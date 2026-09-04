"""Binary little-endian PLY: write, read back, and thin.

The wire format is fixed by the phone-side viewer and is exactly:

    property float x / float y / float z / uchar red / uchar green / uchar blue

15 bytes per vertex, no normals, no alpha, no padding. numpy structured
arrays are packed in field order with no alignment holes, so one `tofile`
after the ASCII header is the whole writer — and `read_ply`, which exists so
the tests can prove a round trip and so dense COLMAP fusion output can be
loaded back, is a genuinely general reader that picks those six properties
out of whatever else a producer wrote.
"""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from typing import BinaryIO

import numpy as np

#: The exact vertex layout the app expects.
VERTEX_DTYPE = np.dtype(
    [
        ("x", "<f4"),
        ("y", "<f4"),
        ("z", "<f4"),
        ("red", "u1"),
        ("green", "u1"),
        ("blue", "u1"),
    ]
)

HEADER_TEMPLATE = (
    "ply\n"
    "format binary_little_endian 1.0\n"
    "comment created by masi rock_scan_worker\n"
    "element vertex {count}\n"
    "property float x\n"
    "property float y\n"
    "property float z\n"
    "property uchar red\n"
    "property uchar green\n"
    "property uchar blue\n"
    "end_header\n"
)

_SCALAR_FORMATS = {
    "char": "i1",
    "int8": "i1",
    "uchar": "u1",
    "uint8": "u1",
    "short": "i2",
    "int16": "i2",
    "ushort": "u2",
    "uint16": "u2",
    "int": "i4",
    "int32": "i4",
    "uint": "u4",
    "uint32": "u4",
    "float": "f4",
    "float32": "f4",
    "double": "f8",
    "float64": "f8",
}


@dataclass(frozen=True)
class PointCloud:
    """Points and their colours, the only two things the viewer draws."""

    points: np.ndarray  # (N, 3) float32
    colors: np.ndarray  # (N, 3) uint8

    def __post_init__(self) -> None:
        if self.points.ndim != 2 or self.points.shape[1] != 3:
            raise ValueError(f"points must be (N, 3), got {self.points.shape}")
        if self.colors.shape != self.points.shape:
            raise ValueError("colors must match points in shape")

    @property
    def count(self) -> int:
        return int(self.points.shape[0])

    @property
    def bounds(self) -> tuple[list[float], list[float]] | tuple[None, None]:
        if self.count == 0:
            return (None, None)
        return (
            [float(v) for v in self.points.min(axis=0)],
            [float(v) for v in self.points.max(axis=0)],
        )


def empty_cloud() -> PointCloud:
    return PointCloud(
        points=np.zeros((0, 3), dtype=np.float32),
        colors=np.zeros((0, 3), dtype=np.uint8),
    )


def make_cloud(points: np.ndarray, colors: np.ndarray | None = None) -> PointCloud:
    pts = np.ascontiguousarray(np.asarray(points, dtype=np.float32).reshape(-1, 3))
    if colors is None:
        cols = np.full(pts.shape, 200, dtype=np.uint8)
    else:
        cols = np.ascontiguousarray(
            np.clip(np.asarray(colors), 0, 255).astype(np.uint8).reshape(-1, 3)
        )
    finite = np.isfinite(pts).all(axis=1)
    if not finite.all():
        # A single NaN from a degenerate triangulation would make the whole
        # bounding box NaN and leave the viewer with nothing to frame on.
        pts = pts[finite]
        cols = cols[finite]
    return PointCloud(points=pts, colors=cols)


def subsample(
    cloud: PointCloud, max_points: int, *, seed: int = 0
) -> tuple[PointCloud, bool]:
    """Uniform random thinning to `max_points`. Returns (cloud, was_thinned).

    Uniform, not voxel-gridded: it is one line, it cannot distort the shape
    the way an ill-chosen voxel size does, and the point of the cap is only
    that a phone can open the file.
    """
    if max_points <= 0 or cloud.count <= max_points:
        return cloud, False
    rng = np.random.default_rng(seed)
    picks = rng.choice(cloud.count, size=max_points, replace=False)
    picks.sort()
    return (
        PointCloud(points=cloud.points[picks], colors=cloud.colors[picks]),
        True,
    )


def write_ply(path: Path, cloud: PointCloud) -> int:
    """Write `cloud` to `path`; returns bytes written."""
    path.parent.mkdir(parents=True, exist_ok=True)
    vertices = np.empty(cloud.count, dtype=VERTEX_DTYPE)
    vertices["x"] = cloud.points[:, 0]
    vertices["y"] = cloud.points[:, 1]
    vertices["z"] = cloud.points[:, 2]
    vertices["red"] = cloud.colors[:, 0]
    vertices["green"] = cloud.colors[:, 1]
    vertices["blue"] = cloud.colors[:, 2]
    with path.open("wb") as handle:
        handle.write(HEADER_TEMPLATE.format(count=cloud.count).encode("ascii"))
        vertices.tofile(handle)
    return path.stat().st_size


def read_ply(path: Path) -> PointCloud:
    """Read x/y/z/red/green/blue out of a binary little-endian PLY.

    Tolerates extra properties (COLMAP's dense fusion writes normals) and a
    colourless cloud (filled mid-grey, so the viewer still draws something).
    """
    with path.open("rb") as handle:
        header = _read_header(handle)
        raw = np.fromfile(handle, dtype=header.dtype, count=header.count)

    if raw.size == 0:
        return empty_cloud()
    points = np.stack(
        [raw[name].astype(np.float32) for name in ("x", "y", "z")], axis=1
    )
    colour_names = [n for n in ("red", "green", "blue") if n in raw.dtype.names]
    if len(colour_names) == 3:
        colors = np.stack(
            [_to_byte(raw[name]) for name in colour_names], axis=1
        )
    else:
        colors = np.full(points.shape, 200, dtype=np.uint8)
    return PointCloud(points=points, colors=colors)


@dataclass(frozen=True)
class _Header:
    count: int
    dtype: np.dtype


def _read_header(handle: BinaryIO) -> _Header:
    line = handle.readline().strip()
    if line != b"ply":
        raise ValueError("not a PLY file")
    count = 0
    fields: list[tuple[str, str]] = []
    in_vertex_element = False
    little_endian = True
    while True:
        raw = handle.readline()
        if not raw:
            raise ValueError("PLY header ended without end_header")
        tokens = raw.strip().split()
        if not tokens:
            continue
        keyword = tokens[0].decode("ascii", "replace")
        if keyword == "format":
            fmt = tokens[1].decode("ascii", "replace")
            if fmt == "ascii":
                raise ValueError("ASCII PLY is not supported")
            little_endian = fmt != "binary_big_endian"
        elif keyword == "element":
            name = tokens[1].decode("ascii", "replace")
            in_vertex_element = name == "vertex"
            if in_vertex_element:
                count = int(tokens[2])
        elif keyword == "property" and in_vertex_element:
            if tokens[1] == b"list":
                raise ValueError("list properties on vertices are not supported")
            scalar = tokens[1].decode("ascii", "replace")
            name = tokens[2].decode("ascii", "replace")
            if scalar not in _SCALAR_FORMATS:
                raise ValueError(f"unknown PLY scalar type {scalar!r}")
            fields.append((name, _SCALAR_FORMATS[scalar]))
        elif keyword == "end_header":
            break
    if not fields:
        raise ValueError("PLY header declared no vertex properties")
    prefix = "<" if little_endian else ">"
    dtype = np.dtype([(name, prefix + fmt) for name, fmt in fields])
    for required in ("x", "y", "z"):
        if required not in dtype.names:
            raise ValueError(f"PLY vertex is missing {required!r}")
    return _Header(count=count, dtype=dtype)


def _to_byte(column: np.ndarray) -> np.ndarray:
    if column.dtype == np.uint8:
        return column
    if np.issubdtype(column.dtype, np.floating):
        # Float colour channels are conventionally 0..1.
        return np.clip(column * 255.0, 0, 255).astype(np.uint8)
    return np.clip(column, 0, 255).astype(np.uint8)
