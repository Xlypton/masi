// RockFeatureMatcher.swift
// Pure-Swift ORB-style wide-baseline feature matching.
// No external dependencies — only iOS SDK (Accelerate, CoreVideo, Foundation, UIKit).

import Accelerate
import CoreVideo
import Foundation
import UIKit

// MARK: - Public types

struct MatchResult {
    let homography: [Double]   // 9 doubles, row-major 3×3, reference-pixel → live-frame-pixel
    let confidence: Double     // 0..1, inlierCount / max(1, goodMatchCount)
    let inlierCount: Int
}

// MARK: - Internal types

private struct DetectedCorner {
    let x: Int
    let y: Int
    let score: Float
    let scale: Float
}

private struct OrbKeypoint {
    let x: Int
    let y: Int
    let scale: Float
    let score: Float
    let d0: UInt64
    let d1: UInt64
    let d2: UInt64
    let d3: UInt64
}

// MARK: - RockFeatureMatcher

final class RockFeatureMatcher {

    // MARK: BRIEF pattern — generated once at class init

    private static let briefPattern: [(Int8, Int8, Int8, Int8)] = {
        var pairs = [(Int8, Int8, Int8, Int8)]()
        pairs.reserveCapacity(256)
        var s: UInt32 = 0xDEAD_BEEF
        for _ in 0..<256 {
            func next() -> Int8 {
                s = s &* 1_664_525 &+ 1_013_904_223
                return Int8(bitPattern: UInt8(s >> 24) & 0x1F) &- 16
            }
            pairs.append((next(), next(), next(), next()))
        }
        return pairs
    }()

    // MARK: State

    private var refKeypoints: [OrbKeypoint] = []
    private var refWidth: Int = 0
    private var refHeight: Int = 0

    // MARK: - Public API

    func loadReference(cgImage: CGImage, refWidth: Int, refHeight: Int) {
        self.refWidth = refWidth
        self.refHeight = refHeight
        guard let (gray, w, h) = cgImageToGray(cgImage) else {
            NSLog("AR_DBG orb loadReference: failed to convert cgImage to gray")
            return
        }
        refKeypoints = extractKeypoints(gray: gray, width: w, height: h)
        NSLog("AR_DBG orb loadReference: %d ref keypoints (image %dx%d)", refKeypoints.count, w, h)
    }

    func matchFrame(_ pixelBuffer: CVPixelBuffer) -> MatchResult? {
        guard !refKeypoints.isEmpty else {
            NSLog("AR_DBG orb no-match reason=no_ref_keypoints")
            return nil
        }
        guard let (gray, w, h) = pixelBufferToGray(pixelBuffer) else {
            NSLog("AR_DBG orb no-match reason=gray_conversion_failed")
            return nil
        }
        let liveKps = extractKeypoints(gray: gray, width: w, height: h)
        guard liveKps.count >= 4 else {
            NSLog("AR_DBG orb no-match reason=too_few_live_keypoints count=%d", liveKps.count)
            return nil
        }

        let goodMatches = matchKeypoints(ref: refKeypoints, live: liveKps)
        guard goodMatches.count >= 4 else {
            NSLog("AR_DBG orb no-match reason=too_few_good_matches count=%d", goodMatches.count)
            return nil
        }

        guard let result = ransacHomography(
            matches: goodMatches,
            refKps: refKeypoints,
            liveKps: liveKps
        ) else {
            NSLog("AR_DBG orb no-match reason=ransac_failed good_matches=%d", goodMatches.count)
            return nil
        }

        NSLog("AR_DBG orb match inliers=%d confidence=%.2f", result.inlierCount, result.confidence)
        return result
    }

    func reset() {
        refKeypoints = []
        refWidth = 0
        refHeight = 0
    }

    // MARK: - Grayscale conversion helpers

    private func pixelBufferToGray(_ pb: CVPixelBuffer) -> ([UInt8], Int, Int)? {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }

        let srcW = CVPixelBufferGetWidth(pb)
        let srcH = CVPixelBufferGetHeight(pb)
        guard let baseAddr = CVPixelBufferGetBaseAddress(pb) else { return nil }

        let bytesPerRow = CVPixelBufferGetBytesPerRow(pb)
        // Source as BGRA
        var srcBuf = vImage_Buffer(
            data: baseAddr,
            height: vImagePixelCount(srcH),
            width: vImagePixelCount(srcW),
            rowBytes: bytesPerRow
        )

        var grayData = [UInt8](repeating: 0, count: srcW * srcH)
        // BGRA → luminance (Rec.601), via a 1x4 matrix positioned to the physical
        // B,G,R,A byte order (vImageMatrixMultiply_ARGB8888ToPlanar8 treats its
        // 4 input channels purely positionally, not by the "ARGB" name).
        var matrix: [Int16] = [29, 150, 77, 0]
        let err: vImage_Error = grayData.withUnsafeMutableBufferPointer { ptr in
            var dst = vImage_Buffer(
                data: ptr.baseAddress,
                height: vImagePixelCount(srcH),
                width: vImagePixelCount(srcW),
                rowBytes: srcW
            )
            return matrix.withUnsafeMutableBufferPointer { matPtr in
                vImageMatrixMultiply_ARGB8888ToPlanar8(
                    &srcBuf, &dst, matPtr.baseAddress!, 256, nil, 0, vImage_Flags(kvImageNoFlags)
                )
            }
        }
        guard err == kvImageNoError else { return nil }
        return (grayData, srcW, srcH)
    }

    private func cgImageToGray(_ cg: CGImage) -> ([UInt8], Int, Int)? {
        let w = cg.width
        let h = cg.height
        guard w > 0, h > 0 else { return nil }

        let colorSpace = CGColorSpaceCreateDeviceGray()
        var grayData = [UInt8](repeating: 0, count: w * h)
        guard let ctx = CGContext(
            data: &grayData,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: w,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }

        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        return (grayData, w, h)
    }

    private func scaleGray(_ src: [UInt8], srcW: Int, srcH: Int, dstW: Int, dstH: Int) -> [UInt8] {
        guard dstW > 0, dstH > 0, srcW > 0, srcH > 0 else { return [] }
        var dst = [UInt8](repeating: 0, count: dstW * dstH)
        src.withUnsafeBufferPointer { srcPtr in
            dst.withUnsafeMutableBufferPointer { dstPtr in
                var srcBuf = vImage_Buffer(
                    data: UnsafeMutableRawPointer(mutating: srcPtr.baseAddress!),
                    height: vImagePixelCount(srcH),
                    width: vImagePixelCount(srcW),
                    rowBytes: srcW
                )
                var dstBuf = vImage_Buffer(
                    data: dstPtr.baseAddress!,
                    height: vImagePixelCount(dstH),
                    width: vImagePixelCount(dstW),
                    rowBytes: dstW
                )
                _ = vImageScale_Planar8(&srcBuf, &dstBuf, nil, vImage_Flags(kvImageHighQualityResampling))
            }
        }
        return dst
    }

    // MARK: - FAST-9 corner detection

    private func fast9(
        _ gray: [UInt8],
        width: Int,
        height: Int,
        threshold: Int = 20,
        scale: Float = 1.0
    ) -> [DetectedCorner] {
        let circle: [(Int, Int)] = [
            (0, -3), (1, -3), (2, -2), (3, -1),
            (3,  0), (3,  1), (2,  2), (1,  3),
            (0,  3), (-1, 3), (-2, 2), (-3, 1),
            (-3, 0), (-3,-1), (-2,-2), (-1,-3)
        ]
        // Pre-compute flat offsets
        let offsets: [Int] = circle.map { (dx, dy) in dy * width + dx }

        var corners = [DetectedCorner]()
        let border = 3
        for y in border..<(height - border) {
            for x in border..<(width - border) {
                let idx = y * width + x
                let center = Int(gray[idx])
                let lo = center - threshold
                let hi = center + threshold

                // Quick reject: check pixels 0, 4, 8, 12
                let p0  = Int(gray[idx + offsets[0]])
                let p4  = Int(gray[idx + offsets[4]])
                let p8  = Int(gray[idx + offsets[8]])
                let p12 = Int(gray[idx + offsets[12]])

                let aboveFast = (p0 > hi ? 1 : 0) + (p4 > hi ? 1 : 0) + (p8 > hi ? 1 : 0) + (p12 > hi ? 1 : 0)
                let belowFast = (p0 < lo ? 1 : 0) + (p4 < lo ? 1 : 0) + (p8 < lo ? 1 : 0) + (p12 < lo ? 1 : 0)
                guard aboveFast >= 3 || belowFast >= 3 else { continue }

                // Full FAST-9 test: 9 consecutive above OR below
                var vals = [Int](repeating: 0, count: 16)
                for i in 0..<16 {
                    vals[i] = Int(gray[idx + offsets[i]])
                }

                var isCorner = false
                // Check 9 consecutive bright
                outer: for start in 0..<16 {
                    for offset in 0..<9 {
                        if vals[(start + offset) % 16] <= hi { continue outer }
                    }
                    isCorner = true
                    break
                }
                if !isCorner {
                    // Check 9 consecutive dark
                    outer: for start in 0..<16 {
                        for offset in 0..<9 {
                            if vals[(start + offset) % 16] >= lo { continue outer }
                        }
                        isCorner = true
                        break
                    }
                }
                guard isCorner else { continue }

                // Score = sum |I(circle_i) - I(center)|
                var score: Float = 0
                for i in 0..<16 {
                    score += Float(abs(vals[i] - center))
                }

                let scaledX = Int(Float(x) / scale + 0.5)
                let scaledY = Int(Float(y) / scale + 0.5)
                corners.append(DetectedCorner(x: scaledX, y: scaledY, score: score, scale: scale))
            }
        }
        return corners
    }

    // MARK: - Keypoint selection

    private func selectKeypoints(corners: [DetectedCorner], nmsRadius: Int = 5, maxCount: Int = 250) -> [DetectedCorner] {
        guard !corners.isEmpty else { return [] }
        // Sort descending by score
        let sorted = corners.sorted { $0.score > $1.score }
        var selected = [DetectedCorner]()
        selected.reserveCapacity(maxCount)
        // Simple greedy NMS
        var suppressed = [Bool](repeating: false, count: sorted.count)
        let r2 = nmsRadius * nmsRadius
        for i in 0..<sorted.count {
            guard !suppressed[i] else { continue }
            selected.append(sorted[i])
            if selected.count >= maxCount { break }
            for j in (i+1)..<sorted.count {
                if suppressed[j] { continue }
                let dx = sorted[j].x - sorted[i].x
                let dy = sorted[j].y - sorted[i].y
                if dx * dx + dy * dy <= r2 {
                    suppressed[j] = true
                }
            }
        }
        return selected
    }

    // MARK: - BRIEF descriptor

    private func briefDescriptor(
        gray: [UInt8],
        width: Int,
        height: Int,
        kx: Int,
        ky: Int
    ) -> (UInt64, UInt64, UInt64, UInt64) {
        let pattern = RockFeatureMatcher.briefPattern
        var d0: UInt64 = 0
        var d1: UInt64 = 0
        var d2: UInt64 = 0
        var d3: UInt64 = 0

        for i in 0..<256 {
            let (x1, y1, x2, y2) = pattern[i]
            let px1 = min(max(kx + Int(x1), 0), width - 1)
            let py1 = min(max(ky + Int(y1), 0), height - 1)
            let px2 = min(max(kx + Int(x2), 0), width - 1)
            let py2 = min(max(ky + Int(y2), 0), height - 1)

            let bit: UInt64 = gray[py1 * width + px1] < gray[py2 * width + px2] ? 1 : 0
            let shift = i % 64
            switch i / 64 {
            case 0: d0 |= bit << shift
            case 1: d1 |= bit << shift
            case 2: d2 |= bit << shift
            default: d3 |= bit << shift
            }
        }
        return (d0, d1, d2, d3)
    }

    // MARK: - Full extraction pipeline

    private func extractKeypoints(gray: [UInt8], width: Int, height: Int) -> [OrbKeypoint] {
        let scales: [(Float, Int, Int)] = [
            (1.0,   width,           height),
            (0.75,  Int(Float(width) * 0.75 + 0.5), Int(Float(height) * 0.75 + 0.5)),
            (0.5,   width / 2,       height / 2)
        ]

        var allCorners = [DetectedCorner]()
        for (scaleFactor, dstW, dstH) in scales {
            guard dstW > 8, dstH > 8 else { continue }
            let scaledGray: [UInt8]
            if scaleFactor == 1.0 {
                scaledGray = gray
            } else {
                scaledGray = scaleGray(gray, srcW: width, srcH: height, dstW: dstW, dstH: dstH)
            }
            let corners = fast9(scaledGray, width: dstW, height: dstH, threshold: 20, scale: scaleFactor)
            allCorners.append(contentsOf: corners)
        }

        let selected = selectKeypoints(corners: allCorners, nmsRadius: 5, maxCount: 250)

        var keypoints = [OrbKeypoint]()
        keypoints.reserveCapacity(selected.count)
        for corner in selected {
            // Clamp to gray buffer (full-res)
            let kx = min(max(corner.x, 0), width - 1)
            let ky = min(max(corner.y, 0), height - 1)
            let (d0, d1, d2, d3) = briefDescriptor(gray: gray, width: width, height: height, kx: kx, ky: ky)
            keypoints.append(OrbKeypoint(
                x: corner.x, y: corner.y,
                scale: corner.scale, score: corner.score,
                d0: d0, d1: d1, d2: d2, d3: d3
            ))
        }
        return keypoints
    }

    // MARK: - Hamming BFMatcher + Lowe's ratio test

    private func hammingDist(
        _ a0: UInt64, _ a1: UInt64, _ a2: UInt64, _ a3: UInt64,
        _ b0: UInt64, _ b1: UInt64, _ b2: UInt64, _ b3: UInt64
    ) -> Int {
        return (a0 ^ b0).nonzeroBitCount
             + (a1 ^ b1).nonzeroBitCount
             + (a2 ^ b2).nonzeroBitCount
             + (a3 ^ b3).nonzeroBitCount
    }

    private struct GoodMatch {
        let refIdx: Int
        let liveIdx: Int
        let dist: Int
    }

    private func matchKeypoints(ref: [OrbKeypoint], live: [OrbKeypoint]) -> [GoodMatch] {
        var matches = [GoodMatch]()
        matches.reserveCapacity(live.count)

        for (li, lkp) in live.enumerated() {
            var bestDist = Int.max
            var secondBestDist = Int.max
            var bestRef = -1

            for (ri, rkp) in ref.enumerated() {
                let d = hammingDist(
                    lkp.d0, lkp.d1, lkp.d2, lkp.d3,
                    rkp.d0, rkp.d1, rkp.d2, rkp.d3
                )
                if d < bestDist {
                    secondBestDist = bestDist
                    bestDist = d
                    bestRef = ri
                } else if d < secondBestDist {
                    secondBestDist = d
                }
            }

            guard bestRef >= 0,
                  bestDist < 60,
                  Double(bestDist) / Double(max(1, secondBestDist)) < 0.80
            else { continue }

            matches.append(GoodMatch(refIdx: bestRef, liveIdx: li, dist: bestDist))
        }
        return matches
    }

    // MARK: - RANSAC homography

    private func ransacHomography(
        matches: [GoodMatch],
        refKps: [OrbKeypoint],
        liveKps: [OrbKeypoint]
    ) -> MatchResult? {
        let maxIter = 500
        let inlierThresh = 6.0
        let minInliers = 6
        let n = matches.count
        guard n >= 4 else { return nil }

        var bestInliers = 0
        var bestH: [Double]? = nil
        var rng: UInt64 = 12345_67890

        func nextRandom(_ bound: Int) -> Int {
            rng ^= rng << 13
            rng ^= rng >> 7
            rng ^= rng << 17
            return Int(rng % UInt64(bound))
        }

        for _ in 0..<maxIter {
            // Sample 4 unique indices
            var idxSet = [Int]()
            var attempts = 0
            while idxSet.count < 4, attempts < 20 {
                let r = nextRandom(n)
                if !idxSet.contains(r) { idxSet.append(r) }
                attempts += 1
            }
            guard idxSet.count == 4 else { continue }

            let srcPts = idxSet.map { i -> (Float, Float) in
                let kp = refKps[matches[i].refIdx]
                return (Float(kp.x), Float(kp.y))
            }
            let dstPts = idxSet.map { i -> (Float, Float) in
                let kp = liveKps[matches[i].liveIdx]
                return (Float(kp.x), Float(kp.y))
            }

            guard let H = solveDLT4(srcPts: srcPts, dstPts: dstPts) else { continue }

            // Count inliers
            var inlierCount = 0
            for m in matches {
                let rp = refKps[m.refIdx]
                let lp = liveKps[m.liveIdx]
                let (wx, wy) = applyHomography(H, x: Double(rp.x), y: Double(rp.y))
                let dx = wx - Double(lp.x)
                let dy = wy - Double(lp.y)
                if sqrt(dx*dx + dy*dy) < inlierThresh {
                    inlierCount += 1
                }
            }

            if inlierCount > bestInliers {
                bestInliers = inlierCount
                bestH = H
            }
        }

        guard bestInliers >= minInliers, let H = bestH else { return nil }
        let confidence = Double(bestInliers) / Double(max(1, matches.count))
        return MatchResult(homography: H, confidence: confidence, inlierCount: bestInliers)
    }

    private func applyHomography(_ H: [Double], x: Double, y: Double) -> (Double, Double) {
        let w = H[6]*x + H[7]*y + H[8]
        guard abs(w) > 1e-10 else { return (0, 0) }
        let px = (H[0]*x + H[1]*y + H[2]) / w
        let py = (H[3]*x + H[4]*y + H[5]) / w
        return (px, py)
    }

    // MARK: - DLT homography solver

    private func solveDLT4(srcPts: [(Float, Float)], dstPts: [(Float, Float)]) -> [Double]? {
        guard srcPts.count == 4, dstPts.count == 4 else { return nil }

        let (normSrc, T1) = normalize2D(srcPts)
        let (normDst, T2) = normalize2D(dstPts)

        // Build 8×8 system with h[8]=1 fixed
        var A = [[Double]](repeating: [Double](repeating: 0, count: 8), count: 8)
        var b = [Double](repeating: 0, count: 8)

        for i in 0..<4 {
            let (x, y) = (Double(normSrc[i].0), Double(normSrc[i].1))
            let (xp, yp) = (Double(normDst[i].0), Double(normDst[i].1))
            let row1 = i * 2
            let row2 = row1 + 1

            // row1: [-x, -y, -1,  0,  0,  0, x'*x, x'*y] * h = x'  (h8=1 moved to rhs)
            A[row1][0] = -x;    A[row1][1] = -y;    A[row1][2] = -1
            A[row1][3] = 0;     A[row1][4] = 0;     A[row1][5] = 0
            A[row1][6] = xp*x;  A[row1][7] = xp*y
            b[row1] = xp  // rhs = xp (from -xp*h8 with h8=1 → moved to rhs as xp)

            // row2: [ 0,  0,  0, -x, -y, -1, y'*x, y'*y] * h = y'
            A[row2][0] = 0;     A[row2][1] = 0;     A[row2][2] = 0
            A[row2][3] = -x;    A[row2][4] = -y;    A[row2][5] = -1
            A[row2][6] = yp*x;  A[row2][7] = yp*y
            b[row2] = yp
        }

        guard let h8 = solveGE8x8(A, b) else { return nil }
        var h = h8 + [1.0]  // append h[8] = 1

        // h is [h0..h7, 1], reshape to 3×3
        let Hnorm = h  // already 9 elements

        // Denormalize: H_px = T2_inv * H_norm * T1
        let T2inv = invertSimilarity(T2)
        let Hpx = matMul33(T2inv, matMul33(Hnorm, T1))

        guard Hpx.allSatisfy({ $0.isFinite }) else { return nil }
        guard abs(Hpx[8]) > 1e-8 else { return nil }

        let scale = Hpx[8]
        return Hpx.map { $0 / scale }
    }

    private func normalize2D(_ pts: [(Float, Float)]) -> (normalized: [(Float, Float)], T: [Double]) {
        let n = pts.count
        guard n > 0 else { return (pts, [1,0,0, 0,1,0, 0,0,1]) }
        let cx = pts.reduce(0.0) { $0 + $1.0 } / Float(n)
        let cy = pts.reduce(0.0) { $0 + $1.1 } / Float(n)
        let meanDist = pts.reduce(0.0) { $0 + sqrt(pow($1.0 - cx, 2) + pow($1.1 - cy, 2)) } / Float(n)
        let s = meanDist > 1e-6 ? Float(sqrt(2.0)) / meanDist : 1.0
        let norm = pts.map { (($0.0 - cx) * s, ($0.1 - cy) * s) }
        let T: [Double] = [
            Double(s), 0,         -Double(cx) * Double(s),
            0,         Double(s), -Double(cy) * Double(s),
            0,         0,          1
        ]
        return (norm, T)
    }

    private func solveGE8x8(_ A: [[Double]], _ b: [Double]) -> [Double]? {
        // Build augmented matrix [A | b]
        var aug = (0..<8).map { r in A[r] + [b[r]] }

        for col in 0..<8 {
            // Partial pivoting
            var maxRow = col
            for r in (col+1)..<8 {
                if abs(aug[r][col]) > abs(aug[maxRow][col]) { maxRow = r }
            }
            aug.swapAt(col, maxRow)
            guard abs(aug[col][col]) > 1e-10 else { return nil }

            // Eliminate all other rows
            for r in 0..<8 where r != col {
                let f = aug[r][col] / aug[col][col]
                for c in 0...8 {
                    aug[r][c] -= f * aug[col][c]
                }
            }
        }

        return (0..<8).map { aug[$0][8] / aug[$0][$0] }
    }

    private func matMul33(_ a: [Double], _ b: [Double]) -> [Double] {
        var out = [Double](repeating: 0, count: 9)
        for r in 0..<3 {
            for c in 0..<3 {
                out[r*3+c] = a[r*3+0]*b[0*3+c] + a[r*3+1]*b[1*3+c] + a[r*3+2]*b[2*3+c]
            }
        }
        return out
    }

    private func invertSimilarity(_ T: [Double]) -> [Double] {
        let s = T[0]
        let tx = T[2]
        let ty = T[5]
        guard abs(s) > 1e-10 else { return [1,0,0, 0,1,0, 0,0,1] }
        return [
            1/s, 0,   -tx/s,
            0,   1/s, -ty/s,
            0,   0,    1
        ]
    }
}
