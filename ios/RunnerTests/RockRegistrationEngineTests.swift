// RockRegistrationEngineTests.swift
// XCTest coverage for the AR placement-engines math + registration seam (#66):
//   A. `RockEngineMath` pure geometry (no OpenCV / camera needed -- runs
//      anywhere, highest value).
//   B. Synthetic homography recovery through the real `OpenCvRegistrationEngine`
//      / `OrbRegistrationEngine` Swift API -- renders a feature-rich synthetic
//      reference photo, warps it by a KNOWN homography to produce a synthetic
//      "live frame", feeds both through the real engine, and checks the
//      recovered reference-corner projection against the known ground truth.
//
// Coordinate-convention note for Part B: every image in this file (the
// synthetic reference, the warped "live" frame) is rendered via
// `UIGraphicsImageRenderer`, which -- like `UIGraphicsBeginImageContext` --
// pre-applies the CTM flip so (0,0) is the top-left corner and y increases
// downward (the same "row 0 = top" convention `CVPixelBuffer`/`CGImage`
// storage and `RockEngineMath`'s coordinate contract both assume). Reading
// pixels back out into a raw `CGContext(data:...)` (for the BGRA pixel
// buffer) or via `RockMatcher.mm`'s own `GrayMatFromCGImage` uses the same
// "plain `draw(in:)`, no manual flip" pattern already established -- and
// working -- elsewhere in this codebase, so the two stay consistent.
import CoreGraphics
import CoreVideo
import UIKit
import XCTest
@testable import Runner

final class RockRegistrationEngineTests: XCTestCase {

    // MARK: - A. RockEngineMath pure geometry

    func testApplyHomography_identityMapsPointToItself() {
        let identity: [Double] = [1, 0, 0, 0, 1, 0, 0, 0, 1]
        let p = CGPoint(x: 42, y: -7)
        guard let result = RockEngineMath.applyHomography(identity, to: p) else {
            XCTFail("identity homography returned nil")
            return
        }
        XCTAssertEqual(Double(result.x), Double(p.x), accuracy: 1e-9)
        XCTAssertEqual(Double(result.y), Double(p.y), accuracy: 1e-9)
    }

    func testApplyHomography_translationShiftsCorrectly() {
        let tx = 12.5
        let ty = -3.25
        let h: [Double] = [1, 0, tx, 0, 1, ty, 0, 0, 1]
        let p = CGPoint(x: 10, y: 20)
        guard let result = RockEngineMath.applyHomography(h, to: p) else {
            XCTFail("translation homography returned nil")
            return
        }
        XCTAssertEqual(Double(result.x), 10 + tx, accuracy: 1e-9)
        XCTAssertEqual(Double(result.y), 20 + ty, accuracy: 1e-9)
    }

    func testApplyHomography_degenerateScaleReturnsNil() {
        // Last row all-zero -> s (the perspective divisor) is always 0,
        // regardless of the input point: a degenerate homography.
        let h: [Double] = [1, 0, 0, 0, 1, 0, 0, 0, 0]
        let result = RockEngineMath.applyHomography(h, to: CGPoint(x: 5, y: 5))
        XCTAssertNil(result)
    }

    func testProjectReferenceQuadNormalized_identityFullExtentNormalizesToUnitSquare() {
        let refSize = CGSize(width: 100, height: 200)
        let bufferSize = refSize // ref and buffer the same size -- no scaling
        let identity: [Double] = [1, 0, 0, 0, 1, 0, 0, 0, 1]

        guard let result = RockEngineMath.projectReferenceQuadNormalized(
            homography: identity, refSize: refSize, bufferSize: bufferSize
        ) else {
            XCTFail("identity projection returned nil")
            return
        }

        let expected: [Double] = [0, 0, 1, 0, 1, 1, 0, 1] // TL,TR,BR,BL
        XCTAssertEqual(result.cornersNorm.count, 8)
        for i in 0..<8 {
            XCTAssertEqual(result.cornersNorm[i], expected[i], accuracy: 1e-9, "corner component \(i)")
        }
        XCTAssertTrue(result.areaGrade.isFinite)
        XCTAssertGreaterThanOrEqual(result.areaGrade, 0.3)
        XCTAssertLessThanOrEqual(result.areaGrade, 0.85)
    }

    func testProjectReferenceQuadNormalized_collapsedQuadReturnsNil() {
        let refSize = CGSize(width: 100, height: 200)
        let bufferSize = refSize
        // h0=h1=h3=h4=0 maps EVERY point to (h2,h5)=(5,5) regardless of input
        // -- a fully collapsed (zero-area) quad.
        let collapsing: [Double] = [0, 0, 5, 0, 0, 5, 0, 0, 1]
        let result = RockEngineMath.projectReferenceQuadNormalized(
            homography: collapsing, refSize: refSize, bufferSize: bufferSize
        )
        XCTAssertNil(result)
    }

    func testImageNormToView_identityTransformScalesByViewSize() {
        let p = CGPoint(x: 0.5, y: 0.5)
        let viewSize = CGSize(width: 390, height: 844)
        let result = RockEngineMath.imageNormToView(p, displayTransform: .identity, viewSize: viewSize)
        XCTAssertEqual(Double(result.x), 195, accuracy: 1e-9)
        XCTAssertEqual(Double(result.y), 422, accuracy: 1e-9)
    }

    func testIsConvex_unitSquareIsConvexWithAreaOne() {
        let square = [
            CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0),
            CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1),
        ]
        XCTAssertTrue(RockEngineMath.isConvex(square))
        XCTAssertEqual(abs(RockEngineMath.signedArea(square)), 1.0, accuracy: 1e-9)
    }

    func testIsConvex_selfIntersectingQuadIsRejected() {
        // Bowtie: swapping the middle two corners of a square crosses its edges.
        let bowtie = [
            CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 1),
            CGPoint(x: 1, y: 0), CGPoint(x: 0, y: 1),
        ]
        XCTAssertFalse(RockEngineMath.isConvex(bowtie))
    }

    // MARK: - B. Synthetic homography recovery through the real engines

    /// OpenCV (ORB + BFMatcher + RANSAC) is the wide-baseline-robust engine,
    /// so it gets the harder synthetic case: a ~10 degree rotation about the
    /// reference's own center, plus a modest translation.
    ///
    /// KNOWN FAILING as of 2026-07-28: `engine.process(pixelBuffer:)` returns
    /// nil (see the `XCTFail` message) on this synthetic frame, despite a
    /// same-size identity match (ref matched against an exact copy of itself)
    /// succeeding trivially in ad hoc testing -- i.e. the BGRA pixel-buffer
    /// path and gray conversion are not the issue; OpenCV's ORB+RANSAC could
    /// not recover a homography once the frame is actually rotated/translated
    /// under the coded thresholds (`inliers>=12`, `inlierRatio>=0.25`, 5px
    /// RANSAC reprojection). Root cause not yet isolated (`RockMatcher.mm` has
    /// no stage-level diagnostics to pinpoint which gate failed). Real finding
    /// for #66 -- do not loosen this assertion to force a pass.
    func testOpenCvEngine_recoversRotationAndTranslationHomography() throws {
        let refW = 640
        let refH = 480
        let refImage = makeSyntheticReferenceImage(width: refW, height: refH)

        let margin = 120
        let liveW = refW + margin * 2
        let liveH = refH + margin * 2

        let cx = Double(refW) / 2.0
        let cy = Double(refH) / 2.0
        let theta = 10.0 * .pi / 180.0
        let extraTx = 15.0
        let extraTy = -10.0

        var t = CGAffineTransform(translationX: CGFloat(-cx), y: CGFloat(-cy))
        t = t.concatenating(CGAffineTransform(rotationAngle: CGFloat(theta)))
        t = t.concatenating(CGAffineTransform(
            translationX: CGFloat(cx + Double(margin) + extraTx),
            y: CGFloat(cy + Double(margin) + extraTy)
        ))

        let liveImage = warpedImage(from: refImage, refToLive: t, liveWidth: liveW, liveHeight: liveH)
        guard let pixelBuffer = makeBGRAPixelBuffer(from: liveImage) else {
            XCTFail("failed to build synthetic live BGRA pixel buffer")
            return
        }

        let engine = OpenCvRegistrationEngine()
        let loaded = engine.loadReference(
            refImage, refSize: CGSize(width: refW, height: refH), rockQuadPercent: []
        )
        XCTAssertTrue(loaded, "OpenCV engine failed to load the synthetic reference (too few ORB keypoints?)")

        guard let alignment = engine.process(pixelBuffer: pixelBuffer) else {
            XCTFail("OpenCV engine returned nil -- failed to recover a homography from the synthetic rotated+translated frame")
            return
        }

        XCTAssertGreaterThan(alignment.confidence, 0.3, "OpenCV confidence too low: \(alignment.confidence)")

        let maxErrorPx = maxCornerErrorPx(
            groundTruth: t, refSize: CGSize(width: refW, height: refH),
            alignment: alignment, bufferSize: CGSize(width: liveW, height: liveH)
        )
        NSLog("AR_TEST OpenCV rotation+translation: confidence=%.3f maxCornerErrorPx=%.2f", alignment.confidence, maxErrorPx)
        XCTAssertLessThan(maxErrorPx, 20.0, "OpenCV recovered corners too far from ground truth: max error \(maxErrorPx)px")
    }

    /// The pure-Swift ORB engine's BRIEF descriptor has no per-keypoint
    /// orientation compensation (see `RockFeatureMatcher.briefDescriptor`),
    /// so it is not expected to be rotation-invariant -- this synthetic case
    /// is translation-only, per the design brief.
    ///
    /// KNOWN FAILING as of 2026-07-28, root cause ISOLATED: the engine's own
    /// `AR_DBG` diagnostic logs `orb no-match reason=too_few_live_keypoints
    /// count=0` -- `RockFeatureMatcher.pixelBufferToGray`'s vImage BGRA->gray
    /// conversion (`vImageMatrixMultiply_ARGB8888ToPlanar8`) produces a live
    /// grayscale image where FAST-9 finds ZERO corners, on a live buffer whose
    /// raw BGRA content is confirmed non-degenerate (visually rich, verified
    /// via a debug PNG dump) and on the SAME underlying texture that
    /// `cgImageToGray` (the reference-image path) finds 62 keypoints on. This
    /// isolates the bug to the live-frame vImage conversion path specifically
    /// -- not a rotation-invariance limit, not this test's harness. Real
    /// finding for #66 -- do not loosen this assertion to force a pass.
    func testOrbEngine_recoversTranslationOnlyHomography() throws {
        let refW = 640
        let refH = 480
        let refImage = makeSyntheticReferenceImage(width: refW, height: refH)

        let margin = 80
        let liveW = refW + margin * 2
        let liveH = refH + margin * 2

        let shiftX = 25.0
        let shiftY = -18.0
        let t = CGAffineTransform(
            translationX: CGFloat(Double(margin) + shiftX),
            y: CGFloat(Double(margin) + shiftY)
        )

        let liveImage = warpedImage(from: refImage, refToLive: t, liveWidth: liveW, liveHeight: liveH)
        guard let pixelBuffer = makeBGRAPixelBuffer(from: liveImage) else {
            XCTFail("failed to build synthetic live BGRA pixel buffer")
            return
        }

        let engine = OrbRegistrationEngine()
        let loaded = engine.loadReference(
            refImage, refSize: CGSize(width: refW, height: refH), rockQuadPercent: []
        )
        XCTAssertTrue(loaded, "ORB engine failed to load the synthetic reference")

        guard let alignment = engine.process(pixelBuffer: pixelBuffer) else {
            XCTFail("ORB engine returned nil -- failed to recover a homography from the synthetic translated frame")
            return
        }

        let maxErrorPx = maxCornerErrorPx(
            groundTruth: t, refSize: CGSize(width: refW, height: refH),
            alignment: alignment, bufferSize: CGSize(width: liveW, height: liveH)
        )
        NSLog("AR_TEST ORB translation: confidence=%.3f maxCornerErrorPx=%.2f", alignment.confidence, maxErrorPx)
        XCTAssertLessThan(maxErrorPx, 20.0, "ORB recovered corners too far from ground truth: max error \(maxErrorPx)px")
    }

    // MARK: - Test helpers (synthetic image render / warp / pixel buffer)

    /// Renders a feature-rich synthetic "reference photo": smooth multi-octave
    /// **value noise** (a coarse grid of random values per octave,
    /// bilinearly interpolated, several octaves summed) -- a continuous,
    /// isotropic, non-periodic grayscale texture with rich local gradient
    /// variety everywhere, roughly approximating natural rock-surface
    /// mottling. This deliberately avoids two failure modes tried first:
    /// plain solid rectangles (near-identical right-angle corners starve
    /// ORB's Lowe-ratio-test matching of discriminative descriptors) and a
    /// regular small-block noise grid (FAST corners cluster at the grid's
    /// periodic boundaries, which are themselves repetitive). All grid values
    /// come from a deterministic seeded PRNG for reproducibility.
    private func makeSyntheticReferenceImage(width: Int, height: Int) -> CGImage {
        var seed: UInt32 = 0x1234_5678
        func nextRand() -> UInt32 {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            return seed
        }
        func randUnit() -> Double { Double(nextRand() % 100_000) / 100_000.0 }

        struct Octave {
            let cell: Int
            let cols: Int
            let rows: Int
            let values: [Double]
        }
        func makeOctave(cell: Int) -> Octave {
            let cols = width / cell + 2
            let rows = height / cell + 2
            var values = [Double](repeating: 0, count: cols * rows)
            for i in 0..<values.count { values[i] = randUnit() }
            return Octave(cell: cell, cols: cols, rows: rows, values: values)
        }
        func sample(_ o: Octave, x: Int, y: Int) -> Double {
            let gx = Double(x) / Double(o.cell)
            let gy = Double(y) / Double(o.cell)
            let x0 = Int(gx)
            let y0 = Int(gy)
            let fx = gx - Double(x0)
            let fy = gy - Double(y0)
            func v(_ cx: Int, _ cy: Int) -> Double {
                let cxx = min(max(cx, 0), o.cols - 1)
                let cyy = min(max(cy, 0), o.rows - 1)
                return o.values[cyy * o.cols + cxx]
            }
            let top = v(x0, y0) * (1 - fx) + v(x0 + 1, y0) * fx
            let bot = v(x0, y0 + 1) * (1 - fx) + v(x0 + 1, y0 + 1) * fx
            return top * (1 - fy) + bot * fy
        }

        let octaveA = makeOctave(cell: 48) // coarse large-scale structure
        let octaveB = makeOctave(cell: 20) // mid-scale detail
        let octaveC = makeOctave(cell: 9)  // fine detail

        var pixels = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            let rowBase = y * width
            for x in 0..<width {
                let v = 0.5 * sample(octaveA, x: x, y: y)
                    + 0.3 * sample(octaveB, x: x, y: y)
                    + 0.2 * sample(octaveC, x: x, y: y)
                pixels[rowBase + x] = UInt8(max(0, min(255, v * 255)))
            }
        }

        let colorSpace = CGColorSpaceCreateDeviceGray()
        guard let ctx = CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width, space: colorSpace, bitmapInfo: CGImageAlphaInfo.none.rawValue
        ), let cgImage = ctx.makeImage() else {
            fatalError("failed to build synthetic value-noise reference image")
        }
        return cgImage
    }

    /// Renders `ref` into a new, larger canvas after applying `refToLive`
    /// (a ref-pixel -> live-canvas-pixel affine map) -- i.e. the synthetic
    /// "live camera frame" the registration engines are asked to match
    /// against the untouched `ref` image.
    private func warpedImage(
        from ref: CGImage, refToLive: CGAffineTransform, liveWidth: Int, liveHeight: Int
    ) -> CGImage {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: liveWidth, height: liveHeight))
        let img = renderer.image { rendererCtx in
            let ctx = rendererCtx.cgContext
            UIColor(white: 0.5, alpha: 1.0).setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: liveWidth, height: liveHeight))
            ctx.concatenate(refToLive)
            ctx.draw(ref, in: CGRect(x: 0, y: 0, width: ref.width, height: ref.height))
        }
        guard let cgImage = img.cgImage else {
            fatalError("UIGraphicsImageRenderer produced no warped CGImage")
        }
        return cgImage
    }

    /// Builds a single-plane 32BGRA `CVPixelBuffer` from `image` -- the
    /// synthetic-test buffer shape `RockMatcher.mm`'s
    /// `GrayMatFromLockedPixelBuffer` explicitly anticipates.
    private func makeBGRAPixelBuffer(from image: CGImage) -> CVPixelBuffer? {
        let width = image.width
        let height = image.height
        var pixelBuffer: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
            attrs as CFDictionary, &pixelBuffer
        )
        guard status == kCVReturnSuccess, let buffer = pixelBuffer else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: base, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: bytesPerRow, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return buffer
    }

    /// Row-major 3x3 homography (matching `RockEngineMath.applyHomography`'s
    /// convention) equivalent to affine transform `t`: since `t` has no
    /// perspective term, h6=h7=0 and h8=1 (s is always 1).
    private func homographyRowMajor(from t: CGAffineTransform) -> [Double] {
        [Double(t.a), Double(t.c), Double(t.tx),
         Double(t.b), Double(t.d), Double(t.ty),
         0, 0, 1]
    }

    /// Ground truth: reprojects the reference's 4 corners through
    /// `groundTruth`, then compares (in live-frame pixel space) against the
    /// engine's returned normalized corners scaled by `bufferSize`. Returns
    /// the largest per-corner Euclidean error in pixels.
    private func maxCornerErrorPx(
        groundTruth t: CGAffineTransform, refSize: CGSize,
        alignment: EngineAlignment, bufferSize: CGSize
    ) -> Double {
        let H = homographyRowMajor(from: t)
        let refCorners = [
            CGPoint(x: 0, y: 0),
            CGPoint(x: refSize.width, y: 0),
            CGPoint(x: refSize.width, y: refSize.height),
            CGPoint(x: 0, y: refSize.height),
        ]
        XCTAssertEqual(alignment.corners.count, 8)

        var maxError = 0.0
        for (i, corner) in refCorners.enumerated() {
            guard let expected = RockEngineMath.applyHomography(H, to: corner) else {
                XCTFail("ground-truth homography degenerate for corner \(i)")
                continue
            }
            let actualX = alignment.corners[i * 2] * Double(bufferSize.width)
            let actualY = alignment.corners[i * 2 + 1] * Double(bufferSize.height)
            let dx = actualX - Double(expected.x)
            let dy = actualY - Double(expected.y)
            maxError = max(maxError, (dx * dx + dy * dy).squareRoot())
        }
        return maxError
    }
}
