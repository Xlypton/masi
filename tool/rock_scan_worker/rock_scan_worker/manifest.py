"""The manifest: everything about a finished scan except the points.

This is a WIRE CONTRACT with
`lib/features/scan/domain/rock_scan_manifest.dart`, which is the
authoritative consumer. Keys are fixed; add, never rename. `version` is the
only key the reader requires, and every other value may legitimately be null
— a worker that could not compute a figure must say "unknown" rather than
invent one, because the UI can only be honest about what it can represent.

The one rule with teeth: `metresPerUnit` is null unless real metric scale was
recovered. Structure-from-motion is defined only up to a similarity
transform, so an arbitrary-scale cloud reporting 1.0 would make the app show
a climber measurements that are confidently wrong.
"""

from __future__ import annotations

import json
import math
from typing import Any, Sequence

from . import MANIFEST_VERSION
from .config import Config
from .ply import PointCloud
from .reconstruct.base import ReconstructionResult

#: Coordinate rounding. 6 decimals is far finer than any reconstruction's
#: actual precision and keeps the JSON in a database column small.
COORD_DECIMALS = 6
CAMERA_DECIMALS = 4


def build_manifest(
    *,
    result: ReconstructionResult,
    cloud: PointCloud,
    frames_extracted: int,
    max_cameras: int = 300,
) -> dict[str, Any]:
    """The manifest document for one finished reconstruction."""
    bounds_min, bounds_max = cloud.bounds
    registered = int(result.frames_registered)
    ratio = (registered / frames_extracted) if frames_extracted > 0 else None

    metres_per_unit = _finite_positive(result.metres_per_unit)
    # scaleSource is null whenever metresPerUnit is — the Dart doc states the
    # pairing, and a source without a number is worse than neither.
    scale_source = result.scale_source if metres_per_unit is not None else None

    return {
        "version": MANIFEST_VERSION,
        "engine": result.engine,
        "engineVersion": result.engine_version,
        "framesExtracted": int(frames_extracted),
        "framesRegistered": registered,
        "pointCount": cloud.count,
        "boundsMin": _round_vec(bounds_min, COORD_DECIMALS),
        "boundsMax": _round_vec(bounds_max, COORD_DECIMALS),
        "cameras": _cap_cameras(result.cameras, max_cameras),
        "registeredRatio": _round_scalar(ratio, 4),
        "meanReprojectionError": _round_scalar(result.mean_reprojection_error, 4),
        "metresPerUnit": metres_per_unit,
        "scaleSource": scale_source,
    }


def manifest_for_config(
    config: Config, *, result: ReconstructionResult, cloud: PointCloud, frames_extracted: int
) -> dict[str, Any]:
    return build_manifest(
        result=result,
        cloud=cloud,
        frames_extracted=frames_extracted,
        max_cameras=config.max_manifest_cameras,
    )


def manifest_json(manifest: dict[str, Any]) -> str:
    """Compact JSON — this goes into a text column on every sync pull."""
    return json.dumps(manifest, separators=(",", ":"), allow_nan=False)


def _cap_cameras(
    cameras: Sequence[Sequence[float]], limit: int
) -> list[list[float]]:
    """At most `limit` camera positions, evenly spread ALONG THE PATH.

    Evenly spread, not the first N: the trail exists so a climber can see
    whether they covered the whole face, and the first 300 of 900 frames is
    the left-hand third of the wall.
    """
    usable = [_round_vec(list(c), CAMERA_DECIMALS) for c in cameras]
    clean = [c for c in usable if c is not None]
    if limit <= 0 or len(clean) <= limit:
        return clean  # type: ignore[return-value]
    step = (len(clean) - 1) / float(limit - 1) if limit > 1 else 0.0
    picked = [clean[int(round(i * step))] for i in range(limit)]
    return picked  # type: ignore[return-value]


def _round_vec(vec: Sequence[float] | None, decimals: int) -> list[float] | None:
    if vec is None:
        return None
    values = list(vec)[:3]
    if len(values) < 3:
        return None
    out: list[float] = []
    for raw in values:
        try:
            number = float(raw)
        except (TypeError, ValueError):
            return None
        if not math.isfinite(number):
            return None
        out.append(round(number, decimals))
    return out


def _round_scalar(value: float | None, decimals: int) -> float | None:
    if value is None:
        return None
    try:
        number = float(value)
    except (TypeError, ValueError):
        return None
    if not math.isfinite(number):
        return None
    return round(number, decimals)


def _finite_positive(value: float | None) -> float | None:
    number = _round_scalar(value, 8)
    if number is None or number <= 0:
        return None
    return number
