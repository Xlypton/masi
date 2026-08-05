import CoreGraphics
import CoreVideo
import Foundation

/// One registration-engine alignment result, ready to hand to
/// `ArChannelHandler.sendAlignment` -- see `RockRegistrationEngine.process`.
struct EngineAlignment {
    /// 8 doubles, TL,TR,BR,BL, VIEW-SPACE logical points (same space
    /// `ARSCNView.projectPoint` produces, and the same space
    /// `ArChannelHandler.sendAlignment`'s `corners` param expects) --
    /// these are the FULL reference photo's 4 corners reprojected into the
    /// live view, never a rock-crop subset (see the CRITICAL coordinate
    /// contract on `RockRegistrationEngine.loadReference`).
    let corners: [Double]
    /// 0..1 graded match confidence for this frame.
    let confidence: Double
    /// Whether this frame's alignment is usable (mirrors the ARKit
    /// `tracking` field in `sendAlignment`).
    let tracking: Bool
}

/// A pluggable native "given the live camera frame, where did the reference
/// photo go" alignment engine -- the seam that lets `ArPlatformView` swap
/// ARKit's pin-once image-anchor tracking for a continuous per-frame
/// reference->live homography (Vision or OpenCV), while publishing the exact
/// same `EngineAlignment` -> `sendAlignment` contract regardless of which
/// engine is active.
///
/// CRITICAL coordinate contract: routes are stored normalized to the FULL
/// reference photo, and the Dart side does
/// `Homography.fromQuad(fullPhotoCorners, engineCorners)`. Every conforming
/// engine's `process(...)` MUST reproject the FULL reference image's 4
/// corners `(0,0),(w,0),(w,h),(0,h)` -- never a rock-crop subset.
/// `rockQuadPercent` passed to `loadReference` exists only to *restrict
/// feature detection* to the rock region (an OpenCV detection mask); it must
/// never change which corners get projected.
protocol RockRegistrationEngine: AnyObject {
    /// `image`/`refSize` is the upright, full reference photo (already
    /// EXIF-corrected by `ArRockSegmentation.uprightCGImage`, matching what
    /// ARKit's `.arkit` path feeds to `ARReferenceImage`).
    /// `rockQuadPercent` is 8 normalized (0..1) doubles, TL,TR,BR,BL of the
    /// rock region within the oriented photo; empty means "whole image" and
    /// is exactly what engines that ignore rock-restriction (Vision, v1)
    /// should treat any non-empty value as too, per their own docs.
    /// Returns `false` on any load failure -- callers fall back to `nil`
    /// (i.e. no engine, ARKit-only) rather than keep a half-loaded engine.
    func loadReference(_ image: CGImage, refSize: CGSize, rockQuadPercent: [Double]) -> Bool

    /// One live frame -> the reference's 4 corners projected into
    /// `viewSize` (Flutter view/logical points), or `nil` when this frame
    /// produced no usable match (caller sends the "not tracked" payload,
    /// mirroring ARKit's own not-tracked path).
    func process(pixelBuffer: CVPixelBuffer, viewSize: CGSize) -> EngineAlignment?

    /// Resets any per-session state (e.g. frame counters). Engines that hold
    /// no such state may no-op.
    func reset()
}

/// The set of registration engines selectable via the `start` MethodChannel
/// call's `engine` arg (see `ArChannelHandler`). Raw values are the exact
/// wire strings sent from Dart -- must stay in sync with the Dart
/// `ArPlacementEngine` enum's `.name`.
enum ArPlacementEngineKind: String {
    case arkit
    case vision
    case opencv
}

/// Shared math used by every non-ARKit `RockRegistrationEngine` to map a
/// point in LIVE camera pixel-buffer space into the Flutter view's logical
/// point space, given the live AR preview is displayed **aspect-fill**
/// (fills `viewSize`, cropping whichever axis overflows -- never
/// letterboxed/pillarboxed bars) inside the platform view.
///
/// A caseless enum (no cases, cannot be instantiated) used purely as a
/// namespace, mirroring Swift's common "enum as namespace" idiom.
enum RockEngineMath {
    /// `p` is a point in live pixel-buffer space (`bufferSize` = the
    /// `CVPixelBuffer`'s `(width, height)`); returns the corresponding point
    /// in `viewSize` (Flutter view/logical points).
    ///
    /// Aspect-fill: `scale = max(vw/bw, vh/bh)` (the axis that would
    /// otherwise underflow is scaled up until it fills, so the other axis
    /// overflows and gets cropped/centered), then the buffer's scaled
    /// content is centered in the view: `ox = (vw - bw*scale)/2`,
    /// `oy = (vh - bh*scale)/2`.
    static func livePixelToView(_ p: CGPoint, bufferSize: CGSize, viewSize: CGSize) -> CGPoint {
        let bw = bufferSize.width
        let bh = bufferSize.height
        let vw = viewSize.width
        let vh = viewSize.height
        guard bw > 0, bh > 0 else { return p }
        let scale = max(vw / bw, vh / bh)
        let ox = (vw - bw * scale) / 2
        let oy = (vh - bh * scale) / 2
        return CGPoint(x: p.x * scale + ox, y: p.y * scale + oy)
    }
}
