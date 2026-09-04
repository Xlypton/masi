"""A synthetic crag: three textured planes, a camera walking past them.

Why this exists. `ffmpeg`'s own test patterns (`testsrc2`, `smptebars`) look
like video but are useless here — they are 2D, so there is no parallax to
recover and COLMAP has nothing to triangulate. A real end-to-end test needs a
scene with actual 3D structure and actual texture, which is what this builds:
three planes meeting in a corner (like the inside of a dihedral, which is
also a shape climbers scan), each painted with high-frequency random shapes
that SIFT can key off, rendered from a moving pinhole camera by warping each
plane's texture through the exact homography its corners imply.

Pure numpy + Pillow. It is deliberately a *test helper*, not part of the
worker: nothing here ships.
"""

from __future__ import annotations

import math
from dataclasses import dataclass
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw


def make_texture(size: int = 512, *, seed: int = 0) -> Image.Image:
    """A high-contrast, corner-rich texture. Rock-like enough for SIFT."""
    rng = np.random.default_rng(seed)
    base = rng.integers(60, 200, size=(size // 8, size // 8, 3), dtype=np.uint8)
    image = Image.fromarray(base).resize((size, size), Image.BILINEAR)
    draw = ImageDraw.Draw(image)
    for _ in range(260):
        x, y = rng.integers(0, size, size=2)
        radius = int(rng.integers(4, 26))
        colour = tuple(int(c) for c in rng.integers(0, 256, size=3))
        if rng.random() < 0.5:
            draw.ellipse([x - radius, y - radius, x + radius, y + radius], fill=colour)
        else:
            draw.rectangle([x - radius, y - radius, x + radius, y + radius], fill=colour)
    return image


@dataclass(frozen=True)
class Plane:
    """A textured quad, given by its four 3D corners in texture order."""

    corners: np.ndarray  # (4, 3): top-left, top-right, bottom-right, bottom-left
    texture: Image.Image


def default_scene(seed: int = 0) -> list[Plane]:
    """A dihedral: back wall, left wall, floor."""
    back = np.array([[-1, 1, 0], [1, 1, 0], [1, -1, 0], [-1, -1, 0]], dtype=np.float64)
    left = np.array([[-1, 1, 1.6], [-1, 1, 0], [-1, -1, 0], [-1, -1, 1.6]], dtype=np.float64)
    floor = np.array([[-1, -1, 0], [1, -1, 0], [1, -1, 1.6], [-1, -1, 1.6]], dtype=np.float64)
    return [
        Plane(back, make_texture(seed=seed)),
        Plane(left, make_texture(seed=seed + 1)),
        Plane(floor, make_texture(seed=seed + 2)),
    ]


def look_at(eye: np.ndarray, target: np.ndarray, up: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    """World-to-camera rotation and translation, COLMAP's convention."""
    forward = target - eye
    forward = forward / np.linalg.norm(forward)
    right = np.cross(forward, up)
    right = right / np.linalg.norm(right)
    true_up = np.cross(right, forward)
    rotation = np.stack([right, -true_up, forward])  # rows: camera x, y, z axes
    translation = -rotation @ eye
    return rotation, translation


def project(points: np.ndarray, rotation: np.ndarray, translation: np.ndarray, focal: float,
            width: int, height: int) -> np.ndarray:
    camera = (rotation @ points.T).T + translation
    depth = camera[:, 2]
    x = focal * camera[:, 0] / depth + width / 2.0
    y = focal * camera[:, 1] / depth + height / 2.0
    return np.stack([x, y], axis=1)


def _homography(source: np.ndarray, destination: np.ndarray) -> np.ndarray:
    """The 3x3 mapping `source` (4 points) onto `destination` (4 points)."""
    rows = []
    for (sx, sy), (dx, dy) in zip(source, destination):
        rows.append([sx, sy, 1, 0, 0, 0, -dx * sx, -dx * sy, -dx])
        rows.append([0, 0, 0, sx, sy, 1, -dy * sx, -dy * sy, -dy])
    _, _, vt = np.linalg.svd(np.asarray(rows, dtype=np.float64))
    matrix = vt[-1].reshape(3, 3)
    return matrix / matrix[2, 2]


def render_view(
    scene: list[Plane],
    eye: np.ndarray,
    *,
    width: int = 800,
    height: int = 600,
    focal: float = 700.0,
    target: np.ndarray | None = None,
) -> Image.Image:
    target = np.array([0.0, 0.0, 0.0]) if target is None else target
    rotation, translation = look_at(eye, target, np.array([0.0, 1.0, 0.0]))
    canvas = Image.new("RGB", (width, height), (25, 25, 30))

    for plane in scene:
        projected = project(plane.corners, rotation, translation, focal, width, height)
        if not np.isfinite(projected).all():
            continue
        camera_depth = ((rotation @ plane.corners.T).T + translation)[:, 2]
        if (camera_depth <= 0.05).any():
            continue  # behind or through the camera; skip rather than smear
        tw, th = plane.texture.size
        texture_corners = np.array([[0, 0], [tw, 0], [tw, th], [0, th]], dtype=np.float64)
        # PIL's PERSPECTIVE transform samples the SOURCE for each output
        # pixel, so it wants image -> texture, i.e. the inverse homography.
        inverse = _homography(projected, texture_corners)
        coefficients = tuple((inverse / inverse[2, 2]).ravel()[:8])
        warped = plane.texture.transform(
            (width, height), Image.PERSPECTIVE, coefficients, Image.BILINEAR
        )
        mask = Image.new("L", (width, height), 0)
        ImageDraw.Draw(mask).polygon([tuple(p) for p in projected], fill=255)
        canvas.paste(warped, (0, 0), mask)
    return canvas


def camera_path(count: int) -> list[np.ndarray]:
    """A slow arc past the corner: real translation, so real parallax."""
    path = []
    for index in range(count):
        t = index / max(count - 1, 1)
        angle = math.radians(-26 + 52 * t)
        radius = 3.4
        path.append(
            np.array(
                [
                    radius * math.sin(angle),
                    0.35 * math.sin(t * math.pi),  # a little vertical drift
                    -radius * math.cos(angle),
                ]
            )
        )
    return path


def render_frames(out_dir: Path, *, count: int = 36, seed: int = 0, **kwargs) -> list[Path]:
    out_dir.mkdir(parents=True, exist_ok=True)
    scene = default_scene(seed=seed)
    paths = []
    for index, eye in enumerate(camera_path(count)):
        frame = render_view(scene, eye, **kwargs)
        path = out_dir / f"view_{index:04d}.png"
        frame.save(path)
        paths.append(path)
    return paths


def render_video(destination: Path, *, count: int = 36, fps: int = 6, seed: int = 0,
                 ffmpeg_bin: str = "ffmpeg", **kwargs) -> Path:
    """Render the scene and encode it, so the worker sees a real video file."""
    import subprocess
    import tempfile

    with tempfile.TemporaryDirectory() as scratch:
        frames_dir = Path(scratch)
        render_frames(frames_dir, count=count, seed=seed, **kwargs)
        destination.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(
            [
                ffmpeg_bin, "-y", "-hide_banner", "-loglevel", "error",
                "-framerate", str(fps),
                "-i", str(frames_dir / "view_%04d.png"),
                "-c:v", "libx264", "-crf", "16", "-preset", "veryfast",
                "-pix_fmt", "yuv420p",
                str(destination),
            ],
            check=True,
            capture_output=True,
        )
    return destination
