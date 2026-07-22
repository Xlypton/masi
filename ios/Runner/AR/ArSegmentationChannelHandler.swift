import Flutter
import UIKit

/// Stateless companion to `ArChannelHandler` that runs rock/wall foreground
/// segmentation on a still photo WITHOUT an ARKit session or PlatformView.
///
/// This MUST be a SEPARATE channel ("masi/arSegmentation") because the
/// primary "masi/ar" MethodChannel is created lazily inside
/// `ArPlatformView.init`, which only runs once a `UiKitView(viewType:
/// 'masi/ar')` mounts. A caller that wants a segmentation preview BEFORE any
/// AR view is on screen therefore cannot use "masi/ar". This handler is
/// registered once at launch (see AppDelegate) and is always available.
///
/// Dart contract (must stay in sync with the Dart AR segmentation layer):
///   MethodChannel('masi/arSegmentation')
///     - "segmentPreview" args: {imagePath: String}
///       result: {rockQuadPercent: [Double]x8?, rockMaskAlpha: Uint8List?,
///                rockMaskWidth: Int?, rockMaskHeight: Int?}
///       -- all four keys are OMITTED TOGETHER when segmentation found
///       nothing, failed, or the image could not be decoded (mirrors the
///       "masi/ar" start result's rockQuadPercent omission convention -- an
///       empty result map, never a null sentinel). `rockQuadPercent` is
///       [tlX,tlY, trX,trY, brX,brY, blX,blY], each 0..1, the fraction of
///       the FULL upright reference photo the foreground was cropped to.
///       `rockMaskAlpha` is a raw 8-bit alpha buffer (row-major, one byte
///       per texel, each 0 or 255 -- NOT PNG), length ==
///       rockMaskWidth*rockMaskHeight, in the same full-upright-photo 0..1
///       frame (long edge downsampled to <= 256px).
///     - any other method: FlutterMethodNotImplemented.
///
/// The segmentation runs on a background queue (Vision is not cheap); the
/// `FlutterResult` is always invoked back on the main thread.
final class ArSegmentationChannelHandler: NSObject {

    static let channelName = "masi/arSegmentation"

    private let methodChannel: FlutterMethodChannel

    init(messenger: FlutterBinaryMessenger) {
        methodChannel = FlutterMethodChannel(
            name: ArSegmentationChannelHandler.channelName,
            binaryMessenger: messenger
        )
        super.init()
        methodChannel.setMethodCallHandler { [weak self] call, result in
            self?.handle(call, result: result)
        }
        NSLog("AR_DBG segChannel registered on %@", ArSegmentationChannelHandler.channelName)
    }

    private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        NSLog("AR_DBG segChannel received method=%@", call.method)
        switch call.method {
        case "segmentPreview":
            guard
                let args = call.arguments as? [String: Any],
                let imagePath = args["imagePath"] as? String,
                !imagePath.isEmpty
            else {
                result(FlutterError(
                    code: "bad_args",
                    message: "segmentPreview requires imagePath: String",
                    details: nil
                ))
                return
            }
            DispatchQueue.global(qos: .userInitiated).async {
                var payload: [String: Any] = [:]
                if let uiImage = UIImage(contentsOfFile: imagePath),
                   let uprightCG = ArRockSegmentation.uprightCGImage(from: uiImage),
                   let crop = ArRockSegmentation.segmentAndCrop(uprightCG) {
                    payload["rockQuadPercent"] = crop.quadPercent
                    payload["rockMaskAlpha"] = FlutterStandardTypedData(bytes: crop.mask.alpha)
                    payload["rockMaskWidth"] = crop.mask.width
                    payload["rockMaskHeight"] = crop.mask.height
                    NSLog(
                        "AR_DBG segChannel: segmented %@ -> mask %dx%d",
                        imagePath, crop.mask.width, crop.mask.height
                    )
                } else {
                    NSLog("AR_DBG segChannel: no segmentation for %@ (returning empty)", imagePath)
                }
                DispatchQueue.main.async { result(payload) }
            }

        default:
            result(FlutterMethodNotImplemented)
        }
    }
}
