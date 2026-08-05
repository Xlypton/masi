# AR Phase 2 — Continuous Placement Registration Design
**Date:** 2026-07-27  
**Status:** Approved → implementing

## Problem
ARKit pin-once image-anchor tracking is unstable: routes float mid-air, drift at oblique angles, and break between sessions ("a year later"). Phase 1 (rock mask/crop, committed) is done. Phase 2 fixes *placement*.

## Decision: Continuous 2D Image Registration
**No ARKit world-anchor dependence.** Instead, every live camera frame is registered against the stored topo photo via 2D image matching → homography → project 4 reference corners → existing painter seam. Handles moderate viewpoint/lighting changes. Manual-align fallback retained for large-baseline failures.

## Two Parallel Engines (both built, user picks in morning)

### Phase 2A — Vision Registration (`ArVisionPipeline`, already written, just wiring)
- `VNHomographicImageRegistrationRequest`: reference CGImage → live CVPixelBuffer → `warpTransform` (3×3)
- `normalizationCorrection` (already in file): converts Vision's normalized/bottom-left to pixel-space/top-left
- **Output:** row-major `[Double]×9` homography, reference-pixel → live-frame-pixel
- **Confidence:** determinant-based binary (0 or 0.8) — already in `heuristicConfidence`
- **Best for:** small-to-moderate motion within a session; fast (Apple hardware)
- **Risk:** designed for small motion; may fail for wide-baseline return visits

### Phase 2B — ORB Feature Matching (`RockFeatureMatcher`, new file)
- FAST-9 corners (3-scale pyramid) + simplified BRIEF descriptors (256 bits, no rotation needed for ±30° tolerance)
- Hamming BFMatcher + Lowe's ratio test (0.8) + RANSAC 4-point DLT
- **Output:** same `[Double]×9` format, same screen-corner projection path
- **Confidence:** `inlierCount / totalMatches` (graded, not binary)
- **Best for:** wide-baseline (different sessions, angle, lighting); no external deps
- **Risk:** new, untuned — may have false matches on texture-poor rock

## Shared Output Contract (no Dart changes needed)
Both engines output a homography. `ArPlatformView` converts it to 4 screen corners via:
1. Project reference TL/TR/BR/BL (in reference-pixel space) through homography H
2. Normalize by live-frame dimensions → `[0,1]²` camera coords
3. Apply `ARFrame.displayTransform(for: .portrait, viewportSize:)` → screen points
4. Send via existing `sendAlignment(corners:tracking:frameWidth:frameHeight:trackingState:)`

Confidence → `trackingState` mapping (so Dart's `derivedConfidence` and coaching overlay work unchanged):
- ≥ 0.5 → `"normal"` (confidence = 1.0 in Dart)
- 0.2–0.5 → `"limited"` reason `"insufficientFeatures"` (confidence = 0.35)
- < 0.2 / no match → `tracking: false` (after 90 consecutive weak frames ≈ 3s)

Hold-last-good: maintain `_lastGoodCorners`, publish until weak-frame count hits 90, then send `tracking: false`.

## Mode Switch
```swift
// ArPlatformView.swift — change this 1 line to switch engines
static let registrationMode: RegistrationMode = .vision  // .vision or .orb
```
Both compiled into the app simultaneously; no rebuild for mode switch beyond this 1 line.

## Files Changed
| File | Change |
|------|--------|
| `ios/Runner/AR/ArPlatformView.swift` | Add `RegistrationMode` enum, instantiate both engines in `startSession`, replace pin-once with continuous registration loop in `session(_:didUpdate:frame:)` |
| `ios/Runner/AR/ArVisionPipeline.swift` | No changes (complete) |
| `ios/Runner/AR/RockFeatureMatcher.swift` | NEW — pure Swift ORB-style implementation |
| `ios/RunnerTests/ArVisionPipelineTests.swift` | NEW — unit tests for matrix math |
| `ios/RunnerTests/RockFeatureMatcherTests.swift` | NEW — unit tests for FAST detection, descriptor, RANSAC |

**No Dart changes.** Existing `ar_channel.dart`, `ar_controller.dart`, `ar_screen.dart`, `ar_overlay_painter.dart` untouched.

## Testing (simulator)
- Swift XCTest unit tests for pure math (FAST detection with synthetic image, Hamming distance, RANSAC homography recovery from known correspondences, Vision normalizationCorrection)
- `flutter analyze` + `flutter test` for Dart side (no changes expected)
- `flutter build ios --simulator` to confirm Swift compiles
- Device visual verification (human, morning): routes should lock to the wall instead of floating

## Explicitly Out of Scope
- Mask-guided feature matching (feed rock mask into ORB to skip sky/foliage) — deferred
- Mask persistence/sync to web/friends — deferred
- ARKit plane detection — rejected (2D registration covers the use case)
- External dependencies (OpenCV, ML model for features) — rejected (zero-dep target)
