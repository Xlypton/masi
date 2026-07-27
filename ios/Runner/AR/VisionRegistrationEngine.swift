import CoreGraphics
import CoreVideo
import Foundation

/// `RockRegistrationEngine` wrapping the dormant `ArVisionPipeline`
/// (`VNHomographicImageRegistrationRequest`) -- the `.vision` variant of the AR
/// placement-engine A/B (see
/// `docs/superpowers/specs/2026-07-27-ar-placement-engines-design.md`).
/// Apple-native, zero binary weight, but tuned for modest-baseline motion --
/// expect it to hold moderate viewing-angle change and degrade past that (the
/// ORB / OpenCV engines are the wide-baseline-robust variants).
final class VisionRegistrationEngine: RockRegistrationEngine {

    private let pipeline = ArVisionPipeline(frameStride: 1)
    private var refSize: CGSize = .zero

    func loadReference(_ image: CGImage, refSize: CGSize, rockQuadPercent: [Double]) -> Bool {
        // Vision registers the WHOLE reference image -- there is no
        // straightforward way to restrict `VNHomographicImageRegistrationRequest`
        // to a sub-region, so `rockQuadPercent` is intentionally ignored here in
        // v1. This does not affect which corners get projected (always the full
        // photo, per the protocol's coordinate contract).
        self.refSize = refSize
        return pipeline.loadReference(cgImage: image, refSize: refSize)
    }

    func process(pixelBuffer: CVPixelBuffer) -> EngineAlignment? {
        var out: ArAlignmentResult?
        // `processLiveFrame` invokes its completion synchronously on the calling
        // queue (see `ArVisionPipeline` doc) -- this capture is safe.
        pipeline.processLiveFrame(pixelBuffer) { out = $0 }
        guard let r = out, r.frameWidth > 0, r.homography.count == 9 else { return nil }

        let bufferSize = CGSize(width: r.frameWidth, height: r.frameHeight)
        guard let proj = RockEngineMath.projectReferenceQuadNormalized(
            homography: r.homography,
            refSize: refSize,
            bufferSize: bufferSize
        ) else { return nil }

        // Vision has no numeric match score, so the geometry grade IS the
        // confidence.
        return EngineAlignment(corners: proj.cornersNorm, confidence: proj.areaGrade, tracking: true)
    }

    func reset() {
        pipeline.reset()
    }
}
