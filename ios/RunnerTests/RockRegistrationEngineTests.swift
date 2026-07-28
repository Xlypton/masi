// RockRegistrationEngineTests.swift
// XCTest coverage for the AR placement-engines math + registration seam (#66):
//   A. `RockEngineMath` pure geometry (no OpenCV / camera needed -- runs
//      anywhere, highest value).
//   B. Synthetic homography recovery through the real `OpenCvRegistrationEngine`
//      / `OrbRegistrationEngine` / `ArVisionPipeline` Swift API -- renders a
//      feature-rich synthetic reference photo, warps it by a KNOWN homography
//      to produce a synthetic "live frame", feeds both through the real
//      engine, and checks the recovered reference-corner projection against
//      the known ground truth.
//
// Device-realism notes for Part B (2026-07-28 rewrite):
// - The reference image is a deterministic layout of many high-contrast,
//   spatially-DISTINCT shapes (rects/circles/triangles at varied sizes and
//   gray levels) plus sharp diagonal lines -- NOT smooth value noise. Noise
//   textures are pathological for feature matching (no unambiguous corners);
//   this gives FAST/BRIEF and OpenCV's ORB genuinely discriminative geometry
//   to lock onto, the same way a real rock face's edges/pockets do.
// - The warp is a full projective homography (rotation/scale + translation +,
//   for the OpenCV case, a slight perspective term), applied via a manual
//   per-pixel inverse-warp + bilinear sample -- `CGAffineTransform` /
//   Core Graphics' CTM has no projective-transform primitive, so this is the
//   only way to exercise a genuine non-affine homography in a rendered test
//   image.
// - The warped "live" frame is delivered to every engine as a bi-planar YUV
//   `CVPixelBuffer` (`kCVPixelFormatType_420YpCbCr8BiPlanarFullRange`) --
//   matching what `ARFrame.capturedImage` actually is on-device -- NOT a
//   single-plane BGRA buffer. This is the real path
//   `RockFeatureMatcher.pixelBufferToGray`'s YUV Y-plane fix and
//   `RockMatcher.mm`'s planar branch are meant to run.
//
// Coordinate-convention note: every reference/warped image in this file is
// produced by drawing directly into a raw grayscale `CGContext`, and every
// pixel array read back out of a `CGImage` goes through `cgImageToGrayPixels`
// (a plain `ctx.draw(cgImage, in:)`, no manual flip) -- the exact same
// draw-based conversion `RockMatcher.mm`'s `GrayMatFromCGImage` and
// `RockFeatureMatcher.cgImageToGray` use internally. Because both the
// "ground truth" warp and the engines' own reference-loading go through this
// identical conversion, the two stay arithmetically self-consistent
// regardless of Core Graphics' default bottom-left-origin drawing convention
// -- there is no reliance on any particular visual "up" direction.
import CoreGraphics
import CoreVideo
import Foundation
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
    /// so it gets the hardest synthetic case of the three: a ~10 degree
    /// rotation about the reference's own center, a modest translation, AND
    /// a slight projective (non-affine) term -- the closest of the three
    /// tests to a genuine oblique camera viewing-angle change.
    func testOpenCvEngine_recoversRotationTranslationPerspectiveHomography() throws {
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

        let groundTruthH = matMul33(
            translationH(cx + Double(margin) + extraTx, cy + Double(margin) + extraTy),
            matMul33(
                perspectiveH(px: 0.00012, py: -0.00006),
                matMul33(rotationH(theta), translationH(-cx, -cy))
            )
        )

        let liveImage = warpedImageHomography(
            from: refImage, refToLive: groundTruthH, liveWidth: liveW, liveHeight: liveH
        )
        guard let pixelBuffer = makeYUVPixelBuffer(from: liveImage) else {
            XCTFail("failed to build synthetic live YUV pixel buffer")
            return
        }

        let engine = OpenCvRegistrationEngine()
        let loaded = engine.loadReference(
            refImage, refSize: CGSize(width: refW, height: refH), rockQuadPercent: []
        )
        XCTAssertTrue(loaded, "OpenCV engine failed to load the synthetic reference (too few ORB keypoints?)")

        guard let alignment = engine.process(pixelBuffer: pixelBuffer) else {
            XCTFail("OpenCV engine returned nil -- failed to recover a homography from the synthetic rotated+translated+perspective frame")
            return
        }

        XCTAssertGreaterThan(alignment.confidence, 0.3, "OpenCV confidence too low: \(alignment.confidence)")

        let maxErrorPx = maxCornerErrorPx(
            groundTruth: groundTruthH, refSize: CGSize(width: refW, height: refH),
            alignment: alignment, bufferSize: CGSize(width: liveW, height: liveH)
        )
        NSLog("AR_TEST OpenCV rotation+translation+perspective: confidence=%.3f maxCornerErrorPx=%.2f", alignment.confidence, maxErrorPx)
        XCTAssertLessThan(maxErrorPx, 15.0, "OpenCV recovered corners too far from ground truth: max error \(maxErrorPx)px")
    }

    /// The pure-Swift ORB engine's BRIEF descriptor has no per-keypoint
    /// orientation compensation (see `RockFeatureMatcher.briefDescriptor`),
    /// so it is not expected to be rotation-invariant -- this synthetic case
    /// is translation + a modest scale change, no rotation, per the design
    /// brief. This is also the path that exercises the just-applied
    /// `pixelBufferToGray` YUV Y-plane fix: the OLD BGRA-only path read
    /// garbage from a planar buffer and found zero live keypoints.
    func testOrbEngine_recoversTranslationAndScaleHomography() throws {
        let refW = 640
        let refH = 480
        let refImage = makeSyntheticReferenceImage(width: refW, height: refH)

        let margin = 90
        let liveW = refW + margin * 2
        let liveH = refH + margin * 2

        let cx = Double(refW) / 2.0
        let cy = Double(refH) / 2.0
        let scaleFactor = 1.08
        let shiftX = 20.0
        let shiftY = -14.0

        let groundTruthH = matMul33(
            translationH(cx + Double(margin) + shiftX, cy + Double(margin) + shiftY),
            matMul33(scaleH(scaleFactor, scaleFactor), translationH(-cx, -cy))
        )

        let liveImage = warpedImageHomography(
            from: refImage, refToLive: groundTruthH, liveWidth: liveW, liveHeight: liveH
        )
        guard let pixelBuffer = makeYUVPixelBuffer(from: liveImage) else {
            XCTFail("failed to build synthetic live YUV pixel buffer")
            return
        }

        let engine = OrbRegistrationEngine()
        let loaded = engine.loadReference(
            refImage, refSize: CGSize(width: refW, height: refH), rockQuadPercent: []
        )
        XCTAssertTrue(loaded, "ORB engine failed to load the synthetic reference")

        guard let alignment = engine.process(pixelBuffer: pixelBuffer) else {
            XCTFail("ORB engine returned nil -- failed to recover a homography from the synthetic translated+scaled frame")
            return
        }

        let maxErrorPx = maxCornerErrorPx(
            groundTruth: groundTruthH, refSize: CGSize(width: refW, height: refH),
            alignment: alignment, bufferSize: CGSize(width: liveW, height: liveH)
        )
        NSLog("AR_TEST ORB translation+scale: confidence=%.3f maxCornerErrorPx=%.2f", alignment.confidence, maxErrorPx)
        XCTAssertLessThan(maxErrorPx, 15.0, "ORB recovered corners too far from ground truth: max error \(maxErrorPx)px")
    }

    /// Apple's `VNHomographicImageRegistrationRequest` (`ArVisionPipeline`) is
    /// documented as tuned for modest-baseline motion, so it gets the
    /// gentlest synthetic case: a small ~5 degree rotation plus translation,
    /// no perspective. Uses `ArVisionPipeline` directly (rather than
    /// `VisionRegistrationEngine`) so a genuine "Vision produced no
    /// observation at all" (the `frameWidth == 0` sentinel -- possibly a
    /// simulator/hardware limitation) can be told apart from "Vision matched
    /// but the recovered geometry was bad" (a real algorithmic finding) --
    /// only the former is skipped.
    func testVisionEngine_recoversModestRotationTranslationHomography() throws {
        let refW = 640
        let refH = 480
        let refImage = makeSyntheticReferenceImage(width: refW, height: refH)

        let margin = 90
        let liveW = refW + margin * 2
        let liveH = refH + margin * 2

        let cx = Double(refW) / 2.0
        let cy = Double(refH) / 2.0
        let theta = 5.0 * .pi / 180.0
        let extraTx = 10.0
        let extraTy = -8.0

        let groundTruthH = matMul33(
            translationH(cx + Double(margin) + extraTx, cy + Double(margin) + extraTy),
            matMul33(rotationH(theta), translationH(-cx, -cy))
        )

        let liveImage = warpedImageHomography(
            from: refImage, refToLive: groundTruthH, liveWidth: liveW, liveHeight: liveH
        )
        guard let pixelBuffer = makeYUVPixelBuffer(from: liveImage) else {
            XCTFail("failed to build synthetic live YUV pixel buffer")
            return
        }

        let pipeline = ArVisionPipeline(frameStride: 1)
        let loaded = pipeline.loadReference(cgImage: refImage, refSize: CGSize(width: refW, height: refH))
        XCTAssertTrue(loaded, "Vision pipeline failed to load the synthetic reference")

        var out: ArAlignmentResult?
        // `processLiveFrame` invokes its completion synchronously on the
        // calling thread (see `ArVisionPipeline` doc) -- this capture is safe.
        pipeline.processLiveFrame(pixelBuffer) { out = $0 }
        guard let result = out else {
            XCTFail("Vision pipeline invoked its completion with no result at all")
            return
        }
        guard result.frameWidth > 0, result.homography.count == 9 else {
            throw XCTSkip("VNHomographicImageRegistrationRequest produced no observation for this frame (simulator/hardware limitation) -- device-only")
        }

        let maxErrorPx = maxCornerErrorPxHomography(
            groundTruth: groundTruthH, candidate: result.homography, refSize: CGSize(width: refW, height: refH)
        )
        NSLog("AR_TEST Vision rotation+translation: confidence=%.3f maxCornerErrorPx=%.2f", result.confidence, maxErrorPx)
        XCTAssertLessThan(maxErrorPx, 15.0, "Vision recovered corners too far from ground truth: max error \(maxErrorPx)px")
    }

    // MARK: - Test helpers (synthetic image render / warp / pixel buffer)

    /// Renders a feature-rich synthetic "reference photo": a deterministic
    /// grid of many high-contrast, spatially-DISTINCT shapes (filled
    /// rectangles/circles/triangles, jittered position, varied size and gray
    /// level) plus several sharp diagonal lines -- unambiguous corners
    /// everywhere, roughly approximating a real rock face's mix of edges,
    /// pockets and cracks. This deliberately avoids smooth value-noise
    /// (tried first): a continuous isotropic texture has no genuinely
    /// distinct corners, which is pathological for FAST/BRIEF and ORB
    /// matching alike. All layout values come from a deterministic seeded
    /// PRNG for reproducibility.
    private func makeSyntheticReferenceImage(width: Int, height: Int) -> CGImage {
        var seed: UInt32 = 0x1234_5678
        func nextRand() -> UInt32 {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            return seed
        }
        func randInt(_ bound: Int) -> Int { Int(nextRand() % UInt32(bound)) }
        func randDouble() -> Double { Double(nextRand() % 100_000) / 100_000.0 }

        let colorSpace = CGColorSpaceCreateDeviceGray()
        guard let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: colorSpace, bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else {
            fatalError("failed to create synthetic-reference CGContext")
        }

        // Mid-gray background.
        ctx.setFillColor(gray: 0.5, alpha: 1.0)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

        // A grid of cells, one shape per cell at a jittered position with
        // varied size/gray-level/shape-kind -- each shape is spatially
        // isolated from its neighbors (so FAST corners land on unambiguous,
        // well-separated edges, never a periodic self-similar texture that
        // would starve BRIEF/ORB matching of discriminative descriptors)
        // while the overall layout is aperiodic (per-cell position jitter +
        // varied size + varied gray level + 3 shape kinds).
        let cellSize = 56
        let cols = max(1, width / cellSize)
        let rows = max(1, height / cellSize)
        for row in 0..<rows {
            for col in 0..<cols {
                let baseX = col * cellSize + cellSize / 2
                let baseY = row * cellSize + cellSize / 2
                let jx = randInt(16) - 8
                let jy = randInt(16) - 8
                let cx = Double(baseX + jx)
                let cy = Double(baseY + jy)
                let shapeKind = randInt(3) // 0 = rect, 1 = circle, 2 = triangle
                let halfSize = Double(9 + randInt(14)) // 9...22
                let gray = 0.08 + randDouble() * 0.82
                ctx.setFillColor(gray: gray, alpha: 1.0)

                switch shapeKind {
                case 0:
                    let w = halfSize * (1.2 + randDouble())
                    let h = halfSize * (0.8 + randDouble())
                    ctx.fill(CGRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h))
                case 1:
                    let r = halfSize
                    ctx.fillEllipse(in: CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2))
                default:
                    let r = halfSize
                    ctx.beginPath()
                    ctx.move(to: CGPoint(x: cx, y: cy - r))
                    ctx.addLine(to: CGPoint(x: cx + r, y: cy + r))
                    ctx.addLine(to: CGPoint(x: cx - r, y: cy + r))
                    ctx.closePath()
                    ctx.fillPath()
                }
            }
        }

        // Sharp, high-contrast diagonal lines across the full canvas -- extra
        // strong, unambiguous corners at every line/shape intersection and
        // line endpoint, deterministic positions from the same seeded PRNG.
        ctx.setLineWidth(4)
        for _ in 0..<16 {
            let dark = randInt(2) == 0
            ctx.setStrokeColor(gray: dark ? 0.03 : 0.97, alpha: 1.0)
            let x0 = Double(randInt(width))
            let x1 = Double(randInt(width))
            ctx.beginPath()
            ctx.move(to: CGPoint(x: x0, y: 0))
            ctx.addLine(to: CGPoint(x: x1, y: Double(height)))
            ctx.strokePath()
        }

        guard let cgImage = ctx.makeImage() else {
            fatalError("failed to build synthetic feature-distinctive reference image")
        }
        return cgImage
    }

    /// Draw-based CGImage -> grayscale pixel array conversion -- the same
    /// pattern `RockMatcher.mm`'s `GrayMatFromCGImage` and
    /// `RockFeatureMatcher.cgImageToGray` use internally (a plain
    /// `ctx.draw(cgImage, in:)` into a fresh 8-bit grayscale `CGContext`, no
    /// manual flip). Used here to pull the reference image's pixels for the
    /// per-pixel homography warp below.
    private func cgImageToGrayPixels(_ cg: CGImage) -> (pixels: [UInt8], width: Int, height: Int)? {
        let w = cg.width
        let h = cg.height
        guard w > 0, h > 0 else { return nil }
        var pixels = [UInt8](repeating: 0, count: w * h)
        let colorSpace = CGColorSpaceCreateDeviceGray()
        guard let ctx = CGContext(
            data: &pixels, width: w, height: h, bitsPerComponent: 8,
            bytesPerRow: w, space: colorSpace, bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        return (pixels, w, h)
    }

    /// Renders `ref` warped by a full projective homography `H` (row-major
    /// 3x3, ref-pixel -> live-canvas-pixel, matching
    /// `RockEngineMath.applyHomography`'s convention) into a
    /// `liveWidth`x`liveHeight` canvas -- i.e. the synthetic "live camera
    /// frame" the registration engines are asked to match against the
    /// untouched `ref` image. Walks every destination pixel, inverse-maps it
    /// through `H`, and bilinearly samples the reference -- unlike a
    /// `CGAffineTransform`-based warp, this can express a genuine perspective
    /// term (h6/h7 != 0), since Core Graphics' CTM has no projective-warp
    /// primitive.
    private func warpedImageHomography(
        from ref: CGImage, refToLive H: [Double], liveWidth: Int, liveHeight: Int
    ) -> CGImage {
        guard let (refGray, refW, refH) = cgImageToGrayPixels(ref) else {
            fatalError("failed to rasterize reference image for homography warp")
        }
        guard let hInv = invert3x3(H) else {
            fatalError("ground-truth homography is not invertible")
        }

        let background: UInt8 = 128
        var dst = [UInt8](repeating: background, count: liveWidth * liveHeight)
        for ly in 0..<liveHeight {
            let y = Double(ly) + 0.5
            for lx in 0..<liveWidth {
                let x = Double(lx) + 0.5
                let s = hInv[6] * x + hInv[7] * y + hInv[8]
                guard s.isFinite, abs(s) > 1e-9 else { continue }
                let rx = (hInv[0] * x + hInv[1] * y + hInv[2]) / s
                let ry = (hInv[3] * x + hInv[4] * y + hInv[5]) / s
                guard rx.isFinite, ry.isFinite,
                      rx >= 0, ry >= 0, rx < Double(refW - 1), ry < Double(refH - 1)
                else { continue }

                let x0 = Int(rx)
                let y0 = Int(ry)
                let fx = rx - Double(x0)
                let fy = ry - Double(y0)
                let v00 = Double(refGray[y0 * refW + x0])
                let v10 = Double(refGray[y0 * refW + x0 + 1])
                let v01 = Double(refGray[(y0 + 1) * refW + x0])
                let v11 = Double(refGray[(y0 + 1) * refW + x0 + 1])
                let top = v00 * (1 - fx) + v10 * fx
                let bot = v01 * (1 - fx) + v11 * fx
                let v = top * (1 - fy) + bot * fy
                dst[ly * liveWidth + lx] = UInt8(max(0, min(255, v.rounded())))
            }
        }

        let colorSpace = CGColorSpaceCreateDeviceGray()
        guard let ctx = CGContext(
            data: &dst, width: liveWidth, height: liveHeight, bitsPerComponent: 8,
            bytesPerRow: liveWidth, space: colorSpace, bitmapInfo: CGImageAlphaInfo.none.rawValue
        ), let cgImage = ctx.makeImage() else {
            fatalError("failed to build warped homography CGImage")
        }
        return cgImage
    }

    /// Builds a bi-planar 4:2:0 YUV (`kCVPixelFormatType_420YpCbCr8BiPlanarFullRange`)
    /// `CVPixelBuffer` from `image` -- matching what `ARFrame.capturedImage`
    /// actually delivers on-device (see the `RockFeatureMatcher.pixelBufferToGray`
    /// YUV Y-plane fix this test suite exists to validate). The luma (Y)
    /// plane is filled with `image`'s rendered grayscale content; the chroma
    /// (CbCr) plane is filled with flat 128/128 ("no color") since every
    /// engine under test only ever reads luma.
    private func makeYUVPixelBuffer(from image: CGImage) -> CVPixelBuffer? {
        let width = image.width
        let height = image.height
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, width, height,
            kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            nil, &pixelBuffer
        )
        guard status == kCVReturnSuccess, let buffer = pixelBuffer else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        guard let yBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { return nil }
        let yRowBytes = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let colorSpace = CGColorSpaceCreateDeviceGray()
        guard let yCtx = CGContext(
            data: yBase, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: yRowBytes, space: colorSpace, bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }
        yCtx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        guard let cbcrBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 1) else { return nil }
        let cbcrRowBytes = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
        let cbcrHeight = CVPixelBufferGetHeightOfPlane(buffer, 1)
        memset(cbcrBase, 128, cbcrRowBytes * cbcrHeight)

        return buffer
    }

    // MARK: - 3x3 homography helpers (row-major, matching RockEngineMath's convention)

    private func translationH(_ tx: Double, _ ty: Double) -> [Double] {
        [1, 0, tx, 0, 1, ty, 0, 0, 1]
    }

    private func rotationH(_ theta: Double) -> [Double] {
        let c = cos(theta)
        let s = sin(theta)
        return [c, -s, 0, s, c, 0, 0, 0, 1]
    }

    private func scaleH(_ sx: Double, _ sy: Double) -> [Double] {
        [sx, 0, 0, 0, sy, 0, 0, 0, 1]
    }

    private func perspectiveH(px: Double, py: Double) -> [Double] {
        [1, 0, 0, 0, 1, 0, px, py, 1]
    }

    private func matMul33(_ a: [Double], _ b: [Double]) -> [Double] {
        var out = [Double](repeating: 0, count: 9)
        for r in 0..<3 {
            for c in 0..<3 {
                var sum = 0.0
                for k in 0..<3 { sum += a[r * 3 + k] * b[k * 3 + c] }
                out[r * 3 + c] = sum
            }
        }
        return out
    }

    /// General 3x3 matrix inverse (row-major), via the adjugate/cofactor
    /// method. Returns `nil` if the determinant is ~0 (non-invertible).
    private func invert3x3(_ m: [Double]) -> [Double]? {
        guard m.count == 9 else { return nil }
        let a = m[0], b = m[1], c = m[2]
        let d = m[3], e = m[4], f = m[5]
        let g = m[6], h = m[7], i = m[8]

        let c11 = e * i - f * h
        let c21 = c * h - b * i
        let c31 = b * f - c * e
        let c12 = f * g - d * i
        let c22 = a * i - c * g
        let c32 = c * d - a * f
        let c13 = d * h - e * g
        let c23 = b * g - a * h
        let c33 = a * e - b * d

        let det = a * c11 + b * c12 + c * c13
        guard det.isFinite, abs(det) > 1e-12 else { return nil }

        return [
            c11 / det, c21 / det, c31 / det,
            c12 / det, c22 / det, c32 / det,
            c13 / det, c23 / det, c33 / det,
        ]
    }

    // MARK: - Corner-error measurement

    /// Ground truth: reprojects the reference's 4 corners through
    /// `groundTruth`, then compares (in live-frame pixel space) against the
    /// engine's returned normalized corners scaled by `bufferSize`. Returns
    /// the largest per-corner Euclidean error in pixels. For engines
    /// (OpenCV/ORB) that report their match via `EngineAlignment`'s
    /// normalized `corners`.
    private func maxCornerErrorPx(
        groundTruth H: [Double], refSize: CGSize,
        alignment: EngineAlignment, bufferSize: CGSize
    ) -> Double {
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

    /// Same idea as `maxCornerErrorPx`, but compares two raw pixel-space
    /// homographies directly (both applied to the same reference corners) --
    /// used for `ArVisionPipeline`, which reports its match as a raw
    /// `ArAlignmentResult.homography` rather than pre-normalized
    /// `EngineAlignment.corners`.
    private func maxCornerErrorPxHomography(
        groundTruth: [Double], candidate: [Double], refSize: CGSize
    ) -> Double {
        let refCorners = [
            CGPoint(x: 0, y: 0),
            CGPoint(x: refSize.width, y: 0),
            CGPoint(x: refSize.width, y: refSize.height),
            CGPoint(x: 0, y: refSize.height),
        ]

        var maxError = 0.0
        for (i, corner) in refCorners.enumerated() {
            guard let expected = RockEngineMath.applyHomography(groundTruth, to: corner),
                  let actual = RockEngineMath.applyHomography(candidate, to: corner)
            else {
                XCTFail("degenerate homography reprojecting corner \(i)")
                continue
            }
            let dx = Double(actual.x - expected.x)
            let dy = Double(actual.y - expected.y)
            maxError = max(maxError, (dx * dx + dy * dy).squareRoot())
        }
        return maxError
    }
}
