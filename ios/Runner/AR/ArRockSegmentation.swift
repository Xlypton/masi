import CoreVideo
import Vision
import CoreGraphics
import UIKit

/// Best-effort rock/wall foreground crop, computed once per `startSession`
/// call (see `ArPlatformView.startSession`). When Vision finds a confident
/// foreground instance, ARKit's `detectionImages` is fed the tighter crop
/// instead of the full reference photo -- less background clutter to
/// false-match against. Any failure (OS too old, no confident instance,
/// Vision error, unreadable mask) returns `nil` and the caller falls back to
/// the full upright photo, so this is always safe to call.
struct RockCrop {
    let cgImage: CGImage
    /// [tlX,tlY, trX,trY, brX,brY, blX,blY], each 0..1, fraction of the FULL upright reference photo.
    let quadPercent: [Double]
}

enum ArRockSegmentation {
    /// iOS 17+ only. Returns nil on <17, no confident foreground instance, or any Vision failure.
    static func segmentAndCrop(_ image: CGImage) -> RockCrop? {
        guard #available(iOS 17.0, *) else {
            NSLog("AR_DBG seg: iOS<17, skip")
            return nil
        }

        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            NSLog("AR_DBG seg: Vision perform failed error=%@", error.localizedDescription)
            return nil
        }

        guard let observation = request.results?.first else {
            NSLog("AR_DBG seg: no VNInstanceMaskObservation in results")
            return nil
        }

        let instances = observation.allInstances
        guard !instances.isEmpty else {
            NSLog("AR_DBG seg: no confident foreground instances")
            return nil
        }

        let maskBuffer = observation.instanceMask
        guard CVPixelBufferLockBaseAddress(maskBuffer, .readOnly) == kCVReturnSuccess else {
            NSLog("AR_DBG seg: could not lock mask base address")
            return nil
        }
        defer { CVPixelBufferUnlockBaseAddress(maskBuffer, .readOnly) }

        guard let base = CVPixelBufferGetBaseAddress(maskBuffer) else {
            NSLog("AR_DBG seg: mask buffer has no base address")
            return nil
        }

        let maskWidth = CVPixelBufferGetWidth(maskBuffer)
        let maskHeight = CVPixelBufferGetHeight(maskBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(maskBuffer)
        let pixelFormat = CVPixelBufferGetPixelFormatType(maskBuffer)

        guard maskWidth > 0, maskHeight > 0 else {
            NSLog("AR_DBG seg: degenerate mask dims %dx%d", maskWidth, maskHeight)
            return nil
        }

        // Scan the instance mask for the bounding box of ALL foreground
        // pixels (any instance id != 0 -- 0 is background per Vision's
        // contract). The mask's own pixel format isn't documented on the
        // `instanceMask` property directly, so handle the two plausible
        // formats explicitly and bail out (fall back to full photo) on
        // anything else rather than mis-scan.
        //
        // DEVICE-VERIFY: this scan (and the mask -> image scale below, see
        // scaleX/scaleY) assumes the raw CVPixelBuffer's (x, y) = (0, 0) is
        // the top-left corner and that rows/columns map 1:1 onto the
        // reference image's own top-left-origin pixel space once scaled by
        // imgWidth/maskWidth and imgHeight/maskHeight. This is standard
        // Vision/Core Video behavior but is NOT documented on
        // `VNInstanceMaskObservation.instanceMask` itself, so it must be
        // sanity-checked on-device: confirm the actual CROP CONTENT
        // (`RockCrop.cgImage`, or the AR overlay it feeds) is really the
        // photographed rock face and not mirrored or shifted -- e.g. by
        // dumping `cropped` to a file/log during a real device AR session
        // and eyeballing it against the source photo, the same way
        // `ArPlatformView.swift`'s corner-order DEVICE-VERIFY flag is
        // checked.
        var minX = maskWidth
        var minY = maskHeight
        var maxX = -1
        var maxY = -1

        switch pixelFormat {
        case kCVPixelFormatType_OneComponent8:
            let ptr = base.assumingMemoryBound(to: UInt8.self)
            for y in 0..<maskHeight {
                let row = ptr + y * bytesPerRow
                for x in 0..<maskWidth where row[x] != 0 {
                    if x < minX { minX = x }
                    if x > maxX { maxX = x }
                    if y < minY { minY = y }
                    if y > maxY { maxY = y }
                }
            }
        case kCVPixelFormatType_OneComponent32Float:
            for y in 0..<maskHeight {
                let rowBase = (base + y * bytesPerRow).assumingMemoryBound(to: Float32.self)
                for x in 0..<maskWidth where rowBase[x] != 0 {
                    if x < minX { minX = x }
                    if x > maxX { maxX = x }
                    if y < minY { minY = y }
                    if y > maxY { maxY = y }
                }
            }
        default:
            NSLog("AR_DBG seg: unsupported mask pixel format=%d", Int(pixelFormat))
            return nil
        }

        guard maxX >= minX, maxY >= minY else {
            NSLog("AR_DBG seg: mask scan found no foreground pixels")
            return nil
        }

        NSLog(
            "AR_DBG seg: mask bbox (mask space) minX=%d minY=%d maxX=%d maxY=%d maskW=%d maskH=%d",
            minX, minY, maxX, maxY, maskWidth, maskHeight
        )

        // The instance mask is generally produced at a lower working
        // resolution than the full-size reference photo (Vision does not
        // upscale `instanceMask` to the input image's dimensions -- that is
        // what `generateScaledMaskForImageForInstances` is for, which we
        // deliberately avoid per the crop-offset-semantics caution above).
        // Scale the bbox from mask pixel space into the ORIGINAL image's
        // pixel space before cropping/percenting.
        let imgWidth = image.width
        let imgHeight = image.height
        guard imgWidth > 0, imgHeight > 0 else {
            NSLog("AR_DBG seg: degenerate source image dims %dx%d", imgWidth, imgHeight)
            return nil
        }
        let scaleX = Double(imgWidth) / Double(maskWidth)
        let scaleY = Double(imgHeight) / Double(maskHeight)

        let pxMinX = max(0, Int(Double(minX) * scaleX))
        let pxMinY = max(0, Int(Double(minY) * scaleY))
        let pxMaxX = min(imgWidth, Int(Double(maxX + 1) * scaleX))
        let pxMaxY = min(imgHeight, Int(Double(maxY + 1) * scaleY))

        let bboxPx = CGRect(x: pxMinX, y: pxMinY, width: pxMaxX - pxMinX, height: pxMaxY - pxMinY)
        guard bboxPx.width > 0, bboxPx.height > 0, let cropped = image.cropping(to: bboxPx) else {
            NSLog("AR_DBG seg: crop failed bboxPx=%@", NSCoder.string(for: bboxPx))
            return nil
        }

        let quadPercent: [Double] = [
            Double(pxMinX) / Double(imgWidth), Double(pxMinY) / Double(imgHeight), // TL
            Double(pxMaxX) / Double(imgWidth), Double(pxMinY) / Double(imgHeight), // TR
            Double(pxMaxX) / Double(imgWidth), Double(pxMaxY) / Double(imgHeight), // BR
            Double(pxMinX) / Double(imgWidth), Double(pxMaxY) / Double(imgHeight), // BL
        ]

        NSLog(
            "AR_DBG seg: crop bboxPx=%@ quadPercent=%@",
            NSCoder.string(for: bboxPx), quadPercent.description
        )

        return RockCrop(cgImage: cropped, quadPercent: quadPercent)
    }
}
