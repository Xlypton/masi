"""The COLMAP binary sparse-model parser, against synthetic fixtures written
here. No COLMAP needed — and the camera-centre maths gets pinned, which is
the one place a plausible-looking wrong answer is easy to ship."""

from __future__ import annotations

import struct
from pathlib import Path

import numpy as np
import pytest

from rock_scan_worker.reconstruct.colmap_model import (
    pick_best_model,
    quaternion_to_matrix,
    read_images_bin,
    read_points3d_bin,
)


def write_images_bin(path: Path, images: list[dict]) -> None:
    with path.open("wb") as handle:
        handle.write(struct.pack("<Q", len(images)))
        for image in images:
            handle.write(
                struct.pack(
                    "<idddddddi",
                    image["id"],
                    *image["qvec"],
                    *image["tvec"],
                    image.get("camera_id", 1),
                )
            )
            handle.write(image["name"].encode("utf-8") + b"\x00")
            points2d = image.get("points2D", [])
            handle.write(struct.pack("<Q", len(points2d)))
            for x, y, point3d_id in points2d:
                handle.write(struct.pack("<ddQ", x, y, point3d_id))


def write_points3d_bin(path: Path, points: list[dict]) -> None:
    with path.open("wb") as handle:
        handle.write(struct.pack("<Q", len(points)))
        for point in points:
            handle.write(
                struct.pack(
                    "<QdddBBBd",
                    point["id"],
                    *point["xyz"],
                    *point["rgb"],
                    point["error"],
                )
            )
            track = point.get("track", [])
            handle.write(struct.pack("<Q", len(track)))
            for image_id, point2d_idx in track:
                handle.write(struct.pack("<II", image_id, point2d_idx))


def test_reads_images_with_names_and_track_padding(tmp_path):
    path = tmp_path / "images.bin"
    write_images_bin(
        path,
        [
            {
                "id": 1,
                "qvec": (1.0, 0.0, 0.0, 0.0),
                "tvec": (1.0, 2.0, 3.0),
                "name": "frame_00001.jpg",
                "points2D": [(1.0, 2.0, 7), (3.0, 4.0, 18446744073709551615)],
            },
            {
                "id": 2,
                "qvec": (0.0, 1.0, 0.0, 0.0),
                "tvec": (0.0, 0.0, 0.0),
                "name": "frame_00002.jpg",
                "points2D": [],
            },
        ],
    )
    images = read_images_bin(path)
    assert [i.name for i in images] == ["frame_00001.jpg", "frame_00002.jpg"]
    assert images[0].num_points2D == 2


def test_camera_centre_is_minus_r_transpose_t_not_the_translation(tmp_path):
    """`tvec` is not where the camera is. Getting this wrong puts every
    camera somewhere plausible and entirely fictional."""
    path = tmp_path / "images.bin"
    # 90 degrees about Z, so the answer differs from -t in an obvious way.
    qvec = (np.cos(np.pi / 4), 0.0, 0.0, np.sin(np.pi / 4))
    tvec = (1.0, 0.0, 0.0)
    write_images_bin(path, [{"id": 1, "qvec": qvec, "tvec": tvec, "name": "a.jpg"}])
    centre = read_images_bin(path)[0].centre
    expected = -quaternion_to_matrix(qvec).T @ np.asarray(tvec)
    assert np.allclose(centre, expected)
    assert not np.allclose(centre, [-1.0, 0.0, 0.0])


def test_identity_rotation_puts_the_camera_at_minus_t(tmp_path):
    path = tmp_path / "images.bin"
    write_images_bin(path, [{"id": 1, "qvec": (1.0, 0.0, 0.0, 0.0), "tvec": (1.0, 2.0, 3.0), "name": "a.jpg"}])
    assert np.allclose(read_images_bin(path)[0].centre, [-1.0, -2.0, -3.0])


def test_quaternion_normalises_before_use():
    scaled = quaternion_to_matrix((2.0, 0.0, 0.0, 0.0))
    assert np.allclose(scaled, np.eye(3))


def test_reads_points_with_colours_and_errors(tmp_path):
    path = tmp_path / "points3D.bin"
    write_points3d_bin(
        path,
        [
            {"id": 1, "xyz": (1.0, 2.0, 3.0), "rgb": (255, 0, 0), "error": 0.5, "track": [(1, 0), (2, 1)]},
            {"id": 2, "xyz": (-1.0, 0.0, 1.0), "rgb": (0, 255, 0), "error": 1.5, "track": [(1, 2)]},
        ],
    )
    points = read_points3d_bin(path)
    assert points.count == 2
    assert np.allclose(points.xyz[0], [1.0, 2.0, 3.0])
    assert np.array_equal(points.rgb[1], [0, 255, 0])
    assert float(np.mean(points.error)) == pytest.approx(1.0)
    assert list(points.track_length) == [2, 1]


def test_an_empty_model_parses_to_nothing(tmp_path):
    path = tmp_path / "points3D.bin"
    write_points3d_bin(path, [])
    assert read_points3d_bin(path).count == 0


def test_a_truncated_model_file_is_an_error_not_a_silent_short_read(tmp_path):
    path = tmp_path / "images.bin"
    path.write_bytes(struct.pack("<Q", 5))  # claims five images, has none
    with pytest.raises(ValueError):
        read_images_bin(path)


def test_picks_the_sub_model_with_the_most_registered_images(tmp_path):
    """The mapper splits a video that broke into disconnected pieces. The
    biggest piece is the one that actually covers the wall."""
    sparse = tmp_path / "sparse"
    for name, count in (("0", 2), ("1", 5)):
        model = sparse / name
        model.mkdir(parents=True)
        write_images_bin(
            model / "images.bin",
            [
                {"id": i, "qvec": (1.0, 0.0, 0.0, 0.0), "tvec": (0.0, 0.0, 0.0), "name": f"{i}.jpg"}
                for i in range(count)
            ],
        )
        write_points3d_bin(model / "points3D.bin", [])
    assert pick_best_model(sparse).name == "1"


def test_no_model_directory_is_none(tmp_path):
    assert pick_best_model(tmp_path / "missing") is None
    empty = tmp_path / "sparse"
    empty.mkdir()
    assert pick_best_model(empty) is None
