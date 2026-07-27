import CoreGraphics
import CoreVideo
import Foundation

/// `RockRegistrationEngine` wrapping the Obj-C++ OpenCV bridge (`RockMatcher`)
/// -- the `.opencv` variant of the AR placement-engine A/B (see
/// `docs/superpowers/specs/2026-07-27-ar-placement-engines-design.md`).
///
/// OpenCV ORB + BFMatcher + RANSAC `findHomography` -- the heaviest binary of
/// the four engines, but the most battle-tested for wide-baseline / oblique
/// angle robustness (the pure-Swift `.orb` engine trades that battle-testing
/// for zero binary weight).
final class OpenCvRegistrationEngine: RockRegistrationEngine {

    private let matcher = RockMatcher()
    private var refSize: CGSize = .zero

    func loadReference(_ image: CGImage, refSize: CGSize, rockQuadPercent: [Double]) -> Bool {
        guard refSize.width > 0, refSize.height > 0 else { return false }
        self.refSize = refSize
        return matcher.loadReferenceCGImage(image, rockQuad: rockQuadPercent.map { NSNumber(value: $0) })
    }

    func process(pixelBuffer: CVPixelBuffer) -> EngineAlignment? {
        // `RockMatcher.matchPixelBuffer:` bridges to Swift as `matcher.match(_:)`
        // (positional, no label) -- Swift's Clang importer drops the trailing
        // selector piece "PixelBuffer" as a label because it already matches
        // the (dropped) first-parameter name, per its argument-label
        // deduplication heuristic. Returns [h0..h8 row-major 3x3 homography,
        // inlierRatio] (10 numbers), or nil when no reliable match was found
        // this frame.
        guard let arr = matcher.match(pixelBuffer), arr.count == 10 else { return nil }

        let h = (0..<9).map { arr[$0].doubleValue }
        let inlier = arr[9].doubleValue

        let bufferSize = CGSize(
            width: CVPixelBufferGetWidth(pixelBuffer),
            height: CVPixelBufferGetHeight(pixelBuffer)
        )
        guard let proj = RockEngineMath.projectReferenceQuadNormalized(
            homography: h,
            refSize: refSize,
            bufferSize: bufferSize
        ) else { return nil }

        // OpenCV has a real numeric match score (RANSAC inlier ratio), so use
        // it directly (clamped); the quad geometry is a hard validity gate
        // (inside `projectReferenceQuadNormalized`) above.
        let confidence = min(1.0, max(0.0, inlier))
        return EngineAlignment(corners: proj.cornersNorm, confidence: confidence, tracking: true)
    }

    func reset() {
        matcher.reset()
    }
}
