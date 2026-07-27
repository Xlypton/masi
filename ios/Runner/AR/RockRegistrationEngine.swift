import CoreGraphics
import CoreVideo
import Foundation

/// One registration-engine alignment result for a single live frame.
struct EngineAlignment {
    /// 8 doubles, TL,TR,BR,BL, in **normalized captured-image space** `[0,1]`
    /// -- i.e. the FULL reference photo's 4 corners reprojected into the live
    /// camera frame, then divided by the frame's pixel dimensions. These are
    /// NOT view-space points: the captured image is in the camera's native
    /// (landscape) orientation, so `ArPlatformView` must map them to Flutter
    /// view points via `ARFrame.displayTransform(for:viewportSize:)` (which
    /// corrects for interface orientation + aspect-fill) before sending them
    /// on. See `RockEngineMath.projectReferenceQuadNormalized` and the CRITICAL
    /// coordinate contract on `RockRegistrationEngine.loadReference`.
    let corners: [Double]
    /// 0..1 graded match confidence for this frame.
    let confidence: Double
    /// Whether this frame's alignment is usable (mirrors the ARKit `tracking`
    /// field in `sendAlignment`).
    let tracking: Bool
}

/// A pluggable native "given the live camera frame, where did the reference
/// photo go" alignment engine -- the seam that lets `ArPlatformView` swap
/// ARKit's pin-once image-anchor tracking for a continuous per-frame
/// reference->live homography (Vision / pure-Swift ORB / OpenCV), while
/// publishing the exact same `sendAlignment` corner contract regardless of
/// which engine is active.
///
/// CRITICAL coordinate contract: routes are stored normalized to the FULL
/// (oriented) reference photo, and the Dart side does
/// `Homography.fromQuad(fullPhotoCorners, engineCorners)`. Every conforming
/// engine's `process(...)` MUST reproject the FULL reference image's 4 corners
/// `(0,0),(w,0),(w,h),(0,h)` -- never a rock-crop subset. `rockQuadPercent`
/// passed to `loadReference` exists only to *restrict feature detection* to
/// the rock region (e.g. an OpenCV detection mask); it must never change which
/// corners get projected.
protocol RockRegistrationEngine: AnyObject {
    /// `image`/`refSize` is the upright, full reference photo (already
    /// EXIF-corrected by `ArRockSegmentation.uprightCGImage`, matching what
    /// the `.arkit` path feeds to `ARReferenceImage`, and the space routes are
    /// normalized against). `rockQuadPercent` is 8 normalized (0..1) doubles,
    /// TL,TR,BR,BL of the rock region within the oriented photo; empty means
    /// "whole image". Returns `false` on any load failure -- callers fall back
    /// to `nil` (ARKit-only) rather than keep a half-loaded engine.
    func loadReference(_ image: CGImage, refSize: CGSize, rockQuadPercent: [Double]) -> Bool

    /// One live frame -> the reference's 4 corners in normalized captured-image
    /// space (see `EngineAlignment.corners`), or `nil` when this frame produced
    /// no usable match (caller sends the "not tracked" payload, mirroring
    /// ARKit's own not-tracked path). The view mapping (orientation +
    /// aspect-fill) is applied by `ArPlatformView` afterwards, so the engine
    /// needs no view size.
    func process(pixelBuffer: CVPixelBuffer) -> EngineAlignment?

    /// Resets any per-session state (frame counters, etc.). Engines that hold
    /// no such state may no-op.
    func reset()
}

/// The set of registration engines selectable via the `start` MethodChannel
/// call's `engine` arg (see `ArChannelHandler`). Raw values are the exact wire
/// strings sent from Dart -- must stay in sync with the Dart `ArPlacementEngine`
/// enum's `.name`.
///
/// - `arkit`:  the untouched baseline (ARKit image-anchor pin-once).
/// - `vision`: Apple `VNHomographicImageRegistrationRequest` (zero-weight).
/// - `orb`:    pure-Swift ORB feature matching (`RockFeatureMatcher`,
///             zero-dependency, wide-baseline-robust; reconciled from a
///             parallel session).
/// - `opencv`: OpenCV ORB + RANSAC (heavier binary, most battle-tested).
enum ArPlacementEngineKind: String {
    case arkit
    case vision
    case orb
    case opencv
}

/// Shared geometry used by every non-ARKit `RockRegistrationEngine`: reproject
/// the reference photo's corners through a homography, validate the result, and
/// map normalized captured-image points into Flutter view points.
///
/// A caseless enum used purely as a namespace (Swift's "enum as namespace"
/// idiom).
enum RockEngineMath {

    /// Applies row-major 3x3 homography `h` (ref-pixel -> live-frame-pixel,
    /// matching `ArAlignmentResult.homography` / `MatchResult.homography`) to
    /// point `p`: `[x',y',s] = H . [x,y,1]`, then perspective-divides by `s`.
    /// Returns `nil` when `s` is non-finite/near-zero or the divided result is
    /// non-finite (a degenerate homography).
    static func applyHomography(_ h: [Double], to p: CGPoint) -> CGPoint? {
        guard h.count == 9 else { return nil }
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

    /// Reprojects the FULL reference's 4 corners `(0,0),(w,0),(w,h),(0,h)`
    /// (`w,h = refSize`) through `homography` into live-frame-pixel space,
    /// validates the quad (convex + area within a loose band vs the reference
    /// footprint), and returns the 4 corners **normalized by `bufferSize`**
    /// (captured-image `[0,1]` space, TL,TR,BR,BL flat) plus a geometry-only
    /// `areaGrade` in `0.3...0.85`. Returns `nil` for any non-finite /
    /// non-convex / out-of-band result (i.e. no usable match this frame).
    ///
    /// Validation is done in live-frame-pixel space (scale-relative checks are
    /// orientation/scale agnostic); the returned corners are normalized so the
    /// caller can apply `ARFrame.displayTransform` for the final view mapping.
    static func projectReferenceQuadNormalized(
        homography: [Double],
        refSize: CGSize,
        bufferSize: CGSize
    ) -> (cornersNorm: [Double], areaGrade: Double)? {
        let w = Double(refSize.width)
        let h = Double(refSize.height)
        let bw = Double(bufferSize.width)
        let bh = Double(bufferSize.height)
        guard w > 0, h > 0, bw > 0, bh > 0 else { return nil }

        let refCorners: [CGPoint] = [
            CGPoint(x: 0, y: 0),
            CGPoint(x: w, y: 0),
            CGPoint(x: w, y: h),
            CGPoint(x: 0, y: h),
        ]

        var livePixel: [CGPoint] = []
        livePixel.reserveCapacity(4)
        for c in refCorners {
            guard let p = applyHomography(homography, to: c) else { return nil }
            livePixel.append(p)
        }

        guard let grade = gradeQuadArea(quad: livePixel, refSize: refSize) else { return nil }

        var flat: [Double] = []
        flat.reserveCapacity(8)
        for p in livePixel {
            flat.append(Double(p.x) / bw)
            flat.append(Double(p.y) / bh)
        }
        return (flat, grade)
    }

    /// Maps a point in **normalized captured-image space** `[0,1]` to a Flutter
    /// view point, given `displayTransform` from
    /// `ARFrame.displayTransform(for:viewportSize:)` (normalized image ->
    /// normalized viewport, orientation + aspect-fill corrected) and the view
    /// size in logical points.
    static func imageNormToView(
        _ p: CGPoint,
        displayTransform: CGAffineTransform,
        viewSize: CGSize
    ) -> CGPoint {
        let vn = p.applying(displayTransform)
        return CGPoint(x: vn.x * viewSize.width, y: vn.y * viewSize.height)
    }

    // MARK: - Quad validation

    /// Grades a reprojected quad: must be convex, and its area must sit within
    /// `[0.02, 4.0]` of the reference photo's own pixel-area footprint --
    /// catching "technically finite but wildly degenerate" homographies a pure
    /// finiteness check misses (reference collapsed to a sliver, or exploded
    /// far past plausible framing). The band is deliberately loose because the
    /// wall legitimately appears larger/smaller in the live frame than in the
    /// reference. Confidence peaks at `0.85` at the geometric-mean midpoint and
    /// scales toward `0.3` at either bound; outside the band (or non-convex)
    /// returns `nil`.
    static func gradeQuadArea(quad: [CGPoint], refSize: CGSize) -> Double? {
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
        let mid = (log(lower) + log(upper)) / 2
        let halfSpan = (log(upper) - log(lower)) / 2
        let distanceFromMid = min(max(abs(logRatio - mid) / halfSpan, 0), 1)
        return 0.85 - distanceFromMid * (0.85 - 0.3)
    }

    /// Signed polygon area (shoelace) of a 4-point quad.
    static func signedArea(_ points: [CGPoint]) -> Double {
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
    /// cross-product shares a sign (winding-order agnostic); a collinear edge
    /// (zero cross) is tolerated as long as the non-zero ones agree.
    static func isConvex(_ points: [CGPoint]) -> Bool {
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
