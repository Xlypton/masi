# AR Rock-Crop Implementation Plan

> **For agentic workers:** implement task-by-task. Each task is an independently
> testable deliverable with its own assertions and commit. The **implementer of a
> task never verifies it** — a separate clean-context agent re-runs the assertions
> and reviews the diff (CLAUDE.md). Steps use `- [ ]` for tracking.

**Goal:** Auto-segment the rock in a stored topo photo (no author step) and crop the AR overlay to the rock silhouette, so routes stop draping over forest/terrain.

**Architecture:** A bundled Core ML semantic-segmentation model (`upernet-convnext-tiny`, MIT) runs once on the stored photo inside the **already-registered, currently-dormant** `masi/arSegmentation` Swift channel; it returns a per-pixel rock alpha mask + quad over the existing wire contract. Dart caches the mask and renders the overlay *through* it (silhouette) placed by the rock quad. Tracking/anchoring is unchanged — this phase only changes *what* is drawn. Web (no Core ML) gets a cheap route-hull bbox crop.

**Tech Stack:** Swift Vision/Core ML (`VNCoreMLRequest`, `VNGeneratePersonSegmentationRequest`), coremltools (offline), Flutter/Dart, Riverpod v3, existing `rock_mask_codec` + `masi/arSegmentation` MethodChannel.

**Spec:** `docs/superpowers/specs/2026-07-27-ar-rock-crop-design.md`

## Global Constraints

- **iOS-native first.** Core ML target iOS 16+. Model **bundled** in the `Runner` target (decided). Web = route-hull crop; Android unchanged.
- **No new Flutter/pub dependency; no Podfile** (SPM-only). Core ML/Vision are OS frameworks.
- **Model:** `openmmlab/upernet-convnext-tiny` (MIT), quantized Core ML `.mlpackage`, target ~55–60 MB.
- **Output wire contract unchanged** (`rockMaskAlpha` + `rockQuadPercent`); the only wire change is a new **input** `routesNorm` on `segmentPreview`.
- **Tracking/anchoring UNCHANGED.** Do not touch the ARKit pin-once path, `Homography.fromQuad`, `CornerSmoother`, or the manual-align gesture math. Crop only.
- **Mask recipe (authoritative):** `ROCK+ ∪ INVERT` → **clip to padded route bbox** → `AND-NOT` person mask → largest connected component overlapping the route bbox. Class ids resolved by `id2label` **name** match, never hardcoded indices.
- **Toolchain:** prefix every flutter/dart/xcrun/pod command with `export PATH="/opt/homebrew/bin:$PATH" && `. Flutter 3.44 / Dart 3.12 / Xcode 26.
- **Keep `flutter analyze` = 0 and `flutter test` green on every task.**
- **Device verify in-place** via `xcrun devicectl device install app` (NEVER uninstall — wipes login). Live AR only verifiable on the physical iPhone (`PetiTeló`). Never `flutter clean`.
- **Commits:** one per verified task, conventional message, explicit pathspec only (leave the pre-existing staged `Runner.xcscheme` and untracked `.wrangler/`, `android/build/`, `masi_icons_v5_svg/**` alone). End every message with `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`.
- Never introduce `Icons.X`/`CupertinoIcons.X` (use `MasiIcon`) — unlikely needed here.

## File Structure

**Create:**
- `tool/ml/convert_rock_seg_coreml.py` — reproducible offline conversion + quantization (seed: scratchpad `convert_coreml.py`).
- `tool/ml/README.md` — how to regenerate the model, model provenance + MIT license note.
- `ios/Runner/Models/RockSeg.mlpackage` — the bundled quantized model (added to the Runner target).
- `assets/test/crag_sample.jpg` — a bundled test crag photo for the simulator seg test.
- `integration_test/ar_rock_crop_test.dart` — sim seg + cropped-overlay screenshot flow.

**Modify:**
- `ios/Runner/AR/ArRockSegmentation.swift` — replace the `VNGenerateForegroundInstanceMaskRequest` body with the Core ML recipe.
- `ios/Runner/AR/ArSegmentationChannelHandler.swift` — accept the `routesNorm` arg, pass it through.
- `ios/Runner.xcodeproj/project.pbxproj` — add `RockSeg.mlpackage` + `assets/test` as resources (via Xcode).
- `lib/features/ar/application/ar_segmentation_channel.dart` — send `routesNorm`; return decoded mask.
- `lib/features/ar/presentation/ar_screen.dart` — call `segmentPreview` with routes on entry, cache, feed the mask to the painter; web route-hull branch.
- `lib/features/ar/application/ar_controller.dart` — hold the decoded rock mask (not just the highlight box).
- `lib/features/ar/presentation/ar_overlay_painter.dart` — render the ghost/overlay through the mask silhouette, placed by the rock quad.
- `lib/features/topo/presentation/rock_mask_painter.dart` + `topo_canvas.dart` — use the real mask silhouette when available (Task 4, bonus).

---

### Task 1: Convert + quantize + bundle the Core ML model

**Files:**
- Create: `tool/ml/convert_rock_seg_coreml.py`, `tool/ml/README.md`, `ios/Runner/Models/RockSeg.mlpackage`
- Modify: `ios/Runner.xcodeproj/project.pbxproj` (add the model to the Runner target)

**Interfaces:**
- Produces: a bundled Core ML model named `RockSeg.mlmodelc` at runtime, input `image` 512×512 RGB, output `logits` MLMultiArray shape `(1,150,512,512)`, plus `classLabels` = ADE20K-150 `id2label` embedded as model metadata (so Swift resolves class names without a hardcoded list).

- [ ] **Step 1: Write the conversion+quantization script** (seed from scratchpad `convert_coreml.py`; add int8/palettization and embed the label list as metadata):

```python
# tool/ml/convert_rock_seg_coreml.py
import torch, coremltools as ct
from coremltools.optimize.coreml import (OpPalettizerConfig, OptimizationConfig, palettize_weights)
from transformers import AutoModelForSemanticSegmentation

NAME = "openmmlab/upernet-convnext-tiny"   # MIT
m = AutoModelForSemanticSegmentation.from_pretrained(NAME).eval()
id2label = m.config.id2label  # 150 ADE20K classes

class Wrap(torch.nn.Module):            # dict output -> plain logits tensor (coremltools#2380)
    def __init__(self, mm): super().__init__(); self.m = mm
    def forward(self, x): return self.m(pixel_values=x).logits

ex = torch.rand(1, 3, 512, 512)
ts = torch.jit.trace(Wrap(m), ex)
mlmodel = ct.convert(
    ts, inputs=[ct.ImageType(name="image", shape=(1,3,512,512),
        scale=1/(0.229*255), bias=[-0.485/0.229,-0.456/0.224,-0.406/0.225])],  # ImageNet norm
    outputs=[ct.TensorType(name="logits")],
    minimum_deployment_target=ct.target.iOS16, compute_precision=ct.precision.FLOAT16)
# embed labels so Swift can name classes:
mlmodel.user_defined_metadata["ade20k_labels"] = "|".join(id2label[i] for i in range(len(id2label)))
# quantize weights (6-bit palettization -> ~55-60MB):
cfg = OptimizationConfig(global_config=OpPalettizerConfig(mode="kmeans", nbits=6))
mlmodel = palettize_weights(mlmodel, cfg)
mlmodel.save("ios/Runner/Models/RockSeg.mlpackage")
print("saved RockSeg.mlpackage")
```

- [ ] **Step 2: Run it and check the output size** (reuse the scratchpad venv):

Run: `/private/tmp/claude-502/-Users-kerip-Projects-masi/060d264f-be8f-4537-b0d9-3cae99e83a8b/scratchpad/seg-venv/bin/python tool/ml/convert_rock_seg_coreml.py && du -sh ios/Runner/Models/RockSeg.mlpackage`
Expected: prints `saved RockSeg.mlpackage`; size **≤ 65 MB**. If int8 needed instead of 6-bit to hit size, adjust `nbits`.

- [ ] **Step 3: Sanity-check the model loads + predicts** on the sample crag photo via coremltools on macOS:

Run a one-off: load `RockSeg.mlpackage`, predict on `~/Downloads/masi-spike/60ED33DC-*.JPG` resized 512², argmax the logits, assert the top classes include a rock-family label (`rock`/`mountain`/`wall`) over the wall region. (This reproduces the spike result from the *quantized* model — confirming quantization didn't wreck it.)
Expected: rock-family class dominant on the wall; `sky` on top region.

- [ ] **Step 4: Add the model to the Runner target** (Xcode: drag `ios/Runner/Models/RockSeg.mlpackage` into Runner, "Copy if needed", target = Runner) so it compiles to `RockSeg.mlmodelc` in the app bundle. Write `tool/ml/README.md` documenting provenance (upernet-convnext-tiny, MIT) + regen command.

- [ ] **Step 5: Verify it builds into the app:**

Run: `export PATH="/opt/homebrew/bin:$PATH" && cd /Users/kerip/Projects/masi && flutter build ios --debug --no-codesign 2>&1 | tail -5`
Expected: build succeeds; `find build/ios -name "RockSeg.mlmodelc" | head` is non-empty.

- [ ] **Step 6: Commit** (explicit pathspec; the `.mlpackage` is a binary — confirm it's not gitignored and is a reasonable size to commit, else document Git-LFS/first-run-fetch — but decision is bundle):

```bash
git add tool/ml/ ios/Runner/Models/RockSeg.mlpackage ios/Runner.xcodeproj/project.pbxproj
git commit -m "feat(ar): bundle upernet-convnext-tiny rock-seg Core ML model (#68)" # + trailer
```

**Assertions (independent verify):**
- A1. `RockSeg.mlpackage` exists, ≤ 65 MB, MIT-provenance documented in `tool/ml/README.md`.
- A2. Model loads and predicts; on the sample wall photo a rock-family class is dominant over the wall and `sky` over the top — quantization preserved the spike behavior.
- A3. `flutter build ios --debug --no-codesign` succeeds and `RockSeg.mlmodelc` is in the built bundle.
- A4. Scope: only the files above changed; no Dart/AR-runtime files touched.

---

### Task 2: Core ML rock-mask recipe in the Swift channel

**Files:**
- Modify: `ios/Runner/AR/ArRockSegmentation.swift`, `ios/Runner/AR/ArSegmentationChannelHandler.swift`
- Test: `ios/RunnerTests/` XCTest OR the Dart sim integration test in Task 3 (see note).

**Interfaces:**
- Consumes: `RockSeg.mlmodelc` (Task 1); the upright `CGImage` (existing `uprightCGImage`).
- Produces: `segmentPreview(imagePath: String, routesNorm: [[Double]]?)` over `masi/arSegmentation`, returning the **unchanged** map `{rockQuadPercent:[8], rockMaskAlpha:FlutterStandardTypedData, rockMaskWidth:Int, rockMaskHeight:Int}`. `routesNorm` = flat list of normalized route points `[x0,y0,x1,y1,...]` in 0..1 (nil/empty ⇒ skip the route clip).

- [ ] **Step 1: Add the `routesNorm` arg** to `ArSegmentationChannelHandler`'s `segmentPreview` decode (read `args["routesNorm"] as? [Double]`), pass to `segmentAndCrop`.

- [ ] **Step 2: Replace the segmentation core** in `ArRockSegmentation.segmentAndCrop`. Read the current file first; replace the `VNGenerateForegroundInstanceMaskRequest` block with this recipe (keep the existing upright-fix, the Pass-2 max-pool downsample-to-≤256, and the `RockMask`/`quadPercent` return **verbatim** — only the *mask-building* changes):

```swift
// 1. semantic seg
let model = try VNCoreMLModel(for: RockSeg(configuration: MLModelConfiguration()).model)
let req = VNCoreMLRequest(model: model)
req.imageCropAndScaleOption = .scaleFill   // model expects 512x512
try VNImageRequestHandler(cgImage: upright).perform([req])
guard let logits = (req.results?.first as? VNCoreMLFeatureValueObservation)?
        .featureValue.multiArrayValue else { return nil }  // (1,150,H,W)
// 2. argmax -> classId per pixel (H x W), then upscale to image size
// 3. class sets by NAME from model metadata "ade20k_labels":
let labels = /* split user_defined_metadata */
let ROCKPOS: Set = ids(matching:["rock","stone","mountain","cliff","hill","wall","building","house"])
let NONROCK: Set = ids(matching:["sky","tree","grass","plant","person","water","sea","river","earth","ground","sand","field","road","sidewalk","path","floor","runway","dirt"])
// candidate = classId ∈ ROCKPOS  OR  classId ∉ NONROCK
var mask = perPixel { cid in ROCKPOS.contains(cid) || !NONROCK.contains(cid) }
// 4. clip to padded route bbox (routesNorm) if present
if let box = paddedRouteBBox(routesNorm, pad: 0.06) { mask = mask.intersect(box) }
// 5. subtract people (Apple, free)
if let people = try? personMask(upright) { mask = mask.subtract(people) }   // VNGeneratePersonSegmentationRequest
// 6. largest connected component overlapping the route bbox (or image center)
mask = largestComponent(mask, seedBox: box ?? centerBox)
// -> existing Pass-2 downsample + quadPercent(from mask bbox) + RockMask return
```

Implement `ids(matching:)`, `paddedRouteBBox`, `personMask`, `largestComponent`, and the argmax/upscale as private helpers in the same file. Add `#available(iOS 16, *)` guards; on unavailable/failed model, return `nil` (caller already falls back to the full photo — unchanged behavior).

- [ ] **Step 3: Sim/unit check.** Core ML runs in the Simulator (CPU) and needs **no camera**, so this is Simulator-testable. Add an XCTest (or drive via Task 3's Dart integration test) that calls `segmentAndCrop` on the bundled `assets/test/crag_sample.jpg` with a `routesNorm` over the rock, and asserts: returned `rockMaskAlpha` non-nil; foreground coverage within `[0.15, 0.85]`; `rockQuadPercent` inside `[0,1]` and its area < full frame (proves it cropped).

- [ ] **Step 4: Run it.**
Run (XCTest): `export PATH="/opt/homebrew/bin:$PATH" && xcodebuild test -scheme Runner -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:RunnerTests/RockSegTests 2>&1 | tail -20`
Expected: PASS. (If XCTest harness is absent, defer this assertion to Task 3's Dart sim test and note it.)

- [ ] **Step 5: Commit:**
```bash
git add ios/Runner/AR/ArRockSegmentation.swift ios/Runner/AR/ArSegmentationChannelHandler.swift ios/RunnerTests/
git commit -m "feat(ar): rock-mask recipe (semantic-seg + route-clip + person-subtract) in seg channel (#68)" # + trailer
```

**Assertions (independent verify):**
- A1. `segmentPreview` accepts `routesNorm` and passes it through; output map keys unchanged.
- A2. Recipe matches the spec exactly: `ROCK+ ∪ INVERT` → route-clip → person-subtract → largest-CC; class ids resolved by **name** from model metadata (grep: no hardcoded `34`/`16` class-index literals).
- A3. On `crag_sample.jpg` the returned mask covers the rock (coverage in range) and the quad is a **strict sub-rect** of the frame (cropped, not full-photo). Person pixels excluded.
- A4. iOS-availability guarded; failure path returns `nil` (unchanged full-photo fallback). `flutter analyze` 0.
- A5. Scope: only the two Swift files + tests; ARKit pin-once path, homography, smoother untouched (grep the diff).

---

### Task 3: Dart wiring — call, cache, and crop the overlay to the mask

**Files:**
- Modify: `lib/features/ar/application/ar_segmentation_channel.dart`, `lib/features/ar/presentation/ar_screen.dart`, `lib/features/ar/application/ar_controller.dart`, `lib/features/ar/presentation/ar_overlay_painter.dart`
- Create: `integration_test/ar_rock_crop_test.dart`, `assets/test/crag_sample.jpg` (+ pubspec asset entry)

**Interfaces:**
- Consumes: `segmentPreview(imagePath, routesNorm)` (Task 2); `rock_mask_codec.decodeRockMaskAlpha` (existing) → a `ui.Image` silhouette + the quad.
- Produces: `arRockMaskProvider` (family by photoId) yielding `RockMask? {image: ui.Image, quadPercent: List<Offset>}`; `ArOverlayPainter` gains `rockMask` and, when non-null, clips/places the overlay by it.

- [ ] **Step 1:** In `ar_segmentation_channel.dart`, add `routesNorm` to the `segmentPreview` invocation (flatten the wall's route points to `[x0,y0,...]`). On web the channel is `.noop()` — keep returning null (web handled in Step 4).
- [ ] **Step 2:** Add `arRockMaskProvider` (autoDispose family by `photoId`) that calls `segmentPreview` once, decodes via `rock_mask_codec`, caches the `ui.Image`. In `ar_screen._load`, resolve it (with the wall's routes) and store on `ArController`.
- [ ] **Step 3:** In `ar_overlay_painter.dart`, when `rockMask != null`: instead of drawing the ghost over the **full** photo rect, draw it clipped to the mask silhouette (use the decoded alpha as a clip/`BlendMode.dstIn`), and drive placement from the **rock quad** (warp the quad corners through the same homography). Route polylines unchanged. When `rockMask == null`, behavior is exactly as today (fallback).
- [ ] **Step 4 (web):** In the web/manual placement branch of `ar_screen`, when `arSupportsAutoTracking()==false` and no mask, compute a **route-hull padded bbox** (pure Dart, reuse `rockBoxFromRoutes`) and use it as the overlay source rect instead of the full `refSize`. This is the web crop.
- [ ] **Step 5: Write the sim integration test** `ar_rock_crop_test.dart`: seed a wall+photo pointing at `assets/test/crag_sample.jpg` + a few routes, open the AR screen (manual/sim path), take `binding.takeScreenshot('ar-rock-crop')`. (Camera can't run in sim, but the overlay/crop renders over a neutral background — enough to verify the overlay is the rock quad, not the full rect.)
- [ ] **Step 6: Run** the web-driver + sim flows:
Run: `export PATH="/opt/homebrew/bin:$PATH" && cd /Users/kerip/Projects/masi && flutter analyze && flutter test`
Expected: analyze 0, tests green. Then the sim integration screenshot flow (per CLAUDE.md loop) → read the PNG: overlay confined to the rock region, not the full photo rectangle.
- [ ] **Step 7: Commit:**
```bash
git add lib/features/ar/ integration_test/ar_rock_crop_test.dart assets/test/ pubspec.yaml
git commit -m "feat(ar): crop AR overlay to the rock mask (silhouette + quad); web route-hull crop (#68)" # + trailer
```

**Assertions (independent verify):**
- A1. On iOS the overlay is drawn through the mask silhouette and placed by the rock quad; on `rockMask==null` the render is byte-identical to today (fallback intact).
- A2. Web (`autoTracking==false`) crops to the route-hull bbox, not the full `refSize`.
- A3. `arRockMaskProvider` calls `segmentPreview` **once** per photo (cached), passing the wall's routes as `routesNorm`.
- A4. `flutter analyze` 0; `flutter test` green (was ~1564; new tests add, 0 failures). Sim screenshot shows the overlay confined to the rock, not the full rectangle.
- A5. Scope: only `lib/features/ar/**` + the test/asset/pubspec; tracking/homography/smoother untouched.

---

### Task 4 (bonus): canvas "highlight rock" uses the real mask

**Files:** Modify `lib/features/topo/presentation/rock_mask_painter.dart`, `topo_canvas.dart`.

- [ ] **Step 1:** When `arRockMaskProvider` has a mask for the photo, `RockBoxPainter` draws the real silhouette (translucent) instead of the coarse route-bbox rectangle; fall back to the box when no mask.
- [ ] **Step 2: Run** `flutter analyze && flutter test`; sim screenshot of the canvas highlight → read PNG (silhouette hugs the rock, not a loose box).
- [ ] **Step 3: Commit:** `feat(topo): rock-highlight uses the real segmentation mask (#68)` (+ trailer).

**Assertions:** analyze 0, tests green; highlight is the silhouette when a mask exists, box otherwise; scope = the two files.

---

### Final: independent verify + device

- **Independent clean-context verify** (separate agent, per CLAUDE.md): given only this plan's assertions + the full diff, re-run analyze/tests/sim-screenshots and adversarially review. Must pass before "done."
- **Device verify (PetiTeló):** `flutter build ios --release -t lib/main.dart && xcrun devicectl device install app --device <id> build/ios/iphoneos/Runner.app` (in place, no uninstall). Open a topo → AR → confirm routes sit on the **rock silhouette**, overlay no longer covers forest/terrain. Capture via `devicectl ... process launch --console` if diagnostics needed (native NSLog only).

## Self-Review

- **Spec coverage:** model/bundle → T1; recipe (ROCK+∪INVERT, route-clip, person-subtract, largest-CC) → T2; overlay crop + web route-hull → T3; canvas highlight (bonus) → T4; sim+device verify → each task + Final. Persistence/sync intentionally deferred (spec §5) — no task, correct. Matching engine out of scope — no task, correct.
- **Placeholder scan:** recipe helpers named + specified; conversion script is real; no "TBD". The one soft spot: exact current line contents of the Swift/Dart files are read by the implementer (orchestration model) — targets + transformations are precise.
- **Type consistency:** `segmentPreview(imagePath, routesNorm)`, `rockMaskAlpha/rockQuadPercent` (unchanged), `arRockMaskProvider → RockMask{image, quadPercent}`, `RockSeg` model class — consistent across T1–T4.

## Execution
Subagent-driven: one fresh implementer per task, then an independent clean-context verify before the next task; parallel only if file-disjoint (T1 and the T3 test asset are disjoint; T2→T3→T4 are sequential on shared AR files).
