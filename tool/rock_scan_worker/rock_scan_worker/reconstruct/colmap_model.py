"""Readers for COLMAP's binary sparse model, in pure Python.

Parsing `images.bin` and `points3D.bin` ourselves — rather than depending on
pycolmap or shelling out to `model_converter` — keeps the worker's install to
`pip install -r requirements.txt` on a Windows box, and keeps the parser
unit-testable against synthetic fixtures with no COLMAP anywhere. The formats
are stable and documented; the two we need are:

    images.bin    uint64 count, then per image:
                  uint32 id, 4x double qvec (w,x,y,z), 3x double tvec,
                  uint32 camera_id, NUL-terminated name,
                  uint64 num_points2D, then that many (double x, double y,
                  uint64 point3D_id)

    points3D.bin  uint64 count, then per point:
                  uint64 id, 3x double xyz, 3x uint8 rgb, double error,
                  uint64 track_len, then track_len x (uint32, uint32)
"""

from __future__ import annotations

import struct
from dataclasses import dataclass
from pathlib import Path
from typing import BinaryIO

import numpy as np


@dataclass(frozen=True)
class ColmapImage:
    id: int
    qvec: tuple[float, float, float, float]
    tvec: tuple[float, float, float]
    camera_id: int
    name: str
    num_points2D: int

    @property
    def centre(self) -> tuple[float, float, float]:
        """Camera position in world coordinates: `C = -R(q)^T t`.

        COLMAP stores the world-TO-camera rotation, so the position of the
        camera itself is not `tvec` — a mistake that puts every camera in a
        plausible-looking but wrong place, which is exactly the kind of bug
        the manifest's camera trail would show and nothing else would.
        """
        rotation = quaternion_to_matrix(self.qvec)
        centre = -rotation.T @ np.asarray(self.tvec, dtype=np.float64)
        return (float(centre[0]), float(centre[1]), float(centre[2]))


@dataclass(frozen=True)
class ColmapPoints:
    xyz: np.ndarray  # (N, 3) float64
    rgb: np.ndarray  # (N, 3) uint8
    error: np.ndarray  # (N,) float64
    track_length: np.ndarray  # (N,) int64

    @property
    def count(self) -> int:
        return int(self.xyz.shape[0])


def quaternion_to_matrix(qvec: tuple[float, float, float, float]) -> np.ndarray:
    """COLMAP's (w, x, y, z), normalised, as a 3x3 rotation matrix."""
    q = np.asarray(qvec, dtype=np.float64)
    norm = float(np.linalg.norm(q))
    if norm == 0:
        return np.eye(3)
    w, x, y, z = q / norm
    return np.array(
        [
            [1 - 2 * (y * y + z * z), 2 * (x * y - w * z), 2 * (x * z + w * y)],
            [2 * (x * y + w * z), 1 - 2 * (x * x + z * z), 2 * (y * z - w * x)],
            [2 * (x * z - w * y), 2 * (y * z + w * x), 1 - 2 * (x * x + y * y)],
        ]
    )


def _read(handle: BinaryIO, fmt: str) -> tuple:
    size = struct.calcsize(fmt)
    data = handle.read(size)
    if len(data) != size:
        raise ValueError("truncated COLMAP model file")
    return struct.unpack(fmt, data)


def read_images_bin(path: Path) -> list[ColmapImage]:
    images: list[ColmapImage] = []
    with path.open("rb") as handle:
        (count,) = _read(handle, "<Q")
        for _ in range(count):
            image_id, qw, qx, qy, qz, tx, ty, tz, camera_id = _read(handle, "<idddddddi")
            name_bytes = bytearray()
            while True:
                char = handle.read(1)
                if not char or char == b"\x00":
                    break
                name_bytes += char
            (num_points2D,) = _read(handle, "<Q")
            handle.seek(num_points2D * 24, 1)  # skip (double, double, uint64)
            images.append(
                ColmapImage(
                    id=int(image_id),
                    qvec=(qw, qx, qy, qz),
                    tvec=(tx, ty, tz),
                    camera_id=int(camera_id),
                    name=name_bytes.decode("utf-8", "replace"),
                    num_points2D=int(num_points2D),
                )
            )
    return images


def read_points3d_bin(path: Path) -> ColmapPoints:
    xyz: list[tuple[float, float, float]] = []
    rgb: list[tuple[int, int, int]] = []
    errors: list[float] = []
    tracks: list[int] = []
    with path.open("rb") as handle:
        (count,) = _read(handle, "<Q")
        for _ in range(count):
            _point_id, x, y, z, r, g, b, error = _read(handle, "<QdddBBBd")
            (track_length,) = _read(handle, "<Q")
            handle.seek(track_length * 8, 1)  # skip (uint32, uint32) pairs
            xyz.append((x, y, z))
            rgb.append((r, g, b))
            errors.append(error)
            tracks.append(int(track_length))
    return ColmapPoints(
        xyz=np.asarray(xyz, dtype=np.float64).reshape(-1, 3),
        rgb=np.asarray(rgb, dtype=np.uint8).reshape(-1, 3),
        error=np.asarray(errors, dtype=np.float64),
        track_length=np.asarray(tracks, dtype=np.int64),
    )


def pick_best_model(sparse_dir: Path) -> Path | None:
    """The sub-model with the most registered images.

    COLMAP's mapper writes `sparse/0`, `sparse/1`, ... when a video breaks
    into disconnected pieces — which is what happens when the climber
    stopped filming and restarted, or panned away from the face. Taking the
    largest is the right call: it is the one that actually covers the wall.
    """
    if not sparse_dir.is_dir():
        return None
    best: tuple[int, Path] | None = None
    for candidate in sorted(sparse_dir.iterdir()):
        images = candidate / "images.bin"
        points = candidate / "points3D.bin"
        if not (images.is_file() and points.is_file()):
            continue
        try:
            registered = len(read_images_bin(images))
        except (OSError, ValueError):
            continue
        if best is None or registered > best[0]:
            best = (registered, candidate)
    return best[1] if best else None
