# RockSeg Core ML model — provenance + regeneration

## What this is

`ios/Runner/Models/RockSeg.mlpackage` is a bundled, quantized Core ML semantic
segmentation model used by the on-device AR rock-crop feature (see
`docs/superpowers/plans/2026-07-27-ar-rock-crop.md`). It classifies every
pixel of a photo into one of the 150 ADE20K scene-parsing classes so the app
can auto-segment "the rock" in a stored topo photo (no manual author step)
and crop the AR overlay to the rock silhouette instead of draping it over
sky/forest/terrain.

## Model provenance

- **Base model:** [`openmmlab/upernet-convnext-tiny`](https://huggingface.co/openmmlab/upernet-convnext-tiny)
  — UPerNet (Unified Perceptual Parsing) segmentation head on a ConvNeXt-Tiny
  backbone, fine-tuned on **ADE20K** (150-class scene parsing).
- **License: MIT.** Confirmed on the model card. Safe to bundle and ship.
- Loaded via `transformers.AutoModelForSemanticSegmentation`; weights are
  cached locally under `~/.cache/huggingface/hub/models--openmmlab--upernet-convnext-tiny`
  after the first download (~230 MB, fp32 PyTorch weights — not the shipped
  artifact).
- The 150 ADE20K class names come from the model's own `config.id2label` —
  no hand-typed label list anywhere in this pipeline, so a re-export from a
  different checkpoint can't silently drift out of sync with its own labels.

## What the script does (`convert_rock_seg_coreml.py`)

1. Loads the HF model and wraps it in a one-line `nn.Module` (`LogitsOnly`)
   that returns `.logits` directly — `torch.jit.trace` / coremltools can't
   convert a `forward()` that returns a dict (coremltools issue #2380).
2. Traces the wrapped model on a `(1, 3, 512, 512)` example input.
3. Converts via `coremltools.convert(...)` to an **iOS16+ ML Program**
   (`.mlpackage`), `compute_precision=FLOAT16`, with:
   - Input `"image"`: `ct.ImageType`, `512x512`, with ImageNet
     normalization **folded into the Core ML graph** (`scale=1/(0.229*255)`,
     `bias=[-0.485/0.229, -0.456/0.224, -0.406/0.225]`) — so the Swift side
     hands it a raw `CGImage`/pixel buffer with no manual pixel math.
   - Output `"logits"`: `ct.TensorType`, raw per-class logits, no argmax
     baked in (argmax happens on-device in Swift so the class-id → name
     resolution can stay data-driven, see below).
4. Embeds the 150 ADE20K class names into
   `mlmodel.user_defined_metadata["ade20k_labels"]` as a single
   pipe-joined (`"|"`) string, **in `id2label` index order** — index `i` in
   the string corresponds to channel `i` of the `logits` output. This is how
   the Swift recipe (Task 2) resolves class names **by NAME**
   (`"rock"`, `"sky"`, `"mountain"`, ...) instead of hardcoded ADE20K
   indices, per the plan's mask-recipe constraint.
5. Quantizes the weights to fit the ~65 MB bundling budget (see below), and
   saves the result to `ios/Runner/Models/RockSeg.mlpackage`.

### Quantization — what actually ran

The plan's preferred method is **6-bit k-means palettization** via
`coremltools.optimize.coreml`, with int8 linear quantization documented as
an acceptable fallback if the installed API differs. In this environment:

- `coremltools.optimize.coreml.{OpPalettizerConfig, OptimizationConfig,
  palettize_weights}` **is** importable in the installed coremltools 9.0 —
  no API adaptation was needed there.
- The k-means palettizer additionally requires `scikit-learn` at runtime
  (not a hard pip dependency of coremltools) — it was missing from the
  conversion venv and had to be `pip install`ed in. (coremltools prints a
  "scikit-learn version ... not supported" warning at import because the
  installed sklearn 1.9.0 is newer than its pinned compatibility range, but
  the palettization pass completed successfully anyway using its internal
  k-means fallback path — not blocking.)
- The script tries **6-bit kmeans**, then **4-bit kmeans**, then falls back
  to **int8 linear (per-channel, symmetric)** if palettization is
  unavailable or still over budget after both bit depths.

**Actual result for the committed model: 6-bit k-means palettization
succeeded on the first try** — no fallback needed.

| Stage | Size |
|---|---|
| fp16 (pre-quantization, `compute_precision=FLOAT16`) | 118.8 MB |
| **6-bit k-means palettized (shipped)** | **44.8 MB (`du -sh` reports 43M)** |
| Budget | ≤ 65 MB |

## Regeneration

Reuses a scratch Python venv with `torch`, `transformers`, `coremltools`,
`scikit-learn` installed (the repo does not vendor this venv — recreate it
if it doesn't exist locally: `python3.12 -m venv <venv> && <venv>/bin/pip
install torch transformers coremltools scikit-learn pillow numpy`).

```bash
<venv>/bin/python tool/ml/convert_rock_seg_coreml.py
du -sh ios/Runner/Models/RockSeg.mlpackage   # expect <= 65 MB
```

The script is idempotent and deterministic modulo k-means initialization
(palettization LUT centroids can vary slightly run-to-run; this does not
materially change segmentation quality — re-run the sanity check below
after any regeneration).

## Sanity-checking a regenerated model

Quantization can silently degrade a segmentation model (e.g. collapse to
one class everywhere) — always re-verify after regenerating. One-off check
(not part of the repo; adapt paths as needed):

```python
import coremltools as ct, numpy as np
from PIL import Image, ImageOps

model = ct.models.MLModel("ios/Runner/Models/RockSeg.mlpackage")
labels = model.user_defined_metadata["ade20k_labels"].split("|")
im = ImageOps.exif_transpose(Image.open("<a clean rock-wall photo>")).convert("RGB")
im = im.resize((512, 512), Image.BILINEAR)
out = model.predict({"image": im})
class_map = np.argmax(np.asarray(out["logits"])[0], axis=0)  # (512, 512)
# top classes by coverage; expect a rock-family class (rock/mountain/hill/
# cliff/wall) dominant over the rock, "sky" dominant over the top region.
```

This was run against the shipped 44.8 MB model on
`~/Downloads/masi-spike/60ED33DC-EF08-4606-8D92-243128940307.JPG` (a clean
rock wall against open sky) with this result:

```
TOP (upper third) region dominant class: sky (100.0%)
BOTTOM (lower two-thirds) region dominant class: hill (73.4%)
  hill                  73.4%
  sky                   18.6%
  mountain               7.6%
  tree                   0.2%
  person                 0.2%
```

`sky` fully dominates the top region and `hill`/`mountain` (rock-family,
150 %-of-nonzero pixel classes, together ~81% of the bottom region) dominate
the wall — matching the fp16 spike's behavior. Quantization did not wreck
the model.

## Input / output tensor spec

| | Name | Type | Shape/format |
|---|---|---|---|
| Input | `image` | `ImageType` (RGB) | 512 × 512, ImageNet-normalized in-graph |
| Output | `logits` | `Float16` `MLMultiArray` | `(1, 150, 512, 512)` — per-class logits (fp16, from `compute_precision=FLOAT16`), channel `i` = ADE20K class `i` |
| Metadata | `user_defined_metadata["ade20k_labels"]` | `String` | 150 class names, `"|"`-joined, in channel-index order |
| Metadata | `user_defined_metadata["source_model"]` | `String` | `"openmmlab/upernet-convnext-tiny"` |
| Metadata | `user_defined_metadata["source_license"]` | `String` | `"MIT"` |

Consumers (Swift, Task 2) resolve class IDs to names via
`ade20k_labels.split("|")[classId]` — never a hardcoded index — so a future
re-export from a different fine-tune/checkpoint stays correct as long as the
label ordering is re-embedded from that checkpoint's own `config.id2label`.
