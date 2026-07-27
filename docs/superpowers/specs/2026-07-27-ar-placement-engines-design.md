# AR Route-Placement Engines (Phase 2 of #66/#68) — Design

**Status:** approved (design), autonomous overnight build authorized 2026-07-27. User will A/B on device in the morning and pick one to keep.

## Problem

Phase 1 (rock recognition) shipped: the stored topo photo is segmented into a per-pixel rock mask, and the AR overlay is cropped/silhouetted to the rock. Phase 2 is **placement**: routes must land *on the wall* and stay there across viewing angle, lighting, and revisiting the crag later. The current placement — ARKit `ARWorldTrackingConfiguration` + `detectionImages` image-anchor, **pinned once** on first `.normal` detection, then reprojected each frame off a fixed world transform — is unstable: corners fly, `tracking` flips, and routes float mid-air at oblique views. There is no re-match / relocalization.

## Goal

Two interchangeable **registration engines**, both replacing pin-once with **continuous per-frame reference→live homography**, both emitting the exact same corner payload into the existing overlay seam, selectable at runtime so the two (plus the ARKit baseline) can be compared head-to-head on device:

- **Variant A — Vision** (`VNHomographicImageRegistrationRequest`): Apple-native, zero binary weight, fast. Strong at modest baseline; designed for small-motion registration, so wide baseline degrades. This was the originally-approved design.
- **Variant B — OpenCV** (ORB/AKAZE features + BFMatcher + RANSAC `findHomography`): heavier binary (`yeatse/opencv-spm` 5.0.0 prebuilt xcframework via SPM), but genuinely robust to wide baseline / oblique angle / lighting — the "more robust version" requested.

Both degrade gracefully to the existing **manual-align** fallback when confidence stays low.

## Non-goals

- No custom slimmed OpenCV build tonight (use the prebuilt xcframework; slim later only if OpenCV wins).
- No 3D plane / world-anchor reconstruction (explicitly rejected earlier — this is 2D image registration).
- No mask-persistence/sync to web/friends (deferred).
- Web unchanged (manual-align only; `arAutoTrackingProvider` already forces manual on web).

## Architecture

Low-invasion. ARKit stays the untouched default path. A `RockRegistrationEngine` protocol abstracts "given this frame's `CVPixelBuffer` + the reference's 4 corners in reference-pixel space + the view size, return the reference's 4 corners projected into view space + a confidence." For the two new variants, `ArPlatformView.session(_:didUpdate:)` feeds `frame.capturedImage` (already read at `ArPlatformView.swift:392`) to the selected engine and publishes its corners through the **unchanged** `ArChannelHandler.sendAlignment(...)` contract. When engine == `.arkit`, the existing pin-once + `projectPoint` block runs verbatim.

```
select engine (Dart arEngineProvider) ──start arg──▶ ArPlatformView.engine
                                                         │
ARFrame.capturedImage (every frame) ─────────────────────┤
   engine == .arkit  → existing pin-once projectPoint block  (unchanged)
   engine == .vision → VisionRegistrationEngine  ┐
   engine == .opencv → OpenCvRegistrationEngine   ├─▶ corners[8] + confidence
                                                  ┘        │
                              ArChannelHandler.sendAlignment(corners, tracking, trackingState, confidence)
                                                           │  (EventChannel "masi/ar/alignment")
Dart: ArAlignment.fromMap → CornerSmoother → Homography.fromQuad(refCorners, corners) → ArOverlayPainter
```

### Components

**Native (`ios/Runner/AR/`):**

- `RockRegistrationEngine` (protocol) — `func loadReference(cgImage:refSize:rockQuadPercent:) -> Bool`; `func process(pixelBuffer:viewSize:) -> EngineAlignment?`; `func reset()`. `EngineAlignment { corners:[Double](8, TL,TR,BR,BL, view-space logical points), confidence:Double(0..1), tracking:Bool }`.
- `VisionRegistrationEngine` — wraps the dormant `ArVisionPipeline`. Registers reference→live, gets the reference→live pixel homography, **reprojects the reference's 4 corners** through it into live-pixel space, then maps live-pixel → view-space via aspect-fill letterbox transform (the AR preview fills the view). Confidence from the pipeline's degeneracy check, upgraded to a graded score from corner-quad sanity (convex, area ratio in bounds).
- `OpenCvRegistrationEngine` — Swift wrapper over an Obj-C++ bridge `RockMatcher`:
  - `RockMatcher.h/.mm` (Obj-C++): `-(BOOL)loadReferenceCGImage:(CGImageRef)img rockQuad:(NSArray<NSNumber*>*)quadPercent;` builds a grayscale reference Mat cropped to the rock bbox, detects ORB keypoints + descriptors once. `-(NSArray<NSNumber*>* _Nullable)matchPixelBuffer:(CVPixelBufferRef)buf;` converts the live frame to grayscale Mat, ORB-detects, BFMatcher (Hamming, crossCheck) + Lowe ratio, `cv::findHomography(..., RANSAC)`, reprojects the 4 rock-crop corners into live-pixel space, returns `[8 corners..., inlierRatio]` or nil.
  - The Swift wrapper maps live-pixel → view-space (same letterbox transform as Vision) and derives confidence from inlier ratio + count.
- `ArPlatformView` — gains `private var placementEngine: RockRegistrationEngine?` and an `engineKind` set from the `start` arg. `session(_:didUpdate:)`: if a placement engine is set, call `engine.process(capturedImage, viewSize)` and `sendAlignment` its result; else run the existing ARKit block. `startSession` loads the reference into the engine (using the already-decoded upright CGImage + `rockQuadPercent` from segmentation).

**Channel contract (minimal, backward-compatible additions):**

- `ArChannel.start(...)` gains `engine: String` (`'arkit'|'vision'|'opencv'`, default `'arkit'`) and optional `rockQuad: List<double>` (8 doubles, the rock quad percent from segmentation). Parsed in `ArChannelHandler` `"start"` case.
- `ArChannelHandler.sendAlignment(...)` gains `confidence: Double` → adds `"confidence"` to the payload. `ArAlignment.fromMap` already parses `confidence`; wire it into `derivedConfidence` (blend/min with the trackingState band) so a graded engine score actually drives the low-confidence fade + manual-fallback affordance.

**Dart (`lib/features/ar/`):**

- `ArPlacementEngine` enum `{ arkit, vision, opencv }`; `arEngineProvider = NotifierProvider<ArEngineController, ArPlacementEngine>` mirroring `arRockHighlightProvider` (in-memory Notifier — matches the codebase; no SharedPreferences exists). Default `arkit`.
- `_startSession` reads `arEngineProvider` + the rock quad and passes both to `channel.start`. A cycling FAB in `_ArControls` (`ar-engine-toggle`, MasiIcon) cycles arkit→vision→opencv and re-starts the session; a small label shows the active engine so the morning tester knows which is on.
- Confidence: `ArAlignment.derivedConfidence` blends the numeric `confidence` (when present, >0) with the trackingState band via `min`, so low OpenCV/Vision inlier ratios fade the overlay and surface the manual escape hatch exactly like limited ARKit tracking does today.

## Data flow

Session start → Dart picks engine + rock quad → `start` → native loads reference (upright CGImage + rock crop) into the chosen engine → ARFrame stream → per frame: engine matches reference→live → 4 corners in view space + confidence → `sendAlignment` → EventChannel → `CornerSmoother` (EMA, already central) → `Homography.fromQuad(fullPhotoCorners, engineCorners)` → painter warps routes (stored normalized). Loop.

## Error handling / degradation

- Engine returns nil / low confidence on a frame → send `corners:[]`, `tracking:false` (or hold last-good via the existing `_lastGoodHomography` cap at 0.2). Existing Dart logic already holds/fades.
- Sustained low confidence → overlay fades to "searching"; manual-align FAB (`ar-mode-toggle`) is the escape hatch (unchanged).
- Empty rock quad / reference load fail → engine disabled, fall back to ARKit for that session.
- OpenCV link/availability failure at runtime is impossible to hit silently: if the framework is absent the app won't build; there is no dynamic-load path.

## Testing (sim-first; camera is device-only)

- **Swift XCTest (sim, the core correctness proof):** synthetic warped-pair homography recovery. Build a textured reference image, warp it by a known homography `H`, feed both the reference and the warped image to `RockMatcher` (OpenCV) and to the Vision pipeline; assert the recovered 4 corners are within tolerance of `H`-projected corners. OpenCV's xcframework has sim slices, so this runs headless on the Simulator — it validates the *matching + homography + reprojection* math without a camera. Also unit-test the live-pixel→view-space letterbox transform.
- **Dart (`flutter test`):** `arEngineProvider` cycling; `channel.start` sends the `engine`/`rockQuad` args; `ArAlignment.derivedConfidence` blends numeric confidence correctly (0, mid, high cases); painter unaffected.
- **`flutter analyze` = 0**, `flutter test` green, `flutter build ios --simulator` (or device) compiles + links OpenCV.
- **Device (morning, human):** the real A/B — open a topo → AR → cycle engines → judge which holds routes on the wall at angle/lighting; confirm floating is gone; confirm graceful manual fallback.

## Honest bar

Vision registration is built for small motion, not wide baseline — expect it to hold moderate angle change and degrade past that. OpenCV feature-matching is the wide-baseline-robust one but costs binary size and per-frame CPU (throttle via frame stride). The `ArVisionPipeline` coordinate math (bottom-left origin, column-major transpose, determinant-only confidence) was never device-verified — routing it through **corner reprojection validated against synthetic pairs** (not trusting the raw matrix orientation) is how we de-risk it in the sim before the device sees it. Which engine to keep is the morning decision; this build makes both real, comparable, and safe to fall back from.
