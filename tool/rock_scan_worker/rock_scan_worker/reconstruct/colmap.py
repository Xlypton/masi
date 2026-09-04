"""The COLMAP back end: SIFT features, matching, incremental mapping.

Structured as four external commands and a parse. Everything COLMAP-specific
lives behind `Reconstructor` (see `base.py`) — including the diagnosis of
*why* a reconstruction failed, which is the one thing a generic caller cannot
do. Feature counts read straight out of COLMAP's own SQLite database are how
"the rock was too smooth to match" is told apart from "the climber moved too
fast", and those are different sentences on the phone.

GPU: `--gpu auto` asks for CUDA/OpenGL and, if the binary refuses, retries on
CPU with a loud log line rather than failing the scan. A headless Windows box
with an NVIDIA card usually works; a CPU-only COLMAP build silently would not,
and the fallback is the difference between a slow scan and a dead queue.
"""

from __future__ import annotations

import re
import sqlite3
from pathlib import Path
from typing import Callable, Sequence

import numpy as np

from .. import reasons
from ..config import Config
from ..errors import ScanFailure, ToolMissing, TransientError
from ..ply import PointCloud, make_cloud, read_ply
from ..process import CommandResult, run, which
from .base import ReconstructionRequest, ReconstructionResult
from .colmap_model import pick_best_model, read_images_bin, read_points3d_bin

#: Stderr fingerprints that mean "no usable GPU here", not "bad input".
_GPU_FAILURE_MARKERS = (
    "cuda",
    "no gpu",
    "opengl",
    "glew",
    "qt_qpa",
    "could not create opengl context",
    "display",
    "siftgpu",
)

#: Below this many SIFT keypoints on a typical frame, the rock simply has no
#: texture to match. Chosen well under COLMAP's default 8192 cap: real rock
#: gives thousands, blank granite in flat light gives a few hundred.
MIN_MEDIAN_KEYPOINTS = 300

#: Exhaustive matching is O(n^2) image pairs but strictly better at loop
#: closure. Below this many frames it costs seconds, so take the quality.
EXHAUSTIVE_MATCH_LIMIT = 60


class ColmapReconstructor:
    """`Reconstructor` implementation over the `colmap` CLI."""

    name = "colmap"

    def __init__(
        self,
        config: Config,
        *,
        log: Callable[[str], None] | None = None,
    ) -> None:
        self._config = config
        self._log = log or (lambda _m: None)
        self._gpu_ok = config.gpu != "off"
        #: Whether a step actually RAN on the GPU this reconstruction.
        self._used_gpu = False
        self._version: str | None = None

    # -- lifecycle ----------------------------------------------------------

    def preflight(self) -> None:
        if which(self._config.colmap_bin) is None:
            raise ToolMissing(
                f"COLMAP ({self._config.colmap_bin!r}) is not on PATH. Install the "
                "CUDA build and re-open the shell — see tool/rock_scan_worker/README.md."
            )

    def version(self) -> str | None:
        if self._version is not None:
            return self._version
        try:
            result = run([self._config.colmap_bin, "-h"], timeout_s=60.0)
        except (ToolMissing, TransientError):
            return None
        match = re.search(r"COLMAP\s+([0-9][^\s,;]*)", result.stdout + result.stderr)
        self._version = match.group(1) if match else None
        return self._version

    # -- the work -----------------------------------------------------------

    def reconstruct(self, request: ReconstructionRequest) -> ReconstructionResult:
        self.preflight()
        work = request.work_dir
        work.mkdir(parents=True, exist_ok=True)
        database = work / "database.db"
        sparse_dir = work / "sparse"
        sparse_dir.mkdir(parents=True, exist_ok=True)

        want_gpu = self._gpu_ok and request.use_gpu and self._config.gpu != "off"
        self._log(
            f"colmap: gpu mode {self._config.gpu!r}; "
            + ("attempting GPU" if want_gpu else "running on CPU")
        )
        # Reset per run, because this records what ACTUALLY happened rather
        # than what was permitted. `_gpu_ok` only says the GPU has not been
        # proven broken, so reporting it as "used" claimed a GPU run on a
        # CPU-only one — the wrong answer in precisely the situation the
        # field exists for, which is somebody working out why a machine's
        # reconstructions behave differently from another's.
        self._used_gpu = False

        request.progress(0.02, "extracting features")
        self._feature_extractor(database, request)

        median_keypoints = _median_keypoints(database)
        if median_keypoints is not None:
            self._log(f"colmap: median {median_keypoints} keypoints per frame")
            if median_keypoints < MIN_MEDIAN_KEYPOINTS:
                raise ScanFailure(
                    reasons.texture_poor_rock(),
                    detail=f"median keypoints {median_keypoints} < {MIN_MEDIAN_KEYPOINTS}",
                )

        request.progress(0.30, "matching frames")
        self._matcher(database, request)

        request.progress(0.55, "building the sparse model")
        self._mapper(database, sparse_dir, request)

        model_dir = pick_best_model(sparse_dir)
        if model_dir is None:
            raise ScanFailure(
                reasons.reconstruction_empty(),
                detail="mapper produced no sub-model with images and points",
            )

        images = read_images_bin(model_dir / "images.bin")
        points = read_points3d_bin(model_dir / "points3D.bin")
        self._log(
            f"colmap: registered {len(images)} of {request.frame_count} frames, "
            f"{points.count} sparse points"
        )

        cloud = make_cloud(points.xyz, points.rgb)
        dense_used = False
        if request.dense:
            request.progress(0.70, "running dense reconstruction")
            dense_cloud = self._dense(work, model_dir, request)
            if dense_cloud is not None and dense_cloud.count > cloud.count:
                cloud = dense_cloud
                dense_used = True

        request.progress(0.95, "reconstruction finished")
        mean_error = (
            float(np.mean(points.error)) if points.count and points.error.size else None
        )
        return ReconstructionResult(
            cloud=cloud,
            cameras=tuple(image.centre for image in images),
            frames_registered=len(images),
            mean_reprojection_error=mean_error,
            engine=self.name,
            engine_version=self.version(),
            # No metric scale is recovered anywhere in this pipeline. Saying
            # so is a requirement, not an omission — see base.py.
            metres_per_unit=None,
            scale_source=None,
            used_gpu=self._used_gpu,
            dense_used=dense_used,
        )

    # -- steps --------------------------------------------------------------

    def _feature_extractor(self, database: Path, request: ReconstructionRequest) -> None:
        def build(gpu: bool) -> list[str]:
            return [
                self._config.colmap_bin,
                "feature_extractor",
                "--database_path",
                str(database),
                "--image_path",
                str(request.frames_dir),
                # One physical camera filmed the whole video, so sharing
                # intrinsics across every frame is both true and a large
                # stability win for the bundle adjustment.
                "--ImageReader.single_camera",
                "1",
                "--ImageReader.camera_model",
                "OPENCV",
                "--SiftExtraction.use_gpu",
                "1" if gpu else "0",
            ]

        self._run_step(build, "feature extraction", request)

    def _matcher(self, database: Path, request: ReconstructionRequest) -> None:
        exhaustive = request.frame_count <= EXHAUSTIVE_MATCH_LIMIT

        def build(gpu: bool) -> list[str]:
            if exhaustive:
                return [
                    self._config.colmap_bin,
                    "exhaustive_matcher",
                    "--database_path",
                    str(database),
                    "--SiftMatching.use_gpu",
                    "1" if gpu else "0",
                ]
            # Video frames arrive in temporal order, so neighbours in the
            # filename are neighbours in space: sequential matching gets the
            # same graph as exhaustive for a fraction of the pairs.
            return [
                self._config.colmap_bin,
                "sequential_matcher",
                "--database_path",
                str(database),
                "--SequentialMatching.overlap",
                "10",
                "--SequentialMatching.quadratic_overlap",
                "1",
                "--SiftMatching.use_gpu",
                "1" if gpu else "0",
            ]

        self._log(
            "colmap: matching "
            + ("exhaustively" if exhaustive else "sequentially")
            + f" over {request.frame_count} frames"
        )
        self._run_step(build, "matching", request)

    def _mapper(
        self, database: Path, sparse_dir: Path, request: ReconstructionRequest
    ) -> None:
        result = run(
            [
                self._config.colmap_bin,
                "mapper",
                "--database_path",
                str(database),
                "--image_path",
                str(request.frames_dir),
                "--output_path",
                str(sparse_dir),
            ],
            timeout_s=self._config.subprocess_timeout_s,
            log=self._log,
        )
        if not result.ok and not any(sparse_dir.iterdir()):
            raise ScanFailure(
                reasons.reconstruction_empty(),
                detail=f"mapper exited {result.returncode}: {result.tail(6)}",
            )

    def _dense(
        self, work: Path, model_dir: Path, request: ReconstructionRequest
    ) -> PointCloud | None:
        """Optional MVS tier. Best-effort: never fails a scan on its own.

        Dense needs CUDA in every practical build, so a failure here means
        "this box cannot do the quality tier", not "this video is bad" — and
        the sparse cloud we already have is a perfectly good answer.
        """
        dense_dir = work / "dense"
        dense_dir.mkdir(parents=True, exist_ok=True)
        steps = [
            [
                self._config.colmap_bin,
                "image_undistorter",
                "--image_path",
                str(request.frames_dir),
                "--input_path",
                str(model_dir),
                "--output_path",
                str(dense_dir),
                "--output_type",
                "COLMAP",
            ],
            [
                self._config.colmap_bin,
                "patch_match_stereo",
                "--workspace_path",
                str(dense_dir),
                "--workspace_format",
                "COLMAP",
                "--PatchMatchStereo.geom_consistency",
                "true",
            ],
            [
                self._config.colmap_bin,
                "stereo_fusion",
                "--workspace_path",
                str(dense_dir),
                "--workspace_format",
                "COLMAP",
                "--input_type",
                "geometric",
                "--output_path",
                str(dense_dir / "fused.ply"),
            ],
        ]
        for step in steps:
            try:
                result = run(
                    step, timeout_s=self._config.subprocess_timeout_s, log=self._log
                )
            except (ToolMissing, TransientError) as exc:
                self._log(f"colmap: dense stage unavailable, keeping sparse ({exc})")
                return None
            if not result.ok:
                self._log(
                    "colmap: dense stage failed, keeping the sparse cloud: "
                    + result.tail(4)
                )
                return None
        fused = dense_dir / "fused.ply"
        if not fused.is_file():
            return None
        try:
            return read_ply(fused)
        except (OSError, ValueError) as exc:
            self._log(f"colmap: could not read fused cloud, keeping sparse ({exc})")
            return None

    # -- GPU fallback -------------------------------------------------------

    def _run_step(
        self,
        build: Callable[[bool], Sequence[str]],
        label: str,
        request: ReconstructionRequest,
    ) -> CommandResult:
        want_gpu = self._gpu_ok and request.use_gpu and self._config.gpu != "off"
        result = run(
            list(build(want_gpu)),
            timeout_s=self._config.subprocess_timeout_s,
            log=self._log,
        )
        if result.ok:
            if want_gpu:
                self._used_gpu = True
            return result

        if want_gpu and self._config.gpu == "auto" and _looks_like_gpu_failure(result):
            self._log(
                f"colmap: {label} could not use the GPU on this machine; "
                "falling back to CPU (this will be much slower). Reason: "
                + result.first_error_line()
            )
            self._gpu_ok = False
            retry = run(
                list(build(False)),
                timeout_s=self._config.subprocess_timeout_s,
                log=self._log,
            )
            if retry.ok:
                return retry
            result = retry

        if want_gpu and self._config.gpu == "on" and _looks_like_gpu_failure(result):
            raise TransientError(
                f"colmap {label} needs a GPU and could not get one, and --gpu=on "
                f"forbids the CPU fallback: {result.first_error_line()}"
            )
        # An exit code here is an engine problem, not a diagnosis of the
        # video, so it is transient: the same frames on a working box may be
        # perfectly reconstructible.
        raise TransientError(f"colmap {label} exited {result.returncode}: {result.tail(6)}")


def _looks_like_gpu_failure(result: CommandResult) -> bool:
    haystack = (result.stderr + result.stdout).lower()
    return any(marker in haystack for marker in _GPU_FAILURE_MARKERS)


def _median_keypoints(database: Path) -> int | None:
    """Median SIFT keypoints per image, from COLMAP's own database.

    Read-only and entirely best-effort: a schema change in a future COLMAP
    should cost us a diagnosis, never a scan.
    """
    if not database.is_file():
        return None
    try:
        with sqlite3.connect(f"file:{database}?mode=ro", uri=True) as connection:
            rows = [int(r[0]) for r in connection.execute("SELECT rows FROM keypoints")]
    except sqlite3.Error:
        return None
    if not rows:
        return None
    return int(np.median(np.asarray(rows, dtype=np.int64)))
