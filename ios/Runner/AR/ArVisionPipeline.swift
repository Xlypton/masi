import CoreVideo
import Foundation
import UIKit
import Vision
import simd

/// One alignment pass, ready to hand to the Flutter event sink.
struct ArAlignmentResult {
    /// Row-major 3x3 homography (9 values) mapping REFERENCE-IMAGE PIXEL
    /// coordinates -> LIVE-FRAME PIXEL coordinates, both top-left origin.
    /// This matches the Dart-side `Homography.warp` convention: Dart takes
    /// stored route points (percent -> reference-pixel space) and
    /// multiplies `[x, y, 1] * H` (with perspective divide) to place them
    /// onto the live camera view.
    let homography: [Double]
    let confidence: Double
    let tracking: Bool
    /// Live-frame pixel-buffer dimensions (`CVPixelBufferGetWidth/Height`,
    /// post-rotation -- i.e. portrait, matching the on-screen preview) at
    /// the moment this alignment was computed. `0`/`0` is the sentinel for
    /// "no real match this frame" (identity/no-match/degenerate paths) --
    /// only populated on an actual Vision observation, so Dart can tell a
    /// real homography from a fallback one.
    let frameWidth: Int
    let frameHeight: Int
}

/// Wraps `VNHomographicImageRegistrationRequest` to continuously align a
/// static reference topo photo against the live camera feed.
///
/// CALIBRATION NOTE (on-device verification required, not provable by
/// compiling alone):
/// `VNImageHomographicAlignmentObservation.warpTransform` is a
/// `matrix_float3x3` that Vision documents as mapping the "floating" image
/// (the image the `VNImageRequestHandler` was constructed with -- here the
/// STORED REFERENCE photo) into the "targeted" image's coordinate space
/// (the buffer passed to `VNHomographicImageRegistrationRequest(targetedCVPixelBuffer:)`
/// -- here the LIVE frame). That direction (reference -> live) is exactly
/// the direction the Dart contract expects.
///
/// What is NOT verified by compilation, and must be checked on-device:
/// 1. Whether Vision's `warpTransform` operates in NORMALIZED [0,1]x[0,1]
///    image coordinates with origin at the BOTTOM-LEFT (Vision's usual
///    convention for `VNImageRequestHandler`/observations), vs. raw pixel
///    coordinates. This pipeline assumes normalized, bottom-left-origin,
///    and applies `normalizationCorrection` to convert to pixel-space,
///    top-left-origin (matching UIKit/Flutter and the Dart contract).
/// 2. simd's `matrix_float3x3.columns` are COLUMN-major in memory,
///    requiring transposition before flattening row-major -- verify the
///    transposition below produces a matrix that, when applied as
///    `[x, y, 1] * H` (row-vector on the left, per the Dart
///    `Homography.warp` convention), reproduces Vision's intended mapping.
/// 3. The heuristic `confidence` value: Vision does not expose a numeric
///    quality score for `VNHomographicImageRegistrationRequest`, so this
///    uses the matrix determinant as a degeneracy proxy. Replace with a
///    perceptually-tuned metric (e.g. reprojecting reference corners and
///    checking they land inside/near the live frame) once real footage is
///    available.
final class ArVisionPipeline {

    /// The stored reference topo photo, set once via `loadReference`.
    private var referenceCGImage: CGImage?
    private var referenceSize: CGSize = .zero

    /// Simple frame-throttling: only run Vision every Nth sample buffer,
    /// since VNHomographicImageRegistrationRequest is too expensive to run
    /// on every camera frame at full frame rate.
    private let frameStride: Int
    private var frameCounter = 0

    init(frameStride: Int = 3) {
        self.frameStride = max(1, frameStride)
    }

    /// Loads the reference topo photo from disk. `refWidth`/`refHeight` are
    /// the dimensions the Dart side used when converting stored route
    /// percent-points to reference-pixel space, and are required so the
    /// normalization correction below scales correctly even if the
    /// on-disk image was re-encoded at a different resolution.
    func loadReference(path: String, refWidth: Int, refHeight: Int) -> Bool {
        guard let image = UIImage(contentsOfFile: path), let cgImage = image.cgImage else {
            return false
        }
        referenceCGImage = cgImage
        referenceSize = CGSize(width: refWidth, height: refHeight)
        frameCounter = 0
        return true
    }

    /// Loads an already-decoded, upright reference CGImage directly (used by
    /// `VisionRegistrationEngine`, which receives the same EXIF-corrected image
    /// the `.arkit` path feeds to `ARReferenceImage`, so there is nothing to
    /// re-decode from disk).
    func loadReference(cgImage: CGImage, refSize: CGSize) -> Bool {
        referenceCGImage = cgImage
        referenceSize = refSize
        frameCounter = 0
        return true
    }

    func reset() {
        frameCounter = 0
    }

    /// Called for every live camera frame. Applies frame-stride throttling
    /// internally and invokes `completion` with the alignment result, or
    /// `nil` if this frame was skipped (caller should treat `nil` as "no
    /// update this frame", not as tracking-lost). `completion` is invoked
    /// synchronously on the calling (session) queue -- callers must hop to
    /// main before touching the Flutter event sink.
    func processLiveFrame(_ pixelBuffer: CVPixelBuffer, completion: @escaping (ArAlignmentResult?) -> Void) {
        frameCounter += 1
        guard frameCounter % frameStride == 0 else {
            completion(nil)
            return
        }
        guard let referenceCGImage else {
            completion(ArAlignmentResult(homography: ArVisionPipeline.identity, confidence: 0, tracking: false, frameWidth: 0, frameHeight: 0))
            return
        }

        let liveWidth = CVPixelBufferGetWidth(pixelBuffer)
        let liveHeight = CVPixelBufferGetHeight(pixelBuffer)
        let request = VNHomographicImageRegistrationRequest(targetedCVPixelBuffer: pixelBuffer)

        do {
            // The handler is constructed with the STORED REFERENCE image
            // (the "floating" image); the request targets the LIVE frame.
            // Vision computes floating -> targeted, i.e. reference -> live.
            let handler = VNImageRequestHandler(cgImage: referenceCGImage, options: [:])
            try handler.perform([request])
            guard let observation = request.results?.first as? VNImageHomographicAlignmentObservation else {
                NSLog("AR_DBG vision no-match")
                completion(ArAlignmentResult(homography: ArVisionPipeline.identity, confidence: 0, tracking: false, frameWidth: 0, frameHeight: 0))
                return
            }
            let warp = observation.warpTransform
            let corrected = ArVisionPipeline.normalizationCorrection(
                warp: warp,
                refSize: referenceSize,
                liveSize: CGSize(width: liveWidth, height: liveHeight)
            )
            let confidence = ArVisionPipeline.heuristicConfidence(for: corrected)
            NSLog("AR_DBG vision match confidence=%.2f frame=%dx%d", confidence, liveWidth, liveHeight)
            completion(ArAlignmentResult(
                homography: corrected,
                confidence: confidence,
                tracking: confidence > 0.15,
                frameWidth: liveWidth,
                frameHeight: liveHeight
            ))
        } catch {
            NSLog("AR_DBG vision no-match")
            completion(ArAlignmentResult(homography: ArVisionPipeline.identity, confidence: 0, tracking: false, frameWidth: 0, frameHeight: 0))
        }
    }

    // MARK: - Matrix helpers

    static let identity: [Double] = [1, 0, 0, 0, 1, 0, 0, 0, 1]

    /// Converts Vision's `matrix_float3x3` (column-major in memory,
    /// normalized [0,1]^2, bottom-left origin -- see class doc, item 1/2)
    /// into a row-major `[Double]` (9) mapping reference-PIXEL to
    /// live-PIXEL, top-left origin.
    static func normalizationCorrection(warp: matrix_float3x3, refSize: CGSize, liveSize: CGSize) -> [Double] {
        let c0 = warp.columns.0
        let c1 = warp.columns.1
        let c2 = warp.columns.2
        // Transpose simd's column-major storage into row-major, still in
        // Vision's normalized bottom-left-origin space.
        let rowMajorNormalized: [Double] = [
            Double(c0.x), Double(c1.x), Double(c2.x),
            Double(c0.y), Double(c1.y), Double(c2.y),
            Double(c0.z), Double(c1.z), Double(c2.z),
        ]

        guard refSize.width > 0, refSize.height > 0, liveSize.width > 0, liveSize.height > 0 else {
            return rowMajorNormalized
        }

        // pixelLive = S_live * F * H_norm * F * S_ref^-1 * pixelRef
        // where S scales [0,1] <-> [0, size] and F flips y (bottom-left <->
        // top-left origin); F is self-inverse.
        func flip() -> [Double] { [1, 0, 0, 0, -1, 1, 0, 0, 1] }
        func scale(_ w: Double, _ h: Double) -> [Double] { [w, 0, 0, 0, h, 0, 0, 0, 1] }
        func invScale(_ w: Double, _ h: Double) -> [Double] { [1 / w, 0, 0, 0, 1 / h, 0, 0, 0, 1] }

        let sLive = scale(Double(liveSize.width), Double(liveSize.height))
        let f = flip()
        let sRefInv = invScale(Double(refSize.width), Double(refSize.height))

        let step1 = matMul(f, rowMajorNormalized) // F * H_norm
        let step2 = matMul(step1, f) // F * H_norm * F
        let step3 = matMul(step2, sRefInv) // F * H_norm * F * S_ref^-1
        return matMul(sLive, step3) // S_live * F * H_norm * F * S_ref^-1
    }

    /// 3x3 row-major matrix multiply, a * b.
    private static func matMul(_ a: [Double], _ b: [Double]) -> [Double] {
        var out = [Double](repeating: 0, count: 9)
        for r in 0..<3 {
            for c in 0..<3 {
                var sum = 0.0
                for k in 0..<3 {
                    sum += a[r * 3 + k] * b[k * 3 + c]
                }
                out[r * 3 + c] = sum
            }
        }
        return out
    }

    /// `matrix` is the CORRECTED row-major pixel-space homography (i.e. the
    /// output of `normalizationCorrection`, not the raw Vision `warpTransform`)
    /// -- checking finiteness post-correction also catches degenerate scale
    /// factors introduced by the correction step itself (e.g. a pathological
    /// `refSize`/`liveSize`), not just a degenerate Vision observation.
    ///
    /// Vision does not expose a numeric quality score for
    /// `VNHomographicImageRegistrationRequest` (see class doc, item 3), so
    /// this is deliberately binary rather than a graded probability: any
    /// finite, non-degenerate homographic observation is treated as a
    /// confident match (0.8, comfortably above the `tracking` threshold of
    /// 0.15); anything degenerate/non-finite is 0 (no match).
    private static func heuristicConfidence(for matrix: [Double]) -> Double {
        guard matrix.count == 9, matrix.allSatisfy({ $0.isFinite }) else { return 0.0 }
        let det =
            matrix[0] * (matrix[4] * matrix[8] - matrix[5] * matrix[7])
            - matrix[1] * (matrix[3] * matrix[8] - matrix[5] * matrix[6])
            + matrix[2] * (matrix[3] * matrix[7] - matrix[4] * matrix[6])
        guard det.isFinite, abs(det) > 1e-6 else { return 0.0 }
        return 0.8
    }
}
