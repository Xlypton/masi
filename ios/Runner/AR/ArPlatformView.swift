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

    /// Redraws `image` UPRIGHT, baking in its `imageOrientation` into the
    /// pixel buffer itself. `UIImage.cgImage` is the RAW decoded pixel
    /// buffer with EXIF orientation discarded; feeding THAT straight into
    /// `ARReferenceImage` (as this used to do) while Dart's own reference
    /// dimensions are EXIF-oriented made portrait reference photos detect
    /// rotated/skewed. Returns `image.cgImage` unchanged when already `.up`
    /// (no redraw needed).
    private static func uprightCGImage(from image: UIImage) -> CGImage? {
        if image.imageOrientation == .up { return image.cgImage }
        let renderer = UIGraphicsImageRenderer(size: image.size)
        return renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: image.size)) }.cgImage
    }

    func startSession(
        referenceImagePath: String,
        refWidth: Int,
        refHeight: Int,
        routesJson: String,
        completion: @escaping (Bool, [Double]?) -> Void
    ) {
        NSLog("AR_DBG startSession invoked")
        // `routesJson` is accepted for contract completeness -- the native
        // side does not need route geometry: Dart owns and draws the route
        // overlay itself, deriving its transform from the tracked corners
        // this view sends, so `routesJson` is intentionally unused here.
        _ = routesJson

        guard let uiImage = UIImage(contentsOfFile: referenceImagePath), let rawCG = uiImage.cgImage else {
            NSLog("AR_DBG ref decode FAILED")
            completion(false, nil)
            return
        }

        // EXIF orientation fix -- see `uprightCGImage` doc above.
        guard let uprightCG = Self.uprightCGImage(from: uiImage) else {
            NSLog("AR_DBG ref upright redraw FAILED")
            completion(false, nil)
            return
        }
        NSLog(
            "AR_DBG ref exif imageOrientation=%d rawSize=%dx%d uprightSize=%dx%d",
            uiImage.imageOrientation.rawValue, rawCG.width, rawCG.height, uprightCG.width, uprightCG.height
        )

        // Rock segmentation (iOS 17+, best-effort): crop the reference photo
        // down to the detected foreground (the rock/wall) so ARKit's
        // detectionImages target is tighter and less cluttered with
        // background. Any failure (unsupported OS, no confident instance,
        // Vision error) falls back to the full upright photo untouched --
        // see `ArRockSegmentation.segmentAndCrop`.
        var referenceCG = uprightCG
        var rockQuadPercent: [Double]? = nil
        if let crop = ArRockSegmentation.segmentAndCrop(uprightCG) {
            referenceCG = crop.cgImage
            rockQuadPercent = crop.quadPercent
            NSLog("AR_DBG seg: using rock crop quad=\(crop.quadPercent)")
        } else {
            NSLog("AR_DBG seg: no crop, using full upright photo")
        }

        // 0.3m is a nominal physical width -- ARKit only uses it to scale
        // the tracked image's pose in world space. Because we read the
        // corners back out via the anchor's own `physicalSize` (which
        // ARKit derives from this same value plus the image's pixel aspect
        // ratio), the corner projection stays self-consistent regardless of
        // the real-world print size.
        let ref = ARReferenceImage(referenceCG, orientation: .up, physicalWidth: 0.3)
        referenceImage = ref

        guard ARWorldTrackingConfiguration.isSupported else {
            NSLog("AR_DBG ARWorldTrackingConfiguration.isSupported=false, refusing to start session")
            completion(false, nil)
            return
        }

        let config = ARWorldTrackingConfiguration()
        config.detectionImages = [ref]
        config.maximumNumberOfTrackedImages = 1

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.wasTracked = false
            self.frameCounter = 0
            self.pinnedTransform = nil
            self.pinnedPhysicalSize = nil
            self.pinnedManualCorners = nil
            self.sceneView.session.run(config, options: [.resetTracking, .removeExistingAnchors])
            NSLog("AR_DBG ARKit world session.run detectionImages=1")
            completion(true, rockQuadPercent)
        }
    }

    func stopSession() {
        sceneView.session.pause()
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

        // `projectPoint` reads current render/view-port state, and the
        // event sink must be called on the main thread -- ARSessionDelegate
        // callbacks arrive on ARKit's own background queue, so hop to main
        // before doing either.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let pts = self.pinnedManualCorners {
                // Manual world pin takes precedence -- reproject the 4 fixed
                // world points locked in by `lockManualAlignment`.
                var out: [Double] = []
                out.reserveCapacity(8)
                var allValid = true
                for p in pts {
                    let s = self.sceneView.projectPoint(SCNVector3(p.x, p.y, p.z))
                    if !Self.isValidProjection(s) {
                        allValid = false
                        break
                    }
                    out.append(Double(s.x)); out.append(Double(s.y))
                }
                guard allValid, isTrackingAvailable else {
                    // A corner projected behind the camera (or produced a
                    // non-finite screen point), OR ARKit's own tracking state
                    // is `.notAvailable` (truly lost, not merely `.limited`)
                    // -- publishing it would send a garbage/flipped/dishonest
                    // overlay for this frame, so fall back to the
                    // not-tracked payload exactly like the `else` branch.
                    if self.wasTracked { self.wasTracked = false; NSLog("AR_DBG manual pin invalid projection or non-normal tracking, tracking=false") }
                    self.channelHandler.sendAlignment(
                        corners: [], tracking: false, frameWidth: 0, frameHeight: 0,
                        trackingState: trackingStateStr, limitedReason: limitedReasonStr
                    )
                    return
                }
                if !self.wasTracked { self.wasTracked = true; NSLog("AR_DBG manual pin tracking=true") }
                self.channelHandler.sendAlignment(
                    corners: out, tracking: true, frameWidth: fw, frameHeight: fh,
                    trackingState: trackingStateStr, limitedReason: limitedReasonStr
                )
            } else if let t = pinned, let size = phys {
                // EXISTING auto path -- unchanged aside from the corner
                // mapping below.
                let hw = Float(size.width) / 2
                let hh = Float(size.height) / 2
                // DEVICE-VERIFY: straight (un-hacked) corner mapping. The
                // reference image handed to ARKit is now genuinely EXIF-
                // upright (see `uprightCGImage` in `startSession`), so the
                // empirical quarter-turn order that used to compensate for
                // feeding ARKit RAW (non-upright) pixels is no longer
                // appropriate -- this is the naive TL/TR/BR/BL reading. It
                // MUST be confirmed on a physical device with a portrait
                // reference photo: if the overlay comes out rotated/skewed,
                // this mapping is the first place to look.
                let locals: [simd_float4] = [
                    simd_float4(-hw, 0, -hh, 1),  // TL -> (0,0)
                    simd_float4( hw, 0, -hh, 1),  // TR -> (w,0)
                    simd_float4( hw, 0,  hh, 1),  // BR -> (w,h)
                    simd_float4(-hw, 0,  hh, 1),  // BL -> (0,h)
                ]
                var out: [Double] = []
                out.reserveCapacity(8)
                var allValid = true
                for l in locals {
                    let world = t * l
                    let screen = self.sceneView.projectPoint(SCNVector3(world.x, world.y, world.z))
                    if !Self.isValidProjection(screen) {
                        allValid = false
                        break
                    }
                    out.append(Double(screen.x)); out.append(Double(screen.y))
                }
                guard allValid, isTrackingAvailable else {
                    // A pinned corner projected behind the camera (or
                    // produced a non-finite screen point), OR ARKit's own
                    // tracking state is `.notAvailable` (truly lost, not
                    // merely `.limited`) -- abandon this frame rather than
                    // publish a garbage/dishonest overlay, falling back to
                    // the same not-tracked payload as the `else` branch
                    // below.
                    if self.wasTracked { self.wasTracked = false; NSLog("AR_DBG ARKit invalid projection or non-normal tracking, tracking=false") }
                    self.channelHandler.sendAlignment(
                        corners: [], tracking: false, frameWidth: 0, frameHeight: 0,
                        trackingState: trackingStateStr, limitedReason: limitedReasonStr
                    )
                    return
                }
                if !self.wasTracked { self.wasTracked = true; NSLog("AR_DBG ARKit tracking=true (pinned)") }
                self.frameCounter += 1
                if self.frameCounter == 1 || self.frameCounter % 60 == 0 {
                    NSLog("AR_DBG ARKit pinned corners=%@", out.description)
                }
                self.channelHandler.sendAlignment(
                    corners: out, tracking: true, frameWidth: fw, frameHeight: fh,
                    trackingState: trackingStateStr, limitedReason: limitedReasonStr
                )
            } else {
                // EXISTING not-tracked path -- unchanged.
                if self.wasTracked { self.wasTracked = false; NSLog("AR_DBG ARKit tracking=false") }
                self.channelHandler.sendAlignment(
                    corners: [], tracking: false, frameWidth: 0, frameHeight: 0,
                    trackingState: trackingStateStr, limitedReason: limitedReasonStr
                )
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
