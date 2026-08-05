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
        engine: ArPlacementEngineKind,
        rockQuadPercent: [Double],
        completion: @escaping (Bool, [Double]?, RockMask?) -> Void
    )
    func stopSession()
    func setMode(_ mode: ArMode)
    func rescanSession()
    func lockManualAlignment(screenCorners: [Double], completion: @escaping (Bool) -> Void)
    func unlockManualAlignment()
}

/// Owns the exact-contract `masi/ar` MethodChannel (`start`/`stop`/
/// `setMode`/`rescan`) and the `masi/ar/alignment` EventChannel, and
/// forwards method calls to a `ArSessionControlling` delegate (the platform
/// view).
///
/// Dart contract (must stay byte-for-byte in sync with
/// `lib/features/ar/.../ar_channel*.dart`):
///   MethodChannel('masi/ar')
///     - "start" args: {referenceImagePath: String, refWidth: Int, refHeight: Int}
///       result: {success: Bool}. Dart no longer sends `routesJson` (accepted but
///       optional, defaulted to "" -- kept only so `ArSessionControlling.startSession`'s
///       signature doesn't have to change); the rock box is computed and drawn
///       entirely in Dart from the tracked corners this class publishes, so the
///       ARReferenceImage built in `ArPlatformView.startSession` is always the FULL
///       upright reference photo -- no Vision foreground crop. `rockQuadPercent`/
///       `rockMaskAlpha`/`rockMaskWidth`/`rockMaskHeight` are therefore never sent:
///       `startSession`'s completion always passes `nil` for both the quad and mask,
///       and each key is only added to `payload` when non-nil, so they naturally
///       vanish. `ArRockSegmentation` (iOS 17+ Vision crop) and
///       `ArSegmentationChannelHandler` ("masi/arSegmentation" -> "segmentPreview")
///       are left in the target, dormant and unused, rather than removed.
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
///   EventChannel('masi/ar/alignment')
///     - emits {tracking: Bool, corners: [Double]x8?, frameWidth: Int?, frameHeight: Int?,
///       trackingState: String, limitedReason: String?}
///       -- `corners` is the tracked ARKit reference image's four corners (screen-space
///       x,y pairs in TL,TR,BR,BL order) projected via `ARSCNView.projectPoint`, present
///       only when `tracking` is true; `frameWidth`/`frameHeight` are the live ARKit
///       captured-frame pixel dimensions for that same frame, present only when both are
///       `> 0`. Dart treats their absence as "unknown" and falls back to a fitted overlay.
///       `trackingState` is one of "normal" | "limited" | "notAvailable", derived from
///       `ARCamera.trackingState` (decoupled from -- and now a required precondition of --
///       whether the pinned corners are in-frustum: `tracking` is only `true` when BOTH
///       hold). `limitedReason` is present only when `trackingState == "limited"` and is a
///       user-facing hint string ("Move slower", "Need more texture/light", "Starting up",
///       "Reconnecting").
final class ArChannelHandler: NSObject, FlutterStreamHandler {

    static let methodChannelName = "masi/ar"
    static let eventChannelName = "masi/ar/alignment"

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
                let refHeight = args["refHeight"] as? Int
            else {
                result(FlutterError(
                    code: "bad_args",
                    message: "start requires referenceImagePath: String, refWidth: Int, refHeight: Int",
                    details: nil
                ))
                return
            }
            // `routesJson` is no longer sent by Dart (the rock box is
            // computed and drawn entirely in Dart from tracked corners) --
            // tolerate its absence rather than requiring it, to avoid
            // changing the `ArSessionControlling.startSession` signature.
            let routesJson = args["routesJson"] as? String ?? ""
            // `engine` (added for the pluggable placement-engine A/B --
            // see `RockRegistrationEngine`): a wire string matching
            // `ArPlacementEngineKind`'s raw values ('arkit'|'vision'|
            // 'opencv'). Absent/unrecognized defaults to 'arkit' -- the
            // untouched baseline path -- rather than failing the call, so
            // older Dart builds that don't send it yet keep working exactly
            // as before.
            let engineRaw = args["engine"] as? String ?? "arkit"
            let engine = ArPlacementEngineKind(rawValue: engineRaw) ?? .arkit
            // `rockQuad` (added alongside `engine`): 8 normalized [0..1]
            // doubles, TL,TR,BR,BL of the rock region within the oriented
            // reference photo; absent/malformed defaults to `[]` ("whole
            // image" -- see `RockRegistrationEngine.loadReference`'s doc).
            // Named distinctly from the completion closure's own
            // `rockQuadPercent` param below (a DIFFERENT value -- the
            // segmentation-derived quad `startSession` hands back to Dart --
            // to avoid the two being confused despite the shared name in
            // that inner scope).
            let rockQuadArg: [Double]
            if let doubles = args["rockQuad"] as? [Double] {
                rockQuadArg = doubles
            } else if let numbers = args["rockQuad"] as? [NSNumber] {
                rockQuadArg = numbers.map { $0.doubleValue }
            } else {
                rockQuadArg = []
            }
            sessionController?.startSession(
                referenceImagePath: referenceImagePath,
                refWidth: refWidth,
                refHeight: refHeight,
                routesJson: routesJson,
                engine: engine,
                rockQuadPercent: rockQuadArg
            ) { success, rockQuadPercent, rockMask in
                var payload: [String: Any] = ["success": success]
                if let rockQuadPercent { payload["rockQuadPercent"] = rockQuadPercent }
                if let rockMask {
                    payload["rockMaskAlpha"] = FlutterStandardTypedData(bytes: rockMask.alpha)
                    payload["rockMaskWidth"] = rockMask.width
                    payload["rockMaskHeight"] = rockMask.height
                }
                result(payload)
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
    /// `trackingState` is the honest ARKit tracking state for this frame
    /// ("normal" | "limited" | "notAvailable"). The overlay render-lock is
    /// DECOUPLED from tracking quality: callers keep `tracking: true` through
    /// `.limited` (in-frustum + pinned) so the overlay stays placed but FADED
    /// (Dart derives a low confidence from the state), and only drop to
    /// `tracking: false` on `.notAvailable` / out-of-frustum / not-pinned.
    /// PIN-ONCE, by contrast, still requires `.normal`. `limitedReason` is the
    /// raw ARKit reason token ("excessiveMotion" | "insufficientFeatures" |
    /// "initializing" | "relocalizing"); the Dart layer owns the user-facing
    /// copy. Only meaningful (and only sent) when `trackingState == "limited"`.
    /// `confidence` (added for the pluggable placement-engine A/B -- see
    /// `RockRegistrationEngine`) is the engine's own 0..1 graded match
    /// score, only meaningful for the non-ARKit engines; the ARKit path
    /// never passes it, so it defaults to `0` and -- per the existing
    /// "only added when meaningful" convention every other optional field
    /// here follows -- is only added to the payload when non-zero, leaving
    /// the ARKit payload byte-for-byte unchanged.
    func sendAlignment(
        corners: [Double],
        tracking: Bool,
        frameWidth: Int,
        frameHeight: Int,
        trackingState: String,
        limitedReason: String? = nil,
        confidence: Double = 0
    ) {
        var payload: [String: Any] = ["tracking": tracking, "trackingState": trackingState]
        if let limitedReason { payload["limitedReason"] = limitedReason }
        if corners.count == 8 { payload["corners"] = corners }
        if frameWidth > 0 && frameHeight > 0 {
            payload["frameWidth"] = frameWidth
            payload["frameHeight"] = frameHeight
        }
        if confidence != 0 { payload["confidence"] = confidence }
        eventSink?(payload)
    }
}
