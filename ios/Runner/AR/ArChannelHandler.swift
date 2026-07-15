import Flutter
import Foundation

/// Alignment mode requested from Dart via `setMode`.
enum ArMode: String {
    case auto
    case manual
}

/// Implemented by `ArPlatformView` (the object that actually owns the
/// `AVCaptureSession` + `ArVisionPipeline`) so `ArChannelHandler` can stay a
/// thin, testable-in-principle channel adapter with no camera/Vision code.
protocol ArSessionControlling: AnyObject {
    func startSession(
        referenceImagePath: String,
        refWidth: Int,
        refHeight: Int,
        routesJson: String,
        completion: @escaping (Bool) -> Void
    )
    func stopSession()
    func setMode(_ mode: ArMode)
    func rescanSession()
    func lockManualAlignment(screenCorners: [Double], completion: @escaping (Bool) -> Void)
    func unlockManualAlignment()
}

/// Owns the exact-contract `climbtopo/ar` MethodChannel (`start`/`stop`/
/// `setMode`/`rescan`) and the `climbtopo/ar/alignment` EventChannel, and
/// forwards method calls to a `ArSessionControlling` delegate (the platform
/// view).
///
/// Dart contract (must stay byte-for-byte in sync with
/// `lib/features/ar/.../ar_channel*.dart`):
///   MethodChannel('climbtopo/ar')
///     - "start" args: {referenceImagePath: String, refWidth: Int, refHeight: Int, routesJson: String}
///     - "stop" (no args)
///     - "setMode" args: {mode: 'auto'|'manual'}
///     - "rescan" (no args) -- clears the pinned world transform and re-runs
///       image detection so the user can redo a bad first lock.
///     - "lockManual" args: {corners: [Double]x8} -- 4 manually-placed SCREEN
///       corners (TL,TR,BR,BL, in Flutter view/logical points, same space as
///       `sceneView.projectPoint` output); converted to 4 fixed WORLD points
///       and reprojected every frame, independent of the auto-mode pin.
///       Returns a Bool: `true` if tracking was solid and the lock was
///       pinned, `false` if it was refused (no current frame, tracking not
///       `.normal`, or a degenerate/non-finite projection) -- Dart should
///       treat `false` as a no-op and prompt the user to try again.
///     - "unlockManual" (no args) -- clears the manual world pin.
///   EventChannel('climbtopo/ar/alignment')
///     - emits {tracking: Bool, corners: [Double]x8?, frameWidth: Int?, frameHeight: Int?}
///       -- `corners` is the tracked ARKit reference image's four corners (screen-space
///       x,y pairs in TL,TR,BR,BL order) projected via `ARSCNView.projectPoint`, present
///       only when `tracking` is true; `frameWidth`/`frameHeight` are the live ARKit
///       captured-frame pixel dimensions for that same frame, present only when both are
///       `> 0`. Dart treats their absence as "unknown" and falls back to a fitted overlay.
final class ArChannelHandler: NSObject, FlutterStreamHandler {

    static let methodChannelName = "climbtopo/ar"
    static let eventChannelName = "climbtopo/ar/alignment"

    weak var sessionController: ArSessionControlling?

    let methodChannel: FlutterMethodChannel
    let eventChannel: FlutterEventChannel
    private var eventSink: FlutterEventSink?

    init(messenger: FlutterBinaryMessenger) {
        methodChannel = FlutterMethodChannel(name: ArChannelHandler.methodChannelName, binaryMessenger: messenger)
        eventChannel = FlutterEventChannel(name: ArChannelHandler.eventChannelName, binaryMessenger: messenger)
        super.init()
        eventChannel.setStreamHandler(self)
        methodChannel.setMethodCallHandler { [weak self] call, result in
            self?.handle(call, result: result)
        }
    }

    private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        NSLog("AR_DBG channel received method=%@", call.method)
        switch call.method {
        case "start":
            guard
                let args = call.arguments as? [String: Any],
                let referenceImagePath = args["referenceImagePath"] as? String,
                let refWidth = args["refWidth"] as? Int,
                let refHeight = args["refHeight"] as? Int,
                let routesJson = args["routesJson"] as? String
            else {
                result(FlutterError(
                    code: "bad_args",
                    message: "start requires referenceImagePath: String, refWidth: Int, refHeight: Int, routesJson: String",
                    details: nil
                ))
                return
            }
            sessionController?.startSession(
                referenceImagePath: referenceImagePath,
                refWidth: refWidth,
                refHeight: refHeight,
                routesJson: routesJson
            ) { success in
                result(success)
            }

        case "stop":
            sessionController?.stopSession()
            result(nil)

        case "setMode":
            guard
                let args = call.arguments as? [String: Any],
                let modeString = args["mode"] as? String,
                let mode = ArMode(rawValue: modeString)
            else {
                result(FlutterError(
                    code: "bad_args",
                    message: "setMode requires mode: 'auto' | 'manual'",
                    details: nil
                ))
                return
            }
            sessionController?.setMode(mode)
            result(nil)

        case "rescan":
            sessionController?.rescanSession()
            result(nil)

        case "lockManual":
            let args = call.arguments as? [String: Any]
            let raw: [Double]?
            if let doubles = args?["corners"] as? [Double] {
                raw = doubles
            } else if let numbers = args?["corners"] as? [NSNumber] {
                raw = numbers.map { $0.doubleValue }
            } else {
                raw = nil
            }
            guard let corners = raw, corners.count == 8 else {
                result(FlutterError(
                    code: "bad_args",
                    message: "lockManual requires corners: [Double] of length 8",
                    details: nil
                ))
                return
            }
            guard let controller = sessionController else {
                result(false)
                return
            }
            controller.lockManualAlignment(screenCorners: corners) { ok in
                result(ok)
            }

        case "unlockManual":
            sessionController?.unlockManualAlignment()
            result(nil)

        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - FlutterStreamHandler

    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        eventSink = events
        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        eventSink = nil
        return nil
    }

    /// Publishes one alignment update to Dart. MUST be called on the main
    /// thread (Flutter event sinks are not thread-safe).
    ///
    /// `corners` are the four tracked reference-image corners (TL,TR,BR,BL)
    /// in screen-space x,y pairs -- exactly 8 doubles -- and are only
    /// included in the emitted payload when present (i.e. `tracking` is
    /// true and a real ARKit image anchor was projected this frame).
    /// `frameWidth`/`frameHeight` are the live ARKit captured-frame pixel
    /// dimensions for that same frame; pass `0, 0` (the sentinel for "no
    /// frame size") when unknown -- they are only included in the emitted
    /// payload when both are `> 0`.
    func sendAlignment(corners: [Double], tracking: Bool, frameWidth: Int, frameHeight: Int) {
        var payload: [String: Any] = ["tracking": tracking]
        if corners.count == 8 { payload["corners"] = corners }
        if frameWidth > 0 && frameHeight > 0 {
            payload["frameWidth"] = frameWidth
            payload["frameHeight"] = frameHeight
        }
        eventSink?(payload)
    }
}
