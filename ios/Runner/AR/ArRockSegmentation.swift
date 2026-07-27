import CoreVideo
import CoreML
import Vision
import CoreGraphics
import UIKit

/// A coarse, downsampled binary silhouette of the segmented foreground, in
/// the SAME full-upright-reference-photo 0..1 frame as `RockCrop.quadPercent`.
/// `alpha` is a raw 8-bit, row-major buffer (one byte per texel, each byte
/// either 0 or 255 -- NOT PNG), `width * height` bytes long, with its long
/// edge downsampled to <= 256px (aspect need not exactly match the photo:
/// the Dart side stretches it independently in x and y over the aligned
/// quad, which self-corrects any aspect drift). Always present whenever a
/// `RockCrop` is returned.
struct RockMask {
    let alpha: Data
    let width: Int
    let height: Int
}

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
    /// Downsampled binary silhouette of the segmented foreground, full-frame
    /// (NOT just the bbox) in the same full-upright-photo 0..1 frame.
    let mask: RockMask
}

enum ArRockSegmentation {
    /// Redraws `image` UPRIGHT, baking in its `imageOrientation` into the
    /// pixel buffer itself. `UIImage.cgImage` is the RAW decoded pixel
    /// buffer with EXIF orientation discarded; feeding THAT straight into
    /// `ARReferenceImage` (as this used to do) while Dart's own reference
    /// dimensions are EXIF-oriented made portrait reference photos detect
    /// rotated/skewed. Returns `image.cgImage` unchanged when already `.up`
    /// (no redraw needed).
    ///
    /// Non-private so the stateless preview path
    /// (`ArSegmentationChannelHandler`) can share the exact same upright
    /// normalization as the live AR session path (`ArPlatformView`).
    static func uprightCGImage(from image: UIImage) -> CGImage? {
        if image.imageOrientation == .up { return image.cgImage }
        let renderer = UIGraphicsImageRenderer(size: image.size)
        return renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: image.size)) }.cgImage
    }

    /// iOS 16+ only (the bundled `RockSeg` Core ML semantic-segmentation
    /// model has a 16.0 minimum deployment target). Returns nil on <16, a
    /// missing/unloadable model, no Core ML observation, an empty
    /// candidate-rock mask (after the route-clip/person-subtract passes and
    /// the largest-connected-component pass), or any Vision/Core ML
    /// failure -- the caller (`ArSegmentationChannelHandler`) already treats
    /// nil as "no segmentation" and falls back to the full upright photo, so
    /// every early return below is safe.
    ///
    /// `routesNorm` is the wall's route points flattened to
    /// `[x0,y0,x1,y1,...]`, each 0..1 in the SAME full-upright-photo frame as
    /// `quadPercent`. `nil`/empty skips the route-region clip (step 4 below).
    ///
    /// Recipe (authoritative, see docs/superpowers/plans/2026-07-27-ar-rock-crop.md):
    /// semantic-seg argmax -> ROCKPOS ∪ ¬NONROCK candidate mask -> clip to
    /// padded route bbox -> subtract person mask -> largest connected
    /// component overlapping the route bbox (or image center) -> existing
    /// Pass-2 downsample-to-<=256 + quadPercent(bbox) + RockMask return.
    static func segmentAndCrop(_ image: CGImage, routesNorm: [Double]? = nil) -> RockCrop? {
        guard #available(iOS 16.0, *) else {
            NSLog("AR_DBG seg: iOS<16, skip")
            return nil
        }

        guard let (vnModel, labels) = cachedModelAndLabels, !labels.isEmpty, labels.count <= 256 else {
            NSLog("AR_DBG seg: RockSeg model/labels unavailable")
            return nil
        }

        // 1. Semantic segmentation: run the bundled RockSeg model on the
        // upright photo. The model was traced on a plain stretch-resize to
        // 512x512 (ImageNet normalization baked into the graph), so
        // `.scaleFill` (not `.centerCrop`) matches how it was trained.
        let request = VNCoreMLRequest(model: vnModel)
        request.imageCropAndScaleOption = .scaleFill
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            NSLog("AR_DBG seg: Core ML perform failed error=%@", error.localizedDescription)
            return nil
        }

        guard
            let observation = request.results?.first as? VNCoreMLFeatureValueObservation,
            let logits = observation.featureValue.multiArrayValue
        else {
            NSLog("AR_DBG seg: no CoreML feature-value observation")
            return nil
        }

        // logits shape (1, numClasses, gridH, gridW), C-contiguous; strides
        // are in ELEMENTS (not bytes) per `MLMultiArray.strides`.
        let shape = logits.shape.map { $0.intValue }
        let elementStrides = logits.strides.map { $0.intValue }
        guard
            shape.count == 4, shape[0] == 1, shape[1] == labels.count,
            elementStrides.count == 4
        else {
            NSLog("AR_DBG seg: unexpected logits shape=%@ (labels=%d)", shape.description, labels.count)
            return nil
        }
        let numClasses = shape[1]
        let gridH = shape[2]
        let gridW = shape[3]
        let strideC = elementStrides[1]
        let strideY = elementStrides[2]
        let strideX = elementStrides[3]
        guard gridH > 0, gridW > 0 else {
            NSLog("AR_DBG seg: degenerate logits grid %dx%d", gridW, gridH)
            return nil
        }

        // 2. Argmax over the class channels, per pixel -> an 8-bit classId
        // grid (150 classes comfortably fits UInt8). Read via the raw
        // `dataPointer` + `strides` (NOT the NSNumber subscript -- ~100x
        // slower for 150 * 512 * 512 reads). One-shot/offline, so the plain
        // nested loop (no vDSP/Accelerate) costing a few hundred ms is fine.
        var classIds = [UInt8](repeating: 0, count: gridW * gridH)
        switch logits.dataType {
        case .float16:
            let ptr = logits.dataPointer.assumingMemoryBound(to: Float16.self)
            for y in 0..<gridH {
                for x in 0..<gridW {
                    let base = y * strideY + x * strideX
                    var bestClass = 0
                    var bestValue = ptr[base]
                    var c = 1
                    while c < numClasses {
                        let v = ptr[c * strideC + base]
                        if v > bestValue { bestValue = v; bestClass = c }
                        c += 1
                    }
                    classIds[y * gridW + x] = UInt8(bestClass)
                }
            }
        case .float32:
            let ptr = logits.dataPointer.assumingMemoryBound(to: Float.self)
            for y in 0..<gridH {
                for x in 0..<gridW {
                    let base = y * strideY + x * strideX
                    var bestClass = 0
                    var bestValue = ptr[base]
                    var c = 1
                    while c < numClasses {
                        let v = ptr[c * strideC + base]
                        if v > bestValue { bestValue = v; bestClass = c }
                        c += 1
                    }
                    classIds[y * gridW + x] = UInt8(bestClass)
                }
            }
        default:
            NSLog("AR_DBG seg: unsupported logits dataType raw=%d", logits.dataType.rawValue)
            return nil
        }

        // 3. Resolve ROCKPOS/NONROCK class-id sets by NAME (never hardcoded
        // indices) and build the candidate-rock boolean grid:
        // classId ∈ ROCKPOS OR classId ∉ NONROCK.
        let rockPosIds = matchingClassIds(labels, containingAnyOf: [
            "rock", "stone", "mountain", "mount", "cliff", "hill", "wall", "building", "house",
        ])
        let nonRockIds = matchingClassIds(labels, containingAnyOf: [
            "sky", "tree", "grass", "plant", "flower", "person", "water", "sea", "river", "lake",
            "animal", "road", "route", "sidewalk", "pavement", "path", "earth", "ground", "sand",
            "field", "floor", "runway", "dirt",
        ])
        var candidateMask = [Bool](repeating: false, count: gridW * gridH)
        for i in 0..<(gridW * gridH) {
            let cid = Int(classIds[i])
            candidateMask[i] = rockPosIds.contains(cid) || !nonRockIds.contains(cid)
        }

        // 4. Route-region clip: pad the routes' bbox by 6% on each side
        // (clamped to [0,1]) and zero everything outside it. Skipped
        // entirely when routesNorm is nil/empty (no clip).
        let routeBoxGrid = paddedRouteBBoxGrid(routesNorm, gridWidth: gridW, gridHeight: gridH, pad: 0.06)
        if let box = routeBoxGrid {
            for y in 0..<gridH {
                for x in 0..<gridW where x < box.minX || x > box.maxX || y < box.minY || y > box.maxY {
                    candidateMask[y * gridW + x] = false
                }
            }
        }

        // 5. Person-subtract: Apple's built-in person segmentation, best
        // effort (skipped gracefully pre-iOS15 or on any Vision failure --
        // `personMaskGrid` returns nil rather than throwing).
        if #available(iOS 15.0, *), let personGrid = personMaskGrid(image, gridWidth: gridW, gridHeight: gridH) {
            for i in 0..<(gridW * gridH) where personGrid[i] {
                candidateMask[i] = false
            }
        }

        guard candidateMask.contains(true) else {
            NSLog("AR_DBG seg: candidate mask empty after route-clip/person-subtract")
            return nil
        }

        // 6. Largest connected component overlapping the route bbox (or the
        // image-center cell when there are no routes).
        let seedBox = routeBoxGrid ?? (
            minX: gridW / 2 - 1, minY: gridH / 2 - 1,
            maxX: gridW / 2 + 1, maxY: gridH / 2 + 1
        )
        let finalMask = largestComponentGrid(candidateMask, width: gridW, height: gridH, seedBox: seedBox)
        guard finalMask.contains(true) else {
            NSLog("AR_DBG seg: largest-component pass produced an empty mask")
            return nil
        }

        // 7. Feed the 512x512 boolean mask into the EXISTING Pass-2
        // max-pool downsample-to-<=256 + quadPercent(bbox) + RockMask return
        // path below, unchanged -- only how `isForeground`/`maskWidth`/
        // `maskHeight` are produced changed (Core ML mask, not a Vision
        // CVPixelBuffer instance mask).
        let maskWidth = gridW
        let maskHeight = gridH
        let isForeground: (Int, Int) -> Bool = { x, y in finalMask[y * maskWidth + x] }

        // Pass 1: scan the instance mask for the bounding box of ALL
        // foreground pixels.
        var minX = maskWidth
        var minY = maskHeight
        var maxX = -1
        var maxY = -1
        for y in 0..<maskHeight {
            for x in 0..<maskWidth where isForeground(x, y) {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }

        guard maxX >= minX, maxY >= minY else {
            NSLog("AR_DBG seg: mask scan found no foreground pixels")
            return nil
        }

        NSLog(
            "AR_DBG seg: mask bbox (mask space) minX=%d minY=%d maxX=%d maxY=%d maskW=%d maskH=%d",
            minX, minY, maxX, maxY, maskWidth, maskHeight
        )

        // Pass 2 (same locked scope, same base/bytesPerRow/pixelFormat):
        // MAX-POOL downsample the FULL mask (not just the bbox) into a small
        // grid whose long edge is <= 256px. Each output cell is 255 if ANY
        // source pixel it covers is foreground, else 0 -- a max-pool that
        // never erodes the silhouette. Output frame == the full upright
        // photo frame (0..1), matching quadPercent.
        let maskScale = min(1.0, 256.0 / Double(max(maskWidth, maskHeight)))
        let outW = max(1, Int((Double(maskWidth) * maskScale).rounded()))
        let outH = max(1, Int((Double(maskHeight) * maskScale).rounded()))
        var maskBytes = [UInt8](repeating: 0, count: outW * outH)
        for oy in 0..<outH {
            let sy0 = oy * maskHeight / outH
            let sy1 = min(maskHeight, max(sy0 + 1, (oy + 1) * maskHeight / outH))
            for ox in 0..<outW {
                let sx0 = ox * maskWidth / outW
                let sx1 = min(maskWidth, max(sx0 + 1, (ox + 1) * maskWidth / outW))
                var any = false
                cell: for sy in sy0..<sy1 {
                    for sx in sx0..<sx1 where isForeground(sx, sy) {
                        any = true
                        break cell
                    }
                }
                maskBytes[oy * outW + ox] = any ? 255 : 0
            }
        }
        let rockMask = RockMask(alpha: Data(maskBytes), width: outW, height: outH)
        NSLog("AR_DBG seg: full-frame mask downsampled to %dx%d (scale=%f)", outW, outH, maskScale)

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

        return RockCrop(cgImage: cropped, quadPercent: quadPercent, mask: rockMask)
    }

    // MARK: - Core ML model cache

    /// Loaded ONCE (Swift static-let initializers are lazy + thread-safe)
    /// and reused across calls. Loaded ROBUSTLY by URL/`MLModel(contentsOf:)`
    /// rather than an Xcode-generated `RockSeg` class, so this file has no
    /// build-time dependency on Xcode's mlmodel codegen step. `labels` is
    /// the 150 ADE20K class names, parsed from the model's own
    /// `user_defined_metadata["ade20k_labels"]` (pipe-joined, channel-index
    /// order) -- see `tool/ml/README.md`.
    private static let cachedModelAndLabels: (model: VNCoreMLModel, labels: [String])? = {
        guard let url = Bundle.main.url(forResource: "RockSeg", withExtension: "mlmodelc") else {
            NSLog("AR_DBG seg: RockSeg.mlmodelc not found in app bundle")
            return nil
        }
        do {
            // One-shot offline segmentation: force CPU (avoids the ANE/E5RT
            // path, which the Simulator lacks — it returns a zero tensor there —
            // and sidesteps ANE-specific quirks for a once-per-photo run).
            let config = MLModelConfiguration()
            config.computeUnits = .cpuOnly
            let mlmodel = try MLModel(contentsOf: url, configuration: config)
            guard
                let creatorMeta = mlmodel.modelDescription.metadata[MLModelMetadataKey.creatorDefinedKey] as? [String: String],
                let labelsString = creatorMeta["ade20k_labels"]
            else {
                NSLog("AR_DBG seg: RockSeg model missing ade20k_labels metadata")
                return nil
            }
            let labels = labelsString.components(separatedBy: "|")
            let vnModel = try VNCoreMLModel(for: mlmodel)
            NSLog("AR_DBG seg: RockSeg model loaded, %d labels", labels.count)
            return (vnModel, labels)
        } catch {
            NSLog("AR_DBG seg: failed to load RockSeg model error=%@", error.localizedDescription)
            return nil
        }
    }()

    // MARK: - Recipe helpers

    /// Class ids (into `labels`) whose (lowercased) name contains ANY of
    /// `substrings`. Name-based, never a hardcoded index, so a re-exported
    /// model with a different label ordering stays correct.
    private static func matchingClassIds(_ labels: [String], containingAnyOf substrings: [String]) -> Set<Int> {
        var ids = Set<Int>()
        for (index, label) in labels.enumerated() {
            let lower = label.lowercased()
            if substrings.contains(where: { lower.contains($0) }) {
                ids.insert(index)
            }
        }
        return ids
    }

    /// Bounding box of `routesNorm` (flat `[x0,y0,x1,y1,...]`, each 0..1 in
    /// the full-upright-photo frame), padded by `pad` on every side, clamped
    /// to `[0,1]`, then mapped onto a `gridWidth` x `gridHeight` pixel grid
    /// (inclusive min/max cell indices). Returns nil when `routesNorm` is
    /// nil, empty, or has no complete `(x,y)` pair.
    private static func paddedRouteBBoxGrid(
        _ routesNorm: [Double]?,
        gridWidth: Int,
        gridHeight: Int,
        pad: Double
    ) -> (minX: Int, minY: Int, maxX: Int, maxY: Int)? {
        guard let points = routesNorm, points.count >= 2 else { return nil }

        var minXNorm = Double.greatestFiniteMagnitude
        var minYNorm = Double.greatestFiniteMagnitude
        var maxXNorm = -Double.greatestFiniteMagnitude
        var maxYNorm = -Double.greatestFiniteMagnitude
        var i = 0
        while i + 1 < points.count {
            let x = points[i]
            let y = points[i + 1]
            minXNorm = min(minXNorm, x)
            maxXNorm = max(maxXNorm, x)
            minYNorm = min(minYNorm, y)
            maxYNorm = max(maxYNorm, y)
            i += 2
        }
        guard maxXNorm >= minXNorm, maxYNorm >= minYNorm else { return nil }

        minXNorm = min(max(minXNorm - pad, 0), 1)
        minYNorm = min(max(minYNorm - pad, 0), 1)
        maxXNorm = min(max(maxXNorm + pad, 0), 1)
        maxYNorm = min(max(maxYNorm + pad, 0), 1)

        let gMinX = max(0, min(gridWidth - 1, Int((minXNorm * Double(gridWidth)).rounded(.down))))
        let gMinY = max(0, min(gridHeight - 1, Int((minYNorm * Double(gridHeight)).rounded(.down))))
        let gMaxX = max(0, min(gridWidth - 1, Int((maxXNorm * Double(gridWidth)).rounded(.up)) - 1))
        let gMaxY = max(0, min(gridHeight - 1, Int((maxYNorm * Double(gridHeight)).rounded(.up)) - 1))
        guard gMaxX >= gMinX, gMaxY >= gMinY else { return nil }

        return (gMinX, gMinY, gMaxX, gMaxY)
    }

    /// Runs Apple's built-in person-segmentation Vision request on `image`
    /// and resamples/thresholds its output alpha mask (nearest-neighbor)
    /// onto a `gridWidth` x `gridHeight` boolean grid (true == person
    /// pixel). Returns nil on any failure (Vision error, no observation, no
    /// base address) so the caller simply skips the person-subtract step.
    @available(iOS 15.0, *)
    private static func personMaskGrid(_ image: CGImage, gridWidth: Int, gridHeight: Int) -> [Bool]? {
        let request = VNGeneratePersonSegmentationRequest()
        // NB: person seg is full-frame (no imageCropAndScaleOption on this request type),
        // so the proportional resample below already aligns with the .scaleFill class grid.
        request.qualityLevel = .accurate
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            NSLog("AR_DBG seg: person-segmentation perform failed error=%@", error.localizedDescription)
            return nil
        }

        guard let observation = request.results?.first else {
            NSLog("AR_DBG seg: no person-segmentation observation")
            return nil
        }

        let buffer = observation.pixelBuffer
        guard CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else {
            NSLog("AR_DBG seg: could not lock person-mask base address")
            return nil
        }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }

        guard let base = CVPixelBufferGetBaseAddress(buffer) else {
            NSLog("AR_DBG seg: person mask buffer has no base address")
            return nil
        }
        let srcWidth = CVPixelBufferGetWidth(buffer)
        let srcHeight = CVPixelBufferGetHeight(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        guard srcWidth > 0, srcHeight > 0 else {
            NSLog("AR_DBG seg: degenerate person-mask dims %dx%d", srcWidth, srcHeight)
            return nil
        }

        let ptr = base.assumingMemoryBound(to: UInt8.self)
        var grid = [Bool](repeating: false, count: gridWidth * gridHeight)
        for gy in 0..<gridHeight {
            let sy = min(srcHeight - 1, gy * srcHeight / gridHeight)
            for gx in 0..<gridWidth {
                let sx = min(srcWidth - 1, gx * srcWidth / gridWidth)
                grid[gy * gridWidth + gx] = (ptr + sy * bytesPerRow)[sx] > 127
            }
        }
        return grid
    }

    /// Flood-fills `mask` (row-major `width` x `height`, 4-connectivity) into
    /// connected components (BFS, explicit queue -- no recursion) and keeps
    /// only the pixels of the LARGEST component that overlaps `seedBox`
    /// (falling back to the largest component overall if none overlap it).
    /// Everything else is zeroed.
    private static func largestComponentGrid(
        _ mask: [Bool],
        width: Int,
        height: Int,
        seedBox: (minX: Int, minY: Int, maxX: Int, maxY: Int)
    ) -> [Bool] {
        var labels = [Int](repeating: -1, count: width * height)
        var componentSizes: [Int: Int] = [:]
        var componentOverlapsSeed: [Int: Bool] = [:]
        var nextLabel = 0
        var queue = [Int]()
        queue.reserveCapacity(width * height)

        for startY in 0..<height {
            for startX in 0..<width {
                let startIdx = startY * width + startX
                guard mask[startIdx], labels[startIdx] == -1 else { continue }

                let label = nextLabel
                nextLabel += 1
                var size = 0
                var overlapsSeed = false

                labels[startIdx] = label
                queue.removeAll(keepingCapacity: true)
                queue.append(startIdx)
                var head = 0
                while head < queue.count {
                    let cur = queue[head]
                    head += 1
                    size += 1
                    let cx = cur % width
                    let cy = cur / width
                    if cx >= seedBox.minX, cx <= seedBox.maxX, cy >= seedBox.minY, cy <= seedBox.maxY {
                        overlapsSeed = true
                    }
                    if cx > 0 {
                        let n = cur - 1
                        if mask[n], labels[n] == -1 { labels[n] = label; queue.append(n) }
                    }
                    if cx < width - 1 {
                        let n = cur + 1
                        if mask[n], labels[n] == -1 { labels[n] = label; queue.append(n) }
                    }
                    if cy > 0 {
                        let n = cur - width
                        if mask[n], labels[n] == -1 { labels[n] = label; queue.append(n) }
                    }
                    if cy < height - 1 {
                        let n = cur + width
                        if mask[n], labels[n] == -1 { labels[n] = label; queue.append(n) }
                    }
                }

                componentSizes[label] = size
                componentOverlapsSeed[label] = overlapsSeed
            }
        }

        guard !componentSizes.isEmpty else { return mask }

        let overlapping = componentSizes.keys.filter { componentOverlapsSeed[$0] == true }
        let candidates = overlapping.isEmpty ? Array(componentSizes.keys) : overlapping
        guard let winner = candidates.max(by: { (componentSizes[$0] ?? 0) < (componentSizes[$1] ?? 0) }) else {
            return mask
        }

        var out = [Bool](repeating: false, count: width * height)
        for i in 0..<(width * height) where labels[i] == winner {
            out[i] = true
        }
        return out
    }
}
