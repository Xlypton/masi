#!/usr/bin/env python3
"""Convert + quantize `openmmlab/upernet-convnext-tiny` (ADE20K-150, MIT) to a
bundled iOS Core ML model for on-device rock segmentation.

Produces: ios/Runner/Models/RockSeg.mlpackage
  - input  "image": ImageType, 512x512 RGB, ImageNet-normalized in-graph
             (scale=1/(0.229*255), bias=[-0.485/0.229, -0.456/0.224, -0.406/0.225])
  - output "logits": Float32 MLMultiArray, shape (1, 150, 512, 512)
  - metadata user_defined_metadata["ade20k_labels"]: the 150 ADE20K class
    names, in id2label index order, joined with "|" (so Swift can resolve
    class names by NAME, never by hardcoded index).

Quantization: weights are palettized (LUT compression) via
`coremltools.optimize.coreml` to bring the fp16 model (~119 MB) under the
~65 MB bundling budget. Tries 6-bit kmeans palettization first; if the
result is still over budget, retries at progressively fewer bits, then
falls back to int8 linear quantization if the palettizer API is
unavailable in the installed coremltools.

Regenerate with (see tool/ml/README.md for full context):
  <venv>/bin/python tool/ml/convert_rock_seg_coreml.py

Requires: torch, transformers, coremltools >= 8 (tested against 9.0). The
HF model is pulled from the local `~/.cache/huggingface` cache if present,
else downloaded (~230 MB, MIT license).
"""
import os
import sys

import coremltools as ct
import torch
from transformers import AutoModelForSemanticSegmentation

REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
OUT_PATH = os.path.join(REPO_ROOT, "ios", "Runner", "Models", "RockSeg.mlpackage")
SIZE_BUDGET_MB = 65.0

MODEL_NAME = "openmmlab/upernet-convnext-tiny"  # ADE20K-150 semantic seg, MIT license
INPUT_SIZE = 512


class LogitsOnly(torch.nn.Module):
    """Unwrap the HF dict-output model to a plain tensor (coremltools#2380
    can't trace/convert a model whose forward() returns a dict)."""

    def __init__(self, hf_model):
        super().__init__()
        self.m = hf_model

    def forward(self, pixel_values):
        return self.m(pixel_values=pixel_values).logits


def _tmp_path(suffix: str) -> str:
    return os.path.join(os.path.dirname(OUT_PATH), f"RockSeg.tmp_{suffix}.mlpackage")


def dir_size_mb(path: str) -> float:
    total = 0
    for root, _dirs, files in os.walk(path):
        for f in files:
            total += os.path.getsize(os.path.join(root, f))
    return total / 1e6


def build_fp16_mlmodel() -> tuple[ct.models.MLModel, dict]:
    print(f"loading {MODEL_NAME} ...", flush=True)
    hf_model = AutoModelForSemanticSegmentation.from_pretrained(MODEL_NAME).eval()
    id2label = hf_model.config.id2label  # {int: str}, 150 ADE20K classes
    num_labels = len(id2label)
    print(f"loaded, num_labels={num_labels}", flush=True)

    wrapped = LogitsOnly(hf_model).eval()
    example = torch.rand(1, 3, INPUT_SIZE, INPUT_SIZE)
    with torch.no_grad():
        out = wrapped(example)
    print(f"eager logits shape: {tuple(out.shape)}", flush=True)

    traced = torch.jit.trace(wrapped, example)
    print("traced OK", flush=True)

    # ImageNet normalization folded into the Core ML input layer so Swift
    # can hand it a raw CVPixelBuffer/CGImage with no manual pixel math.
    mean = [0.485, 0.456, 0.406]
    std = [0.229, 0.224, 0.225]
    scale = 1.0 / (std[0] * 255.0)
    bias = [-(mean[i] / std[i]) for i in range(3)]

    mlmodel = ct.convert(
        traced,
        inputs=[
            ct.ImageType(
                name="image",
                shape=(1, 3, INPUT_SIZE, INPUT_SIZE),
                scale=scale,
                bias=bias,
            )
        ],
        outputs=[ct.TensorType(name="logits")],
        minimum_deployment_target=ct.target.iOS16,
        compute_precision=ct.precision.FLOAT16,
    )

    labels_joined = "|".join(id2label[i] for i in range(num_labels))
    mlmodel.user_defined_metadata["ade20k_labels"] = labels_joined
    mlmodel.user_defined_metadata["source_model"] = MODEL_NAME
    mlmodel.user_defined_metadata["source_license"] = "MIT"
    mlmodel.short_description = (
        "ADE20K-150 semantic segmentation (upernet-convnext-tiny, MIT) for "
        "Masi rock-crop AR overlay. Input 512x512 RGB image; output logits "
        "(1,150,512,512); class names in user_defined_metadata['ade20k_labels']."
    )

    return mlmodel, id2label


def quantize_to_budget(mlmodel: ct.models.MLModel) -> tuple[ct.models.MLModel, str]:
    """Palettize weights, trying fewer bits until under SIZE_BUDGET_MB.
    Falls back to int8 linear quantization if palettization is unavailable
    or still doesn't fit. Returns (model, method-description)."""
    try:
        from coremltools.optimize.coreml import (
            OpPalettizerConfig,
            OptimizationConfig,
            palettize_weights,
        )

        for nbits in (6, 4):
            cfg = OptimizationConfig(
                global_config=OpPalettizerConfig(mode="kmeans", nbits=nbits)
            )
            print(f"palettizing weights: mode=kmeans nbits={nbits} ...", flush=True)
            candidate = palettize_weights(mlmodel, cfg)
            tmp_path = _tmp_path(f"{nbits}bit")
            candidate.save(tmp_path)
            size_mb = dir_size_mb(tmp_path)
            print(f"  -> {size_mb:.1f} MB", flush=True)
            if size_mb <= SIZE_BUDGET_MB:
                return candidate, f"{nbits}-bit kmeans palettization ({size_mb:.1f} MB)", tmp_path
            _cleanup(tmp_path)
    except ImportError as exc:
        print(f"palettization API unavailable ({exc}); falling back to int8 linear quantization", flush=True)

    # Fallback: int8 linear per-channel quantization.
    from coremltools.optimize.coreml import (
        OpLinearQuantizerConfig,
        OptimizationConfig,
        linear_quantize_weights,
    )

    print("linear-quantizing weights: int8 per-channel ...", flush=True)
    cfg = OptimizationConfig(global_config=OpLinearQuantizerConfig(mode="linear_symmetric", dtype="int8"))
    candidate = linear_quantize_weights(mlmodel, cfg)
    tmp_path = _tmp_path("int8")
    candidate.save(tmp_path)
    size_mb = dir_size_mb(tmp_path)
    print(f"  -> {size_mb:.1f} MB", flush=True)
    return candidate, f"int8 linear quantization ({size_mb:.1f} MB)", tmp_path


def _cleanup(path: str):
    if os.path.exists(path):
        import shutil

        shutil.rmtree(path, ignore_errors=True)


def main():
    fp16_model, id2label = build_fp16_mlmodel()

    fp16_tmp = _tmp_path("fp16")
    fp16_model.save(fp16_tmp)
    fp16_size = dir_size_mb(fp16_tmp)
    print(f"fp16 (pre-quantization) size: {fp16_size:.1f} MB", flush=True)

    quantized, method, tmp_path = quantize_to_budget(fp16_model)
    final_size = dir_size_mb(tmp_path)

    if final_size > SIZE_BUDGET_MB:
        _cleanup(fp16_tmp)
        print(
            f"ERROR: quantized model is {final_size:.1f} MB, over the "
            f"{SIZE_BUDGET_MB} MB budget even at the smallest tried setting.",
            file=sys.stderr,
        )
        sys.exit(1)

    if os.path.exists(OUT_PATH):
        import shutil

        shutil.rmtree(OUT_PATH)
    os.rename(tmp_path, OUT_PATH)
    _cleanup(fp16_tmp)

    print(f"quantization method: {method}", flush=True)
    print(f"saved RockSeg.mlpackage -> {OUT_PATH} ({final_size:.1f} MB)", flush=True)


if __name__ == "__main__":
    main()
