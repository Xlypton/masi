import CoreGraphics
import CoreVideo
import Foundation

/// `RockRegistrationEngine` wrapping the dormant `ArVisionPipeline`
/// (`VNHomographicImageRegistrationRequest`) -- Variant A of the AR
/// placement-engine A/B (see
/// `docs/superpowers/specs/2026-07-27-ar-placement-engines-design.md`).
/// Apple-native, zero binary weight, but tuned for modest-baseline motion --
/// expect it to hold moderate viewing-angle change and degrade past that
/// (the OpenCV engine, Task 2, is the wide-baseline-robust variant).
final class VisionRegistrationEngine: RockRegistrationEngine {

    private let pipeline = ArVisionPipeline(frameStride: 1)
    private var refSize: CGSize = .zero

    func loadReference(_ image: CGImage, refSize: CGSize, rockQuadPercent: [Double]) -> Bool {
        // Vision registers the WHOLE reference image -- unlike the OpenCV
        // engine's ORB detection mask, there is no straightforward way to
        // restrict `VNHomographicImageRegistrationRequest` to a sub-region,
        // so `rockQuadPercent` is intentionally ignored here in v1. This
        // does not affect which corners get projected (always the full
        // photo, per the protocol's coordinate contract) -- it would only
        // ever have affected feature-detection quality.
        self.refSize = refSize
        return pipeline.loadReference(cgImage: image, refSize: refSize)
    }

    func process(pixelBuffer: CVPixelBuffer, viewSize: CGSize) -> EngineAlignment? {
        var out: ArAlignmentResult?
        // `processLiveFrame` invokes its completion synchronously on the
        // calling queue (see `ArVisionPipeline` doc) -- this capture is safe.
        pipeline.processLiveFrame(pixelBuffer) { out = $0 }
        guard let r = out, r.frameWidth > 0, r.homography.count == 9 else { return nil }

        // Reproject the FULL reference photo's 4 corners (never a rock-crop
        // subset -- see the protocol's coordinate contract) through the
        // row-major ref-pixel -> live-pixel homography into live-pixel space.
        let w = Double(refSize.width)
        let h = Double(refSize.height)
        let refCorners: [CGPoint] = [
            CGPoint(x: 0, y: 0),
            CGPoint(x: w, y: 0),
            CGPoint(x: w, y: h),
            CGPoint(x: 0, y: h),
        ]

        var livePixelCorners: [CGPoint] = []
        livePixelCorners.reserveCapacity(4)
        for c in refCorners {
            // Any non-finite/degenerate corner aborts the whole frame --
            // returning a zero-confidence EngineAlignment instead would be
            // dishonest (there is no partial match), so `nil` (no update
            // this frame) is correct here.
            guard let p = Self.apply(homography: r.homography, to: c) else { return nil }
            livePixelCorners.append(p)
        }

        // Sanity-grade the reprojected quad BEFORE the (unit-changing)
        // view-space letterbox mapping: convexity + area-ratio-vs-reference
        // are scale-invariant checks that a degenerate/nonsensical
        // homography will fail regardless of view size.
        guard let confidence = Self.gradeConfidence(quad: livePixelCorners, refSize: refSize) else {
            return nil
        }

        let bufferSize = CGSize(width: r.frameWidth, height: r.frameHeight)
        let viewCorners = livePixelCorners.map {
            RockEngineMath.livePixelToView($0, bufferSize: bufferSize, viewSize: viewSize)
        }

        var flat: [Double] = []
        flat.reserveCapacity(8)
        for p in viewCorners {
            flat.append(Double(p.x))
            flat.append(Double(p.y))
        }
        return EngineAlignment(corners: flat, confidence: confidence, tracking: true)
    }

    func reset() {
        pipeline.reset()
    }

    // MARK: - Homography application

    /// Applies row-major 3x3 `h` (ref-pixel -> live-pixel, per
    /// `ArAlignmentResult.homography`'s doc) to point `p`:
    /// `[x',y',s] = H . [x,y,1]`, then perspective-divides by `s`. Returns
    /// `nil` when `s` is non-finite/near-zero or the divided result is
    /// non-finite (a degenerate homography).
    private static func apply(homography h: [Double], to p: CGPoint) -> CGPoint? {
        let x = Double(p.x)
        let y = Double(p.y)
        let xp = h[0] * x + h[1] * y + h[2]
        let yp = h[3] * x + h[4] * y + h[5]
        let s = h[6] * x + h[7] * y + h[8]
        guard s.isFinite, abs(s) > 1e-9 else { return nil }
        let rx = xp / s
        let ry = yp / s
        guard rx.isFinite, ry.isFinite else { return nil }
        return CGPoint(x: rx, y: ry)
    }

    // MARK: - Confidence grading

    /// Grades a reprojected quad (any consistent unit -- called here with
    /// live-pixel-space corners): must be convex, and its signed area must
    /// sit within `[0.02, 4.0]` of the reference photo's own pixel-area
    /// footprint (`refSize.width * refSize.height`) -- catching the
    /// "technically finite but wildly degenerate" homographies a pure
    /// finiteness check misses (e.g. the reference collapsed to a sliver, or
    /// exploded far past plausible camera framing). Confidence peaks at
    /// `0.85` at the geometric-mean midpoint of that range and scales down
    /// toward `0.3` as the ratio approaches either bound; outside the range
    /// (or non-convex) returns `nil` (no match this frame).
    private static func gradeConfidence(quad: [CGPoint], refSize: CGSize) -> Double? {
        guard quad.count == 4 else { return nil }
        guard quad.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return nil }
        guard isConvex(quad) else { return nil }

        let quadArea = abs(signedArea(quad))
        let refArea = Double(refSize.width) * Double(refSize.height)
        guard refArea > 0, quadArea.isFinite, quadArea > 0 else { return nil }

        let ratio = quadArea / refArea
        let lower = 0.02
        let upper = 4.0
        guard ratio >= lower, ratio <= upper else { return nil }

        let logRatio = log(ratio)
        let logLower = log(lower)
        let logUpper = log(upper)
        let mid = (logLower + logUpper) / 2
        let halfSpan = (logUpper - logLower) / 2
        // 0 at the midpoint, 1 at either bound.
        let distanceFromMid = min(max(abs(logRatio - mid) / halfSpan, 0), 1)
        return 0.85 - distanceFromMid * (0.85 - 0.3)
    }

    /// Signed polygon area (shoelace formula) of a 4-point quad.
    private static func signedArea(_ points: [CGPoint]) -> Double {
        var sum = 0.0
        let n = points.count
        for i in 0..<n {
            let a = points[i]
            let b = points[(i + 1) % n]
            sum += Double(a.x) * Double(b.y) - Double(b.x) * Double(a.y)
        }
        return sum / 2
    }

    /// Whether a 4-point polygon is convex: every consecutive edge-pair
    /// cross-product has the same sign (all-positive or all-negative --
    /// winding-order agnostic); a zero cross-product (collinear edge) is
    /// tolerated as long as the non-zero ones agree.
    private static func isConvex(_ points: [CGPoint]) -> Bool {
        guard points.count == 4 else { return false }
        var sign = 0
        for i in 0..<4 {
            let a = points[i]
            let b = points[(i + 1) % 4]
            let c = points[(i + 2) % 4]
            let v1x = Double(b.x - a.x)
            let v1y = Double(b.y - a.y)
            let v2x = Double(c.x - b.x)
            let v2y = Double(c.y - b.y)
            let cross = v1x * v2y - v1y * v2x
            guard cross.isFinite else { return false }
            if cross == 0 { continue }
            let s = cross > 0 ? 1 : -1
            if sign == 0 {
                sign = s
            } else if sign != s {
                return false
            }
        }
        return sign != 0
    }
}
