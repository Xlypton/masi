import CoreGraphics
import CoreVideo
import Foundation

/// `RockRegistrationEngine` wrapping the pure-Swift ORB feature matcher
/// (`RockFeatureMatcher`) -- the `.orb` variant of the AR placement-engine A/B.
///
/// Zero external dependencies (no framework binary), wide-baseline-robust by
/// design (FAST corners + BRIEF descriptors + Hamming match + RANSAC), but
/// untuned. It is the "lightweight" end of the robust-engine tradeoff; the
/// OpenCV engine is the heavier, more battle-tested end. `RockFeatureMatcher`
/// was authored in a parallel session and is reconciled here behind the shared
/// `RockRegistrationEngine` protocol.
final class OrbRegistrationEngine: RockRegistrationEngine {

    private let matcher = RockFeatureMatcher()
    private var refSize: CGSize = .zero

    func loadReference(_ image: CGImage, refSize: CGSize, rockQuadPercent: [Double]) -> Bool {
        guard refSize.width > 0, refSize.height > 0 else { return false }
        self.refSize = refSize
        // `RockFeatureMatcher` does not rock-restrict its detection in v1 (parity
        // with Vision). Mask-guided ORB is a deferred tuning knob.
        matcher.loadReference(cgImage: image, refWidth: Int(refSize.width), refHeight: Int(refSize.height))
        return true
    }

    func process(pixelBuffer: CVPixelBuffer) -> EngineAlignment? {
        guard let match = matcher.matchFrame(pixelBuffer), match.homography.count == 9 else { return nil }

        let bufferSize = CGSize(
            width: CVPixelBufferGetWidth(pixelBuffer),
            height: CVPixelBufferGetHeight(pixelBuffer)
        )
        guard let proj = RockEngineMath.projectReferenceQuadNormalized(
            homography: match.homography,
            refSize: refSize,
            bufferSize: bufferSize
        ) else { return nil }

        // ORB has a real numeric match score (inlier ratio), so use it directly
        // (clamped); the quad geometry is a hard validity gate above.
        let confidence = min(1.0, max(0.0, match.confidence))
        return EngineAlignment(corners: proj.cornersNorm, confidence: confidence, tracking: true)
    }

    func reset() {
        matcher.reset()
    }
}
