# AR Route-Placement Engines Implementation Plan

> **For agentic workers:** implement task-by-task. Each task ends with an independently testable deliverable + a commit. The agent that writes a task never verifies it — a separate clean-context agent re-runs the assertions.

**Goal:** Two interchangeable continuous-registration placement engines (Apple Vision + OpenCV feature-matching), selectable at runtime alongside the ARKit baseline, both feeding the existing overlay corner seam — so the user can A/B them on device and keep one.

**Architecture:** Low-invasion. ARKit pin-once stays the untouched default. A native `RockRegistrationEngine` protocol abstracts frame→corners; for the two new variants, `ArPlatformView.session(_:didUpdate:)` feeds `frame.capturedImage` to the selected engine and publishes its corners through the unchanged `sendAlignment` contract. Engine chosen via a `start` arg driven by a Dart `arEngineProvider`.

**Tech Stack:** Swift + Obj-C++ (OpenCV bridge), Apple Vision, `yeatse/opencv-spm` 5.0.0 (SPM binary xcframework), Flutter/Dart, Riverpod v3.

## Global Constraints

- **PATH prefix EVERY flutter/dart/xcrun/pod command:** `export PATH="/opt/homebrew/bin:$PATH" && `
- **iOS uses SPM, not CocoaPods** — no Podfile; add OpenCV as an SPM package, never a pod. Never run `pod install`. Never `flutter clean`.
- **Device install is IN-PLACE only** (morning, if reached): `flutter build ios --release -t lib/main.dart && xcrun devicectl device install app --device 00008140-0011585936EB001C build/ios/iphoneos/Runner.app` with `dangerouslyDisableSandbox:true` + phone unlocked. NEVER `flutter install`; NEVER uninstall (wipes login session).
- **Riverpod v3:** `Notifier`/`NotifierProvider`, never `StateProvider`.
- **Icons:** `MasiIcon` only — never `Icons.X`/`CupertinoIcons.X`.
- **Commit to `main` with explicit pathspec.** Leave pre-existing staged `Runner.xcscheme` (M) and untracked `.wrangler/`, `android/build/`, `masi_icons_v5_svg/**` alone. Conventional commits, trailer `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`. Never push.
- **Never print/commit secrets** (`~/.config/climbtopo-mgmt-token`, `sbp_`/`sb_secret_` keys).
- **`flutter analyze` = 0 and `flutter test` green on every commit.**
- Corner order everywhere is **TL, TR, BR, BL** (matches existing `sendAlignment`/`_parseCorners`). Corners are logical view-space points (same space ARKit `projectPoint` produces).

## Interfaces locked across tasks

Native (`ios/Runner/AR/RockRegistrationEngine.swift`):
```swift
struct EngineAlignment {
  let corners: [Double]   // 8 doubles, TL,TR,BR,BL, view-space logical points
  let confidence: Double  // 0..1
  let tracking: Bool
}
protocol RockRegistrationEngine: AnyObject {
  /// upright reference CGImage + rock quad (8 normalized [0..1] doubles, TL,TR,BR,BL of the oriented photo; empty ⇒ whole image)
  func loadReference(_ image: CGImage, refSize: CGSize, rockQuadPercent: [Double]) -> Bool
  /// one live frame → reference's 4 corners projected into view-space; nil ⇒ no match this frame
  func process(pixelBuffer: CVPixelBuffer, viewSize: CGSize) -> EngineAlignment?
  func reset()
}
enum ArPlacementEngineKind: String { case arkit, vision, opencv }
```

Dart (`lib/features/ar/application/ar_controller.dart`):
```dart
enum ArPlacementEngine { arkit, vision, opencv }
final arEngineProvider = NotifierProvider<ArEngineController, ArPlacementEngine>(ArEngineController.new);
class ArEngineController extends Notifier<ArPlacementEngine> {
  ArPlacementEngine build() => ArPlacementEngine.arkit;
  void cycle();               // arkit→vision→opencv→arkit
  void set(ArPlacementEngine e);
}
```

Channel additions (backward-compatible):
- `ArChannel.start({..., ArPlacementEngine engine = ArPlacementEngine.arkit, List<double>? rockQuad})` → sends `engine: engine.name`, and `rockQuad: [8]` when non-null.
- `ArChannelHandler` `"start"` parses `engine` (default `"arkit"`) + optional `rockQuad`; `ArSessionControlling.startSession(...)` gains `engine: ArPlacementEngineKind, rockQuadPercent: [Double]`.
- `sendAlignment(..., confidence: Double)` → payload `"confidence"` (Double). `ArAlignment.fromMap` already parses it; wire into `derivedConfidence`.

---

## Task 1: Native protocol + Vision engine + ArPlatformView switch + channel contract

**Files:**
- Create: `ios/Runner/AR/RockRegistrationEngine.swift`
- Create: `ios/Runner/AR/VisionRegistrationEngine.swift`
- Modify: `ios/Runner/AR/ArPlatformView.swift` (didUpdate switch, engine field, startSession loads reference)
- Modify: `ios/Runner/AR/ArChannelHandler.swift` (start parses `engine`+`rockQuad`; sendAlignment gains `confidence`; `ArSessionControlling` signature)
- Reuse: `ios/Runner/AR/ArVisionPipeline.swift` (dormant; wrap it)

**Interfaces — Produces:** the protocol + `EngineAlignment` + `ArPlacementEngineKind` above; `VisionRegistrationEngine: RockRegistrationEngine`.

**Details:**
- `VisionRegistrationEngine` holds an `ArVisionPipeline`, the reference `CGImage`+`refSize`, and the rock crop rect (from `rockQuadPercent` bbox; whole image if empty). `process`: call the pipeline to get the reference→live pixel homography `H` (row-major 3×3); reproject the **reference's 4 corners** (0,0),(w,0),(w,h),(0,h) through `H` into live-pixel space; map live-pixel → view-space via the aspect-fill letterbox transform below; build `EngineAlignment`. Confidence: start from the pipeline's finite+non-degenerate check, then grade by corner-quad sanity — convex + area ratio within [0.02, 4.0] of the reference footprint ⇒ up to 0.85, else scale down; non-finite/concave ⇒ 0 and `tracking:false`.
- **Aspect-fill letterbox transform** (live pixel-buffer `(bw,bh)` displayed aspect-fill in `viewSize (vw,vh)`): `scale = max(vw/bw, vh/bh)`; `ox = (vw - bw*scale)/2`; `oy = (vh - bh*scale)/2`; `viewPt = (px*scale + ox, py*scale + oy)`. Put this in a `static func livePixelToView(_ p: CGPoint, bufferSize:, viewSize:) -> CGPoint` on `RockRegistrationEngine.swift` (shared by both engines) with a unit test in Task 3.
- `ArPlatformView`: add `private var placementEngine: RockRegistrationEngine?` and `private var engineKind: ArPlacementEngineKind = .arkit`. In `startSession`, after decoding the upright CGImage, if `engineKind != .arkit` build the engine (`VisionRegistrationEngine` for `.vision`; `.opencv` wired in Task 2) and `loadReference(uprightCG, refSize:, rockQuadPercent:)`; if load fails, set `placementEngine = nil` (fall back to ARKit). In `session(_:didUpdate:)`, at the top of the main-queue block: `if let e = placementEngine { if let a = e.process(pixelBuffer: frame.capturedImage, viewSize: sceneView.bounds.size) { channelHandler.sendAlignment(corners: a.corners, tracking: a.tracking, frameWidth: bw, frameHeight: bh, trackingState: a.tracking ? "normal" : "notAvailable", confidence: a.confidence) } else { channelHandler.sendAlignment(corners: [], tracking: false, frameWidth: bw, frameHeight: bh, trackingState: "notAvailable", confidence: 0) }; return }` — the existing ARKit block runs only when `placementEngine == nil`.
- `ArChannelHandler`: `"start"` reads `engine` (String, default `"arkit"`) → `ArPlacementEngineKind(rawValue:) ?? .arkit`, and optional `rockQuad` (`[Double]` count 8, else `[]`). Extend `ArSessionControlling.startSession(referenceImagePath:refWidth:refHeight:routesJson:engine:rockQuadPercent:completion:)`. `sendAlignment` gains `confidence: Double = 0` and, when the engine path is active, adds `payload["confidence"] = confidence`.

**Assertions (verify):**
1. `RockRegistrationEngine.swift` + `VisionRegistrationEngine.swift` exist; protocol + `EngineAlignment` + `ArPlacementEngineKind` + `livePixelToView` present.
2. `ArPlatformView.session(_:didUpdate:)` routes to `placementEngine.process(...)` when set and to the original ARKit block otherwise; `startSession` loads the reference into the engine and falls back to nil on load failure.
3. `ArChannelHandler` parses `engine`+`rockQuad`; `sendAlignment` emits `confidence`; `ArSessionControlling` signature updated and `ArPlatformView` conforms.
4. `export PATH="/opt/homebrew/bin:$PATH" && flutter build ios --simulator --config-only` (or a full sim build) **compiles** — no OpenCV yet.
5. When `engine=='arkit'` (default), the existing ARKit path is byte-for-byte reachable (no behavior change): `placementEngine` is nil ⇒ original block runs.

**Commit:** `feat(ar): pluggable RockRegistrationEngine + Vision registration engine (#66)`

---

## Task 2: OpenCV engine — SPM dep + Obj-C++ bridge + Swift wrapper

**Files:**
- Modify: `ios/Runner.xcodeproj/project.pbxproj` (add SPM package `yeatse/opencv-spm` 5.0.0, product `OpenCV` on the Runner target + Frameworks phase)
- Create: `ios/Runner/AR/RockMatcher.h`, `ios/Runner/AR/RockMatcher.mm` (Obj-C++)
- Modify: `ios/Runner/Runner-Bridging-Header.h` (import `RockMatcher.h`)
- Create: `ios/Runner/AR/OpenCvRegistrationEngine.swift`
- Modify: `ios/Runner/AR/ArPlatformView.swift` (build `OpenCvRegistrationEngine` for `.opencv`)

**Interfaces — Consumes:** `RockRegistrationEngine`, `EngineAlignment`, `livePixelToView` (Task 1). **Produces:** `OpenCvRegistrationEngine: RockRegistrationEngine`.

**SPM add (project.pbxproj) — the fiddly step, do carefully:**
- Add `XCRemoteSwiftPackageReference "opencv-spm"` object: `repositoryURL = "https://github.com/yeatse/opencv-spm.git"; requirement = { kind = exactVersion; version = 5.0.0; }`.
- Append its id to `PBXProject.packageReferences`.
- Add `XCSwiftPackageProductDependency` object: `productName = OpenCV; package = <ref id>;`.
- Append its id to the Runner native target's `packageProductDependencies`.
- Add a `PBXBuildFile` `{ productRef = <product dep id> }` and append to the Runner `PBXFrameworksBuildPhase.files`.
- Build resolves + writes `Runner.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` (network fetch ⇒ build must run with `dangerouslyDisableSandbox:true`).
- If raw pbxproj editing fails to resolve, STOP and record the exact manual Xcode step in the morning note; commit the bridge + wrapper + tests regardless (they're independently reviewable), and leave `.opencv` selecting a graceful "engine unavailable → fall back to ARKit" path.

**`RockMatcher` (Obj-C++), pure OpenCV, no ARKit/Vision:**
```objc
// RockMatcher.h
@interface RockMatcher : NSObject
// rockQuad: 8 normalized doubles TL,TR,BR,BL (empty ⇒ whole image). Returns NO if too few features.
- (BOOL)loadReferenceCGImage:(CGImageRef)image rockQuad:(NSArray<NSNumber *> *)rockQuad;
// Returns @[x0,y0,...,x3,y3, inlierRatio] (10 numbers) in LIVE-PIXEL space, or nil if no reliable homography.
- (NSArray<NSNumber *> * _Nullable)matchPixelBuffer:(CVPixelBufferRef)pixelBuffer;
- (void)reset;
@end
```
`.mm`: convert reference CGImage → BGRA `cv::Mat` → gray, crop to rock bbox (from `rockQuad`), `cv::ORB::create(1500)` detect+compute once, store keypoints/descriptors + crop-corner offsets. `matchPixelBuffer`: lock buffer, wrap BGRA plane → gray Mat, ORB detect+compute, `cv::BFMatcher(cv::NORM_HAMMING)` knnMatch k=2 + Lowe ratio 0.75, require ≥12 good matches, `cv::findHomography(refPts, livePts, cv::RANSAC, 5.0, mask)`, require inliers ≥ 12 and inlierRatio ≥ 0.25, reproject the 4 rock-crop corners (in full-reference-pixel coords) via the homography, return the 8 live-pixel corners + inlierRatio; nil otherwise. Guard empty descriptors.
- `OpenCvRegistrationEngine`: holds a `RockMatcher`, `refSize`. `loadReference` → `matcher.loadReferenceCGImage`. `process` → `matcher.matchPixelBuffer`; map each live-pixel corner via `livePixelToView`; confidence = `min(1.0, inlierRatio * 1.5)` clamped, `tracking = result != nil`. nil result ⇒ return nil.
- `ArPlatformView` `.opencv` case builds `OpenCvRegistrationEngine`.

**Assertions (verify):**
1. `project.pbxproj` references `yeatse/opencv-spm` (5.0.0) with product `OpenCV` on the Runner target; `Package.resolved` lists it after a resolve.
2. `RockMatcher.h/.mm` + `OpenCvRegistrationEngine.swift` exist; bridging header imports `RockMatcher.h`; no `dart:` / ARKit deps in the bridge.
3. `export PATH="/opt/homebrew/bin:$PATH" && flutter build ios --simulator` **compiles and links OpenCV** (sim slices) — run with `dangerouslyDisableSandbox:true`.
4. `.opencv` selection builds `OpenCvRegistrationEngine` in `ArPlatformView`.

**Commit:** `feat(ar): OpenCV feature-matching registration engine + SPM dep (#66)`

---

## Task 3: Swift XCTest — synthetic warped-pair correctness (the sim proof)

**Files:**
- Create: `ios/RunnerTests/RockMatcherTests.swift` (or add to existing test target; create the target's minimal wiring if absent)
- Test: OpenCV homography recovery + `livePixelToView` transform; Vision recovery best-effort (skip-guard if the request is unavailable on sim).

**Details:**
- Programmatically render a **feature-rich** reference image (e.g. draw many high-contrast filled rectangles/checker blobs at known positions into a `CGContext`), pick a known homography `H` (moderate perspective, e.g. rotate ~15° + slight shear), warp the reference into a "live" image via Core Image/`cv::warpPerspective`, wrap it as a `CVPixelBuffer`.
- Feed reference + warped to `RockMatcher`; assert recovered 4 live-pixel corners are within **8 px** of `H`·(reference corners). Assert `inlierRatio > 0.4`.
- Unit-test `livePixelToView`: buffer 1920×1080 aspect-fill in view 390×844 → check a known point maps correctly (centre stays centre; scale = max ratio; offsets symmetric).
- Vision: attempt a `VisionRegistrationEngine.process` on the same pair; if `VNHomographicImageRegistrationRequest` returns nil on sim, `XCTSkip` with a note (device-only) rather than fail — the OpenCV assertion is the hard gate.

**Assertions (verify):**
1. `export PATH="/opt/homebrew/bin:$PATH" && xcodebuild test -scheme Runner -destination 'platform=iOS Simulator,name=iPhone 17'` (or `flutter`-driven) runs `RockMatcherTests`; OpenCV recovery + letterbox tests **pass** on the simulator.
2. Vision test either passes or `XCTSkip`s (never a hard fail on sim).

**Commit:** `test(ar): sim XCTest — OpenCV homography recovery on synthetic warped pairs (#66)`

---

## Task 4: Dart — engine provider + FAB + confidence wiring + tests

**Files:**
- Modify: `lib/features/ar/application/ar_controller.dart` (`ArPlacementEngine` enum, `arEngineProvider`, `ArEngineController`)
- Modify: `lib/features/ar/application/ar_channel.dart` (`start` gains `engine`+`rockQuad`; `derivedConfidence` blends numeric `confidence`)
- Modify: `lib/features/ar/presentation/ar_screen.dart` (`_startSession` reads engine+rock quad → `start`; `ar-engine-toggle` FAB in `_ArControls` cycles + restarts + shows active engine label)
- Create/Modify tests: `test/features/ar/application/ar_engine_provider_test.dart`, extend `test/features/ar/application/ar_channel_test.dart` (start args + confidence blend)

**Details:**
- `ArEngineController.cycle()` arkit→vision→opencv→arkit; `set(e)`. In-memory Notifier (mirror `arRockHighlightProvider`).
- `_startSession`: `final engine = ref.read(arEngineProvider); final rockQuad = rockBoxCornersNorm(widget.routes)` — reuse the existing rock quad source (or the segmentation quad if already on `ArState`); pass both to `channel.start`.
- `ArChannel.start`: add `engine`/`rockQuad` to the args map; keep the 3 existing keys.
- `ArAlignment.derivedConfidence`: when `confidence > 0`, return `min(bandConfidence, confidence)` (numeric engine score can only *lower* the band, surfacing the fade + manual affordance); when `confidence == 0`, keep the current band-only behaviour. Do not regress the ARKit path (ARKit sends no `confidence` ⇒ 0 ⇒ unchanged).
- FAB: `ar-engine-toggle` (MasiIcon, e.g. `masi_ar_peak` or a layers glyph) cycles the engine, calls `_startSession` again to restart with the new engine, and a small caption/pill shows `arkit`/`vision`/`opencv`. Place next to `ar-mode-toggle` in `_ArControls`.

**Assertions (verify):**
1. `arEngineProvider` defaults to `arkit`; `cycle()` walks arkit→vision→opencv→arkit; `set()` works — unit test green.
2. `channel.start` sends `engine` + (when non-null) `rockQuad`; existing keys intact — test green.
3. `derivedConfidence`: `confidence:0`→band unchanged; `confidence:0.2,band:1.0`→0.2; `confidence:0.9,band:0.35`→0.35 — test green.
4. `ar-engine-toggle` FAB present, MasiIcon, cycles + restarts session, shows active engine; no `Icons.`/`CupertinoIcons.` introduced.
5. `export PATH="/opt/homebrew/bin:$PATH" && flutter analyze` = 0; `flutter test` green.

**Commit:** `feat(ar): Dart engine A/B selector + numeric confidence wiring (#66)`

---

## Task 5: Independent verify + park

**Not an implementer task — a clean-context verify agent** given only this plan's assertions + the diff. Re-runs: `flutter analyze` (0), `flutter test` (green), sim build compiles+links OpenCV, XCTest OpenCV recovery passes, and adversarially reviews the diff against every assertion above. Then:
- Update memory (`masi-ar-phase1-shipped` → note Phase 2 both-variants built + sim-tested + parked; new `masi-ar-phase2-two-engines` if warranted).
- Write a concise **morning-test note** (in the journal / a scratch note): how to A/B on device — open a topo → AR → `ar-engine-toggle` cycles arkit→vision→opencv, judge which holds routes on the wall at angle/lighting; the honest bar; the OpenCV size cost + the slim-build follow-up if it wins.
- Confirm no stray edits to pre-existing staged/untracked files.

**No new commit unless verify finds fixes** (then a `fix(ar): …` per fix, re-verified).

## Self-review notes
- Types consistent: `EngineAlignment`, `RockRegistrationEngine`, `ArPlacementEngineKind`/`ArPlacementEngine`, `livePixelToView`, `arEngineProvider`, `sendAlignment(...confidence:)` used identically across tasks.
- Spec coverage: Variant A = Task 1; Variant B = Task 2; sim correctness = Task 3; A/B UX + confidence = Task 4; verify/park = Task 5. Graceful degradation if OpenCV SPM link can't land is called out in Task 2.
- Corner order TL,TR,BR,BL fixed globally; confidence can only lower the band (no false-confidence regression on ARKit).
