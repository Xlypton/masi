"""The one seam this worker is designed around.

Everything above this line — the queue, Storage, the schema, the CLI — knows
only: *a directory of frames goes in, points and camera positions come out*.
That is deliberate. The COLMAP/SIFT front-end here is the part most likely to
be replaced (hloc + SuperPoint/SuperGlue for texture-poor rock, or glomap for
speed), and that swap must be a new `Reconstructor` and one line in the
registry, not a change to how scans are claimed or artifacts stored.

So the contract is narrow on purpose:

* in  — a frames directory, a scratch directory, GPU and quality preferences,
        and a progress callback taking 0.0..1.0.
* out — `ReconstructionResult`: a coloured point cloud in some arbitrary
        frame, camera positions in that same frame, and the handful of
        quality numbers the manifest reports.

`metres_per_unit` is part of the contract precisely because it is almost
always `None`. Structure-from-motion recovers geometry only up to a
similarity transform, so an engine that has not measured something real MUST
say so; the app refuses to show measurements when it is null, and a
placeholder 1.0 would make it show wrong ones instead.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable, Protocol, runtime_checkable

from ..ply import PointCloud, empty_cloud

ProgressFn = Callable[[float, str], None]


@dataclass(frozen=True)
class ReconstructionRequest:
    frames_dir: Path
    work_dir: Path
    frame_count: int
    use_gpu: bool = True
    #: Dense MVS. Far slower, CUDA-only in practice, and a quality tier
    #: rather than a default.
    dense: bool = False
    progress: ProgressFn = lambda _fraction, _label: None


@dataclass(frozen=True)
class ReconstructionResult:
    cloud: PointCloud = field(default_factory=empty_cloud)
    #: Camera POSITIONS only, in the cloud's own frame. No orientation — see
    #: `RockScanManifest.cameras` for why.
    cameras: tuple[tuple[float, float, float], ...] = ()
    frames_registered: int = 0
    mean_reprojection_error: float | None = None
    engine: str = "unknown"
    engine_version: str | None = None
    #: Real-world scale, or None for "arbitrary units" — the normal case.
    metres_per_unit: float | None = None
    scale_source: str | None = None
    #: Whether the GPU was actually used, for the log and nothing else.
    used_gpu: bool = False
    dense_used: bool = False

    @property
    def point_count(self) -> int:
        return self.cloud.count


@runtime_checkable
class Reconstructor(Protocol):
    """What a reconstruction back end must offer. Two methods."""

    name: str

    def preflight(self) -> None:
        """Raise `ToolMissing` if this back end cannot run on this machine."""

    def reconstruct(self, request: ReconstructionRequest) -> ReconstructionResult:
        """Do the work, or raise `ScanFailure` / `TransientError`."""
