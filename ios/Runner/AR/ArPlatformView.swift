import ARKit
import CoreVideo
import Flutter
import ImageIO
import SceneKit
import UIKit
import simd

/// Native AR platform view behind `UiKitView(viewType: 'masi/ar')`.
///
/// Uses ARKit world tracking (`ARWorldTrackingConfiguration` with
/// `detectionImages`) to detect the reference topo photo in the live camera
/// feed. The FIRST solid detection is pinned as a fixed world-space
/// transform (see `pinnedTransform`/`pinnedPhysicalSize` below); every
/// subsequent frame re-projects that same pinned transform's four corners
/// (in reference-image pixel order: TL, TR, BR, BL) into current screen
/// space via `ARSCNView.projectPoint`, and publishes them over the
/// `masi/ar/alignment` EventChannel (via `ArChannelHandler`) as
/// `corners` -- Dart derives its own overlay transform from those four
/// screen points rather than from a homography matrix. Further image
/// (re-)detections are intentionally ignored once pinned, since on 3D
/// scenes ARKit can false-match the reference image onto other surfaces,
/// which otherwise causes the overlay to jump/flicker; `rescanSession()`
/// clears the pin so the user can redo a bad first lock.
///
/// `ArVisionPipeline` (the previous AVFoundation + Vision homography
/// pipeline) is intentionally left in the target, unused.
enum RegistrationMode { case vision, orb }

final class ArPlatformView: NSObject, FlutterPlatformView {

    private let sceneView = ARSCNView()
    private let channelHandler: ArChannelHandler
    /// Standard ARKit "move your device" guidance UI for a good initial lock
    /// (`goal: .tracking`). Added as a subview of `sceneView` so it renders
    /// over the live camera feed; wired to `sceneView.session` in `init`.
    private let coachingOverlay = ARCoachingOverlayView()

    private var mode: ArMode = .auto
    private var referenceImage: ARReferenceImage?
    private var wasTracked = false
    private var frameCounter = 0
    private var pinnedTransform: simd_float4x4?
    private var pinnedPhysicalSize: CGSize?
    /// Last `trackingState` string sent to Dart -- used only to log ARKit
    /// tracking-state TRANSITIONS (AR_DBG) rather than spamming a log line
    /// every frame.
    private var lastTrackingStateStr: String?
    /// Manual-mode fixed world-space corners (TL,TR,BR,BL), set by
    /// `lockManualAlignment(screenCorners:)`. Takes precedence over
    /// `pinnedTransform`/`pinnedPhysicalSize` when present -- see
    /// `session(_:didUpdate:)`. Independent of the auto-mode pin so auto
    /// mode's existing per-frame path is unaffected.
    private var pinnedManualCorners: [simd_float3]?
    /// The active pluggable registration engine (see
    /// `RockRegistrationEngine`), set by `startSession` from the `engine`
    /// arg. `nil` whenever `engineKind == .arkit` (the untouched default) or
    /// the chosen engine failed to load its reference -- in both cases
    /// `session(_:didUpdate:)` falls through to the original ARKit
    /// pin-once + `projectPoint` block below, byte-for-byte unchanged.
    private var placementEngine: RockRegistrationEngine?
    /// Which engine `startSession` was last asked for -- kept alongside
    /// `placementEngine` (rather than inferred from it being non-nil) so a
    /// failed engine load can still be logged/diagnosed against what was
    /// actually requested.
    private var engineKind: ArPlacementEngineKind = .arkit

    // Phase 2 registration engines — both compiled in; switch by changing this constant
    static let registrationMode: RegistrationMode = .vision
    private let visionPipeline = ArVisionPipeline()
    private let orbMatcher = RockFeatureMatcher()

    // Hold-last-good state for continuous registration
    private var _lastGoodCorners: [Double]?
    private var _weakFrameCount: Int = 0
    private let _weakFrameLimit: Int = 90  // ~3s at 30fps → send tracking:false

    private var refWidth: Int = 0
    private var refHeight: Int = 0

    init(frame: CGRect, viewId: Int64, messenger: FlutterBinaryMessenger, args: Any?) {
        sceneView.autoresizingMask = [.flexibleWidth, .flexibleHeight]

        // The MethodChannel ("masi/ar") and EventChannel
        // ("masi/ar/alignment") are created here, against the exact
        // same FlutterBinaryMessenger the registrar handed to
        // ArViewFactory (see AppDelegate.swift), so channel names match
        // the Dart contract exactly.
        channelHandler = ArChannelHandler(messenger: messenger)

        super.init()

        sceneView.session.delegate = self
        channelHandler.sessionController = self

        coachingOverlay.session = sceneView.session
        coachingOverlay.goal = .tracking
        coachingOverlay.activatesAutomatically = true
        coachingOverlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        coachingOverlay.frame = sceneView.bounds
        coachingOverlay.delegate = self
        sceneView.addSubview(coachingOverlay)

        NSLog("AR_DBG ARKit ArPlatformView.init")
    }

    func view() -> UIView {
        sceneView
    }
}

// MARK: - ArSessionControlling (driven by ArChannelHandler / MethodChannel)

extension ArPlatformView: ArSessionControlling {

    func startSession(
        referenceImagePath: String,
        refWidth: Int,
        refHeight: Int,
        routesJson: String,
        engine: ArPlacementEngineKind,
        rockQuadPercent: [Double],
        completion: @escaping (Bool, [Double]?, RockMask?) -> Void
    ) {
        NSLog("AR_DBG startSession invoked")
        // `routesJson` is accepted for contract completeness -- the native
        // side does not need route geometry: Dart owns and draws the route
        // overlay itself, deriving its transform from the tracked corners
        // this view sends, so `routesJson` is intentionally unused here.
        _ = routesJson

        guard let uiImage = UIImage(contentsOfFile: referenceImagePath), let rawCG = uiImage.cgImage else {
            NSLog("AR_DBG ref decode FAILED")
            completion(false, nil, nil)
            return
        }

        // EXIF orientation fix -- see `ArRockSegmentation.uprightCGImage` doc.
        guard let uprightCG = ArRockSegmentation.uprightCGImage(from: uiImage) else {
            NSLog("AR_DBG ref upright redraw FAILED")
            completion(false, nil, nil)
            return
        }
        NSLog(
            "AR_DBG ref exif imageOrientation=%d rawSize=%dx%d uprightSize=%dx%d",
            uiImage.imageOrientation.rawValue, rawCG.width, rawCG.height, uprightCG.width, uprightCG.height
        )

        // Rock-box (Ship 1): the AR reference image is now ALWAYS the full
        // upright photo -- no Vision foreground crop. The rock box itself is
        // computed and drawn entirely in Dart from the tracked corners this
        // view publishes, so native no longer needs to segment anything.
        // `ArRockSegmentation`/`ArSegmentationChannelHandler` are left
        // dormant in the target (unused, but still compiling) rather than
        // removed.
        NSLog("AR_DBG using full-photo reference image, no crop")

        // Pluggable registration engine (see `RockRegistrationEngine`):
        // `.arkit` (the default/baseline) always clears `placementEngine`,
        // leaving `session(_:didUpdate:)`'s original ARKit pin-once block as
        // the only path -- byte-for-byte the pre-existing behavior. `.vision`
        // builds a `VisionRegistrationEngine`; `.opencv` is wired in Task 2
        // (left `nil` for now, which -- same as a load failure below --
        // gracefully falls back to the ARKit path). Any engine whose
        // `loadReference` fails is discarded (`placementEngine = nil`)
        // rather than kept half-loaded.
        engineKind = engine
        switch engine {
        case .arkit:
            placementEngine = nil
        case .vision:
            placementEngine = VisionRegistrationEngine()
        case .opencv:
            // wired in Task 2
            placementEngine = nil
        }
        if let pe = placementEngine {
            let engineRefSize = CGSize(width: uprightCG.width, height: uprightCG.height)
            if !pe.loadReference(uprightCG, refSize: engineRefSize, rockQuadPercent: rockQuadPercent) {
                NSLog("AR_DBG placement engine %@ loadReference FAILED, falling back to ARKit", engine.rawValue)
                placementEngine = nil
            } else {
                NSLog("AR_DBG placement engine %@ loaded", engine.rawValue)
            }
        }

        // 0.3m is a nominal physical width -- ARKit only uses it to scale
        // the tracked image's pose in world space. Because we read the
        // corners back out via the anchor's own `physicalSize` (which
        // ARKit derives from this same value plus the image's pixel aspect
        // ratio), the corner projection stays self-consistent regardless of
        // the real-world print size.
        let ref = ARReferenceImage(uprightCG, orientation: .up, physicalWidth: 0.3)
        referenceImage = ref
        self.refWidth = refWidth
        self.refHeight = refHeight

        guard ARWorldTrackingConfiguration.isSupported else {
            NSLog("AR_DBG ARWorldTrackingConfiguration.isSupported=false, refusing to start session")
            completion(false, nil, nil)
            return
        }

        let config = ARWorldTrackingConfiguration()
        config.detectionImages = [ref]
        config.maximumNumberOfTrackedImages = 1

        // Phase 2: load reference into both registration engines
        let rw = refWidth, rh = refHeight, rpath = referenceImagePath
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let vOK = self.visionPipeline.loadReference(path: rpath, refWidth: rw, refHeight: rh)
            NSLog("AR_DBG visionPipeline.loadReference ok=%@", vOK ? "true" : "false")
            if let cg = UIImage(contentsOfFile: rpath)?.cgImage {
                self.orbMatcher.loadReference(cgImage: cg, refWidth: rw, refHeight: rh)
                NSLog("AR_DBG orbMatcher.loadReference complete")
            }
        }

        // Reset hold-last-good state
        _lastGoodCorners = nil
        _weakFrameCount = 0

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.wasTracked = false
            self.frameCounter = 0
            self.pinnedTransform = nil
            self.pinnedPhysicalSize = nil
            self.pinnedManualCorners = nil
            self.sceneView.session.run(config, options: [.resetTracking, .removeExistingAnchors])
            NSLog("AR_DBG ARKit world session.run detectionImages=1")
            completion(true, nil, nil)
        }
    }

    func stopSession() {
        sceneView.session.pause()
        _lastGoodCorners = nil; _weakFrameCount = 0; visionPipeline.reset(); orbMatcher.reset()
        NSLog("AR_DBG ARKit session paused")
    }

    func setMode(_ newMode: ArMode) {
        // Mode no longer gates whether tracking runs (ARKit always tracks
        // once the session is running) -- Dart still reads/writes it via
        // the `masi/ar` MethodChannel, so it is kept here for contract
        // completeness. Switching modes resets ALL pins so tracking starts
        // fresh in the newly-selected mode.
        mode = newMode
        pinnedTransform = nil
        pinnedPhysicalSize = nil
        pinnedManualCorners = nil
        wasTracked = false
        frameCounter = 0
        _lastGoodCorners = nil; _weakFrameCount = 0; visionPipeline.reset(); orbMatcher.reset()
    }

    /// Clears the pinned world transform and re-runs image detection from
    /// scratch, so the user can redo a bad first lock (e.g. one that pinned
    /// onto the wrong surface). Exposed to Dart via the `rescan` method on
    /// the `masi/ar` MethodChannel (see `ArChannelHandler`).
    func rescanSession() {
        pinnedTransform = nil
        pinnedPhysicalSize = nil
        pinnedManualCorners = nil
        wasTracked = false
        frameCounter = 0
        _lastGoodCorners = nil; _weakFrameCount = 0; visionPipeline.reset(); orbMatcher.reset()
        guard let ref = referenceImage else { return }
        guard ARWorldTrackingConfiguration.isSupported else {
            NSLog("AR_DBG ARWorldTrackingConfiguration.isSupported=false, refusing to rescan")
            return
        }
        let config = ARWorldTrackingConfiguration()
        config.detectionImages = [ref]
        config.maximumNumberOfTrackedImages = 1
        DispatchQueue.main.async { [weak self] in
            self?.sceneView.session.run(config, options: [.resetTracking, .removeExistingAnchors])
            NSLog("AR_DBG rescan session.run")
        }
    }

    /// Converts the 4 manually-placed SCREEN corners (TL,TR,BR,BL, in
    /// Flutter view/logical points) into 4 fixed WORLD points by
    /// unprojecting each screen point into a ray and intersecting it with a
    /// plane placed at the current camera-forward distance to the scene
    /// (estimated via a raycast at the corners' centroid, falling back to a
    /// nominal 2.5m). Stores the result in `pinnedManualCorners`, which
    /// `session(_:didUpdate:)` reprojects every frame -- independent of, and
    /// without touching, `pinnedTransform`/`pinnedPhysicalSize`.
    ///
    /// Reports success via `completion` rather than silently no-op'ing: the
    /// lock is refused (completion(false), pin left untouched) when there is
    /// no current frame, tracking is not `.normal` (pinning during poor
    /// tracking bakes in a bad pose), or the computed world points are
    /// degenerate (non-finite).
    func lockManualAlignment(screenCorners: [Double], completion: @escaping (Bool) -> Void) {
        guard screenCorners.count == 8 else {
            completion(false)
            return
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard let frame = self.sceneView.session.currentFrame else {
                completion(false)
                return
            }
            guard case .normal = frame.camera.trackingState else {
                NSLog("AR_DBG manual lock refused: trackingState not normal")
                completion(false)
                return
            }

            let cam = frame.camera.transform
            let camPos = simd_float3(cam.columns.3.x, cam.columns.3.y, cam.columns.3.z)
            let camForward = -simd_normalize(simd_float3(cam.columns.2.x, cam.columns.2.y, cam.columns.2.z))

            let cx = (screenCorners[0] + screenCorners[2] + screenCorners[4] + screenCorners[6]) / 4
            let cy = (screenCorners[1] + screenCorners[3] + screenCorners[5] + screenCorners[7]) / 4

            var d: Float = 2.5
            if let query = self.sceneView.raycastQuery(
                from: CGPoint(x: cx, y: cy),
                allowing: .estimatedPlane,
                alignment: .any
            ), let hit = self.sceneView.session.raycast(query).first {
                let hitPos = simd_float3(
                    hit.worldTransform.columns.3.x,
                    hit.worldTransform.columns.3.y,
                    hit.worldTransform.columns.3.z
                )
                d = simd_length(hitPos - camPos)
            }
            let planePoint = camPos + d * camForward

            var world: [simd_float3] = []
            world.reserveCapacity(4)
            for i in 0..<4 {
                let sx = screenCorners[i * 2]
                let sy = screenCorners[i * 2 + 1]
                let near = self.sceneView.unprojectPoint(SCNVector3(Float(sx), Float(sy), 0))
                let far = self.sceneView.unprojectPoint(SCNVector3(Float(sx), Float(sy), 1))
                let origin = simd_float3(near)
                let dir = simd_normalize(simd_float3(far) - simd_float3(near))
                let denom = simd_dot(dir, camForward)
                let worldPt: simd_float3
                if abs(denom) < 1e-5 {
                    worldPt = planePoint
                } else {
                    let t = simd_dot(planePoint - origin, camForward) / denom
                    worldPt = origin + t * dir
                }
                world.append(worldPt)
            }

            let allFinite = world.allSatisfy { p in
                p.x.isFinite && p.y.isFinite && p.z.isFinite
            }
            guard allFinite else {
                NSLog("AR_DBG manual lock refused: non-finite world point")
                completion(false)
                return
            }

            self.pinnedManualCorners = world
            self.wasTracked = false
            NSLog("AR_DBG manual lock pinned d=%f", d)
            completion(true)
        }
    }

    /// Clears the manual world pin so `session(_:didUpdate:)` falls back to
    /// the auto path (or not-tracked, if auto has no pin either).
    func unlockManualAlignment() {
        pinnedManualCorners = nil
        wasTracked = false
        NSLog("AR_DBG manual unlock")
    }
}

// MARK: - ARCoachingOverlayViewDelegate (standard ARKit "move your device" guidance)

extension ArPlatformView: ARCoachingOverlayViewDelegate {

    func coachingOverlayViewDidActivate(_ coachingOverlayView: ARCoachingOverlayView) {
        NSLog("AR_DBG coaching overlay activated")
    }

    func coachingOverlayViewDidDeactivate(_ coachingOverlayView: ARCoachingOverlayView) {
        NSLog("AR_DBG coaching overlay deactivated")
    }

    /// ARKit shows a "Start Over" affordance inside the overlay when it
    /// cannot recover tracking on its own; wire it to the same
    /// `rescanSession()` path exposed to Dart's manual "rescan" action so it
    /// gets the user back to a clean first lock the same way.
    func coachingOverlayViewDidRequestSessionReset(_ coachingOverlayView: ARCoachingOverlayView) {
        NSLog("AR_DBG coaching overlay requested session reset")
        rescanSession()
    }
}

// MARK: - ARSessionDelegate (per-frame tracking -> screen-space corners)

extension ArPlatformView: ARSessionDelegate {

    /// Whether `projectPoint`'s result [screen] is a usable on-screen
    /// projection: ARKit/SceneKit's `projectPoint` happily projects points
    /// BEHIND the camera too (mirrored/flipped into view space), and can
    /// occasionally produce non-finite output for degenerate inputs. Both
    /// are silently-wrong-not-crashing failure modes that would otherwise
    /// ship a garbage overlay to Dart with `tracking: true`. `screen.z` is
    /// the projected depth in normalized device-coordinate-like space
    /// (`0` = at the near plane, `1` = at the far plane); requiring it
    /// strictly within `(0, 1)` is the standard "is this point actually in
    /// front of the camera and within its clipping range" frustum check.
    private static func isValidProjection(_ screen: SCNVector3) -> Bool {
        guard screen.x.isFinite, screen.y.isFinite, screen.z.isFinite else {
            return false
        }
        return screen.z > 0 && screen.z < 1
    }

    /// Derives the honest `(trackingState, limitedReason)` payload strings
    /// from ARKit's own `ARCamera.TrackingState`, per the Dart contract:
    /// `.normal` -> ("normal", nil); `.limited(reason)` -> ("limited",
    /// <user-facing hint>); `.notAvailable` -> ("notAvailable", nil).
    private static func trackingStateStrings(_ state: ARCamera.TrackingState) -> (state: String, limitedReason: String?) {
        switch state {
        case .normal:
            return ("normal", nil)
        case .limited(let reason):
            // Send the RAW ARKit reason token, not a pre-translated hint --
            // the Dart presentation layer (_ArStatus._limitedReasonHint in
            // ar_screen.dart) owns the user-facing copy and maps these exact
            // token spellings itself.
            let token: String?
            switch reason {
            case .excessiveMotion:
                token = "excessiveMotion"
            case .insufficientFeatures:
                token = "insufficientFeatures"
            case .initializing:
                token = "initializing"
            case .relocalizing:
                token = "relocalizing"
            @unknown default:
                token = nil
            }
            return ("limited", token)
        case .notAvailable:
            return ("notAvailable", nil)
        }
    }

    /// ARImageAnchor arrival (ARKit's own detection event, independent of
    /// whether we go on to pin it -- see the pin-once gate in
    /// `session(_:didUpdate:)`). Purely diagnostic; does not touch pinning.
    func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        for anchor in anchors {
            guard let imageAnchor = anchor as? ARImageAnchor else { continue }
            NSLog(
                "AR_DBG ARImageAnchor arrived name=%@ isTracked=%@",
                imageAnchor.referenceImage.name ?? "unknown",
                imageAnchor.isTracked ? "true" : "false"
            )
        }
    }

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        let fw = CVPixelBufferGetWidth(frame.capturedImage)
        let fh = CVPixelBufferGetHeight(frame.capturedImage)

        let trackingState = frame.camera.trackingState
        let (trackingStateStr, limitedReasonStr) = Self.trackingStateStrings(trackingState)
        let isTrackingNormal: Bool
        if case .normal = trackingState { isTrackingNormal = true } else { isTrackingNormal = false }
        // Render/tracking:true gate: keep the overlay LOCKED (faded, not
        // ghosted) through `.limited` frames -- only `.notAvailable` (truly
        // lost) drops to `tracking: false`. This is intentionally looser
        // than the PIN-ONCE gate below (`isTrackingNormal`, still required
        // to CREATE a pin in the first place) -- once pinned on a solid
        // `.normal` frame, a subsequent dip to `.limited` (e.g.
        // excessiveMotion during normal panning) must not un-glue the
        // overlay from the wall, it should just fade per Dart's
        // derivedConfidence -- see ar_screen.dart's honest-confidence
        // handling of `trackingState: "limited"`.
        let isTrackingAvailable: Bool
        if case .notAvailable = trackingState { isTrackingAvailable = false } else { isTrackingAvailable = true }
        if lastTrackingStateStr != trackingStateStr {
            NSLog(
                "AR_DBG trackingState %@ -> %@ (limitedReason=%@)",
                lastTrackingStateStr ?? "nil",
                trackingStateStr,
                limitedReasonStr ?? "none"
            )
            lastTrackingStateStr = trackingStateStr
        }

        // Pin on the FIRST detection, only once tracking is solid. After that we
        // ride world tracking off the fixed transform and IGNORE further image
        // (re-)detections, which on 3D scenes false-match onto other surfaces.
        if mode == .auto, pinnedTransform == nil, isTrackingNormal,
           let img = frame.anchors.compactMap({ $0 as? ARImageAnchor }).first {
            pinnedTransform = img.transform
            pinnedPhysicalSize = img.referenceImage.physicalSize
            NSLog("AR_DBG pinned world transform")
            NSLog("AR_DBG corner order = straight TL,TR,BR,BL (DEVICE-VERIFY -- see startSession upright fix)")
        }
        let pinned = pinnedTransform
        let phys = pinnedPhysicalSize

        let capturedImage = frame.capturedImage
        let viewBounds = sceneView.bounds.size

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }

            // ── Manual path: unchanged ──
            if let pts = self.pinnedManualCorners {
                var out: [Double] = []
                out.reserveCapacity(8)
                var allValid = true
                for p in pts {
                    let s = self.sceneView.projectPoint(SCNVector3(p.x, p.y, p.z))
                    if !Self.isValidProjection(s) { allValid = false; break }
                    out.append(Double(s.x)); out.append(Double(s.y))
                }
                guard allValid, isTrackingAvailable else {
                    if self.wasTracked { self.wasTracked = false; NSLog("AR_DBG manual pin invalid") }
                    self.channelHandler.sendAlignment(corners: [], tracking: false, frameWidth: 0, frameHeight: 0, trackingState: trackingStateStr, limitedReason: limitedReasonStr)
                    return
                }
                if !self.wasTracked { self.wasTracked = true; NSLog("AR_DBG manual pin tracking=true") }
                self.channelHandler.sendAlignment(corners: out, tracking: true, frameWidth: fw, frameHeight: fh, trackingState: trackingStateStr, limitedReason: limitedReasonStr)

            // ── Continuous registration path (Vision or ORB) ──
            } else if isTrackingAvailable {
                // Run registration on background queue, then publish result on main
                DispatchQueue.global(qos: .userInteractive).async { [weak self] in
                    guard let self else { return }
                    let rw = self.refWidth, rh = self.refHeight
                    guard rw > 0, rh > 0 else { return }

                    // Get the engine result (nil = skip this frame, not a failure)
                    var engineResult: (homography: [Double], confidence: Double, frameW: Int, frameH: Int)?

                    switch Self.registrationMode {
                    case .vision:
                        var vResult: ArAlignmentResult? = nil
                        let sem = DispatchSemaphore(value: 0)
                        self.visionPipeline.processLiveFrame(capturedImage) { r in
                            vResult = r; sem.signal()
                        }
                        sem.wait()
                        if let r = vResult, r.tracking, r.frameWidth > 0 {
                            engineResult = (r.homography, r.confidence, r.frameWidth, r.frameHeight)
                        } else if vResult != nil {
                            engineResult = (ArVisionPipeline.identity, 0.0, 0, 0)
                        } else {
                            engineResult = nil  // throttled frame — skip
                        }

                    case .orb:
                        if let r = self.orbMatcher.matchFrame(capturedImage) {
                            let fW = CVPixelBufferGetWidth(capturedImage)
                            let fH = CVPixelBufferGetHeight(capturedImage)
                            engineResult = (r.homography, r.confidence, fW, fH)
                        } else {
                            engineResult = (ArVisionPipeline.identity, 0.0, 0, 0)
                        }
                    }

                    guard let result = engineResult else { return }  // throttled frame

                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }

                        let confidence = result.confidence
                        let frameW = result.frameW, frameH = result.frameH

                        // Map CV confidence → trackingState for Dart's derivedConfidence
                        let cvTrackingState: String
                        let cvLimitedReason: String?
                        if confidence >= 0.5 { cvTrackingState = "normal"; cvLimitedReason = nil }
                        else if confidence >= 0.2 { cvTrackingState = "limited"; cvLimitedReason = "insufficientFeatures" }
                        else { cvTrackingState = "limited"; cvLimitedReason = "insufficientFeatures" }

                        if confidence >= 0.2, frameW > 0, frameH > 0 {
                            // Project 4 reference corners through the homography → live-frame-pixel → screen
                            let h = result.homography
                            let refCorners: [(Double, Double)] = [(0, 0), (Double(rw), 0), (Double(rw), Double(rh)), (0, Double(rh))]

                            // Use ARFrame.displayTransform via sceneView.session.currentFrame (main queue)
                            let xform: CGAffineTransform
                            if let currentFrame = self.sceneView.session.currentFrame {
                                xform = currentFrame.displayTransform(for: .portrait, viewportSize: viewBounds)
                            } else {
                                // Fallback: simple scale (will be slightly off but better than nothing)
                                xform = CGAffineTransform(scaleX: viewBounds.width / CGFloat(frameW), y: viewBounds.height / CGFloat(frameH))
                            }

                            var corners: [Double] = []
                            var projectionOK = true
                            for (rx, ry) in refCorners {
                                let wx = h[0]*rx + h[1]*ry + h[2]
                                let wy = h[3]*rx + h[4]*ry + h[5]
                                let wz = h[6]*rx + h[7]*ry + h[8]
                                guard abs(wz) > 1e-6 else { projectionOK = false; break }
                                let lx = wx/wz, ly = wy/wz
                                let nx = lx / Double(frameW), ny = ly / Double(frameH)
                                let pt = CGPoint(x: nx, y: ny).applying(xform)
                                corners.append(Double(pt.x)); corners.append(Double(pt.y))
                            }

                            guard projectionOK, corners.count == 8 else {
                                self._weakFrameCount += 1
                                if self._weakFrameCount >= self._weakFrameLimit {
                                    if self.wasTracked { self.wasTracked = false; NSLog("AR_DBG reg lost tracking (sustained weak)") }
                                    self.channelHandler.sendAlignment(corners: [], tracking: false, frameWidth: 0, frameHeight: 0, trackingState: "limited", limitedReason: "insufficientFeatures")
                                }
                                return
                            }

                            self._weakFrameCount = 0
                            self._lastGoodCorners = corners
                            if !self.wasTracked { self.wasTracked = true; NSLog("AR_DBG reg tracking=true mode=%@", Self.registrationMode == .vision ? "vision" : "orb") }
                            self.frameCounter += 1
                            if self.frameCounter == 1 || self.frameCounter % 60 == 0 {
                                NSLog("AR_DBG reg corners=%@ confidence=%.2f", corners.description, confidence)
                            }
                            self.channelHandler.sendAlignment(corners: corners, tracking: true, frameWidth: frameW, frameHeight: frameH, trackingState: cvTrackingState, limitedReason: cvLimitedReason)

                        } else {
                            // Low confidence or degenerate homography
                            self._weakFrameCount += 1
                            if self._weakFrameCount >= self._weakFrameLimit {
                                if self.wasTracked { self.wasTracked = false; NSLog("AR_DBG reg lost tracking (conf=%.2f)", confidence) }
                                self.channelHandler.sendAlignment(corners: [], tracking: false, frameWidth: 0, frameHeight: 0, trackingState: cvTrackingState, limitedReason: cvLimitedReason)
                                self._lastGoodCorners = nil
                            } else if let last = self._lastGoodCorners {
                                // Hold last good (fade via existing confidence mechanism)
                                self.channelHandler.sendAlignment(corners: last, tracking: true, frameWidth: frameW > 0 ? frameW : 1, frameHeight: frameH > 0 ? frameH : 1, trackingState: "limited", limitedReason: "insufficientFeatures")
                            }
                        }
                    }
                }

            // ── Not tracking ──
            } else {
                if self.wasTracked { self.wasTracked = false; NSLog("AR_DBG tracking=false (notAvailable)") }
                self._lastGoodCorners = nil
                self._weakFrameCount = 0
                self.channelHandler.sendAlignment(corners: [], tracking: false, frameWidth: 0, frameHeight: 0, trackingState: trackingStateStr, limitedReason: limitedReasonStr)
            }
        }
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        NSLog("AR_DBG ARKit session didFailWithError=%@", error.localizedDescription)
        DispatchQueue.main.async { [weak self] in
            self?.wasTracked = false
            self?.lastTrackingStateStr = "notAvailable"
            self?.channelHandler.sendAlignment(
                corners: [], tracking: false, frameWidth: 0, frameHeight: 0,
                trackingState: "notAvailable", limitedReason: nil
            )
        }
    }
}
