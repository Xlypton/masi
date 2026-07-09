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
}

/// Owns the exact-contract `climbtopo/ar` MethodChannel (`start`/`stop`/
/// `setMode`) and the `climbtopo/ar/alignment` EventChannel, and forwards
/// method calls to a `ArSessionControlling` delegate (the platform view).
///
/// Dart contract (must stay byte-for-byte in sync with
/// `lib/features/ar/.../ar_channel*.dart`):
///   MethodChannel('climbtopo/ar')
///     - "start" args: {referenceImagePath: String, refWidth: Int, refHeight: Int, routesJson: String}
///     - "stop" (no args)
///     - "setMode" args: {mode: 'auto'|'manual'}
///   EventChannel('climbtopo/ar/alignment')
///     - emits {homography: [Double] x9 row-major, confidence: Double, tracking: Bool}
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
    func sendAlignment(homography: [Double], confidence: Double, tracking: Bool) {
        eventSink?([
            "homography": homography,
            "confidence": confidence,
            "tracking": tracking,
        ])
    }
}
