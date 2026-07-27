# AR Rock-Crop — auto-segment the rock & crop the overlay to it

**Tasks:** #66 / #68 (Phase 1 of the AR overhaul)
**Date:** 2026-07-27
**Status:** design — awaiting approval

## Goal

The AR overlay currently draws the **whole stored photo** — forest, sky, terrain, crash pads
— so it reads as a big rectangle "too big, including forest and terrain" (the reported bug).
This phase automatically segments the **rock** in the stored topo photo (a per-pixel mask, with
**no author step**) and **crops the drawn overlay to that rock silhouette**, so the routes are shown
on the rock instead of draped over the surroundings.

## Scope

**In:**
- On-device iOS auto rock-mask (Core ML semantic segmentation, no user interaction).
- Crop the AR overlay (and the ghost/photo layer) to the rock silhouette.
- Bonus: replace the coarse route-bbox "highlight rock" on the topo canvas with the real mask.

**Explicitly OUT (later phases, separate specs):**
- "Routes float in the air, not on the wall" and "different angle a year later." Those require the
  **masked feature-matching → homography** engine. **Tracking/anchoring is unchanged here** (native
  pin-once ARKit; web manual-align). This phase changes only **what** is drawn, not **how it is
  anchored**. It fixes the "too big / covers forest" complaint and lays the mask groundwork the
  matching engine will reuse.

## Validated basis (spike, 2026-07-27, 8 real photos)

- **Semantic segmentation (ADE20K) + class-selection** isolated the climbing surface in **7 of 8**
  real photos (forest boulders, clean walls, pillar, dusk light, and the "rock=0%" limestone cave).
  **SAM was rejected** — it fragments on large/textured walls.
- **Ship model confirmed:** `openmmlab/upernet-convnext-tiny` — **MIT license**, ADE20K-150,
  converts to a **118.8 MB fp16 Core ML .mlpackage** today with zero friction (pure CNN → clean
  conversion), **~55–60 MB quantized** (int8/palettize). Matched the (non-free) SegFormer-b4 result
  on 7/8; the one regression (dry-grass foreground bleed) is mitigated by the route-region clip below.

## Design

### 1. Model & runtime
- Convert `upernet-convnext-tiny` offline with `coremltools` → fp16 `.mlpackage`, then quantize
  (int8 / palettization) to ~55–60 MB. Bundle in the `Runner` target (Xcode auto-compiles to
  `.mlmodelc`; no pubspec asset, no Dart change).
- Run via `VNCoreMLRequest` / `MLModel` inside `ios/Runner/AR/ArRockSegmentation.swift`, **replacing**
  the `VNGenerateForegroundInstanceMaskRequest` block (which is the failed saliency approach).
  Core ML target iOS 16+. Runs on the **stored photo, not the live camera** → simulator-runnable.

### 2. Mask recipe (Swift, `ArRockSegmentation`)
1. Argmax the 150-class map. Resolve class ids by **`id2label` name match** (substring), never
   hardcoded indices.
2. **Rock candidate** = `ROCK+` union `{rock, stone, mountain, cliff, hill, wall, building, house}`
   ∪ `INVERT` (everything **not** in `{sky, tree, grass, plant, person, water, sea, river, earth,
   ground, sand, field, road, sidewalk, path, floor, runway, dirt}`). Union captures the rock even
   when it's mislabeled wall/mountain/earth; both agreed in practice.
3. **Clip to the route region (load-bearing).** Intersect the candidate with the **padded bounding
   box of the drawn routes** (passed in as 0..1 normalized points). Confirmed by the spike: this
   removes the dry-grass foreground bleed (photo 388B) and crash-pad/ground leaks, because the routes
   are always on the rock. If a topo has **no routes yet**, skip the clip and fall back to a
   center-region prior.
4. **Subtract people.** `AND-NOT` Apple's free native `VNGeneratePersonSegmentationRequest` — hard-
   excludes climbers/spotters (directly attacks the old people-grab failure).
5. **Largest connected component** overlapping the route region (drops stray blobs).
6. Downsample to ≤256 long-edge alpha (existing Pass-2) → return `rockMaskAlpha` + `rockQuadPercent`.
   The **output** contract is unchanged (Dart decoder `rock_mask_codec` untouched); the only wire change
   is a new **input** arg `routesNorm` on `segmentPreview` (the padded route bbox for the clip in step 3).

### 3. Wiring (Dart)
- Call `segmentPreview(photoPath, routesNorm)` **lazily** on AR entry and on the topo-canvas
  rock-highlight. Decode via the existing `rock_mask_codec`. **Cache** the result keyed by `photoId`
  — in-memory + an optional sidecar file `photos/<id>.rockmask.png`. **No DB migration in v1.**
- `ArOverlayPainter`: render the ghost/photo overlay **through the per-pixel alpha mask** (silhouette),
  and use the **rock quad** as the placement frame instead of the full-photo rect. Route polylines are
  unchanged (already warped through the homography). Net effect: the overlay is the rock shape, not the
  full-photo rectangle → **fixes "too big."**
- Replace the canvas `RockBoxPainter` (route-bbox cyan box) with the real mask silhouette when
  available; fall back to the box.

### 4. Platform behavior
- **iOS:** computes the mask (Core ML). Primary target.
- **Web:** no Core ML — cannot compute on-device. v1 web applies a cheap **route-hull bbox** crop
  (padded bounding box of the drawn routes; no ML) so the PWA overlay also stops covering
  forest/terrain. Syncing the real iOS-computed mask to web viewers is **deferred** (needs persistence
  + sync).
- **Android:** no segmentation handler — unchanged.

### 5. Persistence / sync
- **v1:** local sidecar cache only, iOS. No DB migration, no sync.
- **Later:** persist `rockMaskAlpha` + `rockQuadPercent` on the `Photos` row and sync, so friends and
  web viewers of a published topo inherit the author's mask. Deferred to a follow-up.

### 6. Verification
- **Simulator:** an `integration_test` runs `segmentPreview` on a **bundled test crag asset** →
  asserts a plausible mask (coverage within a sane range, quad within bounds); screenshots the
  **cropped overlay on the topo canvas** (non-AR) → read the PNG.
- **Device (PetiTeló):** live AR view shows routes on the **rock silhouette**, not the full rectangle.
  In-place `devicectl` install (never uninstall).
- **Unit:** class-selection + route-clip + largest-CC helpers (where testable); `rock_mask_codec`
  decode. `flutter analyze` = 0, `flutter test` green.
- **Independent clean-context verify gate** (per CLAUDE.md): a separate agent re-runs the assertions
  and reviews the diff; the implementer never signs off its own work.

### 7. Risks
- **Dry-grass foreground bleed** (388B) — mitigated by the route-region clip (confirmed). Residual on
  route-less topos → center-region prior + person-subtract soften it.
- **Overhang mislabeled "ceiling"** (6A3A) — rely on `INVERT` (which keeps it) over `ROCK+` (which
  drops "ceiling"). Some overhangs stay imperfect; acceptable for a coarse crop mask.
- **Bundle size +~55–60 MB** (iOS-only asset) — significant. Mitigations: quantize hard; or fetch the
  model on first run instead of bundling. **Decision needed (see Open Questions).**
- **Coarse 256-px mask edge** — feather for a clean silhouette; fine as a matching mask later.

## Decisions (resolved 2026-07-27)
1. **Model delivery: BUNDLE** the ~55 MB quantized Core ML model in the iOS app — works offline at the
   crag with no signal; one-time app-size cost accepted.
2. **Web v1: apply the cheap route-hull bbox crop** on web now (no ML) so the PWA overlay also stops
   covering forest/terrain; real mask-sync to web deferred.

## Out of scope / next phase
Masked feature-matching → homography registration engine (fixes floating routes + different-angle
viewing). Separate spike + spec; it reuses the mask this phase produces.
