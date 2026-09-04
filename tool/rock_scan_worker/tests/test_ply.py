"""The PLY the phone opens. Fixed layout: float x/y/z, uchar r/g/b, 15 bytes
per vertex, binary little-endian, nothing else."""

from __future__ import annotations

import struct

import numpy as np
import pytest

from rock_scan_worker.ply import (
    VERTEX_DTYPE,
    empty_cloud,
    make_cloud,
    read_ply,
    subsample,
    write_ply,
)


def test_vertex_record_is_exactly_fifteen_packed_bytes():
    assert VERTEX_DTYPE.itemsize == 15
    assert VERTEX_DTYPE.names == ("x", "y", "z", "red", "green", "blue")


def test_header_declares_the_properties_in_the_agreed_order(tmp_path):
    path = tmp_path / "c.ply"
    write_ply(path, make_cloud(np.zeros((2, 3), dtype=np.float32)))
    header = path.read_bytes().split(b"end_header\n")[0].decode("ascii")
    lines = [line for line in header.splitlines() if line.startswith(("ply", "format", "element", "property"))]
    assert lines == [
        "ply",
        "format binary_little_endian 1.0",
        "element vertex 2",
        "property float x",
        "property float y",
        "property float z",
        "property uchar red",
        "property uchar green",
        "property uchar blue",
    ]


def test_body_is_little_endian_and_the_size_is_exact(tmp_path):
    path = tmp_path / "c.ply"
    cloud = make_cloud(
        np.array([[1.5, -2.0, 3.25]], dtype=np.float32),
        np.array([[10, 20, 30]], dtype=np.uint8),
    )
    write_ply(path, cloud)
    raw = path.read_bytes()
    body = raw.split(b"end_header\n", 1)[1]
    assert len(body) == 15
    x, y, z, r, g, b = struct.unpack("<fffBBB", body)
    assert (x, y, z) == (1.5, -2.0, 3.25)
    assert (r, g, b) == (10, 20, 30)


def test_round_trip_preserves_points_and_colours(tmp_path):
    rng = np.random.default_rng(7)
    cloud = make_cloud(rng.normal(size=(500, 3)) * 5.0, rng.integers(0, 256, size=(500, 3)))
    path = tmp_path / "c.ply"
    write_ply(path, cloud)
    back = read_ply(path)
    assert back.count == 500
    assert np.allclose(back.points, cloud.points)
    assert np.array_equal(back.colors, cloud.colors)


def test_an_empty_cloud_still_writes_a_valid_file(tmp_path):
    path = tmp_path / "c.ply"
    write_ply(path, empty_cloud())
    assert read_ply(path).count == 0


def test_non_finite_points_are_dropped_rather_than_poisoning_the_bounds():
    points = np.array([[0.0, 0.0, 0.0], [np.nan, 1.0, 1.0], [2.0, 2.0, 2.0]])
    cloud = make_cloud(points)
    assert cloud.count == 2
    assert cloud.bounds == ([0.0, 0.0, 0.0], [2.0, 2.0, 2.0])


def test_subsampling_caps_the_count_and_is_deterministic():
    cloud = make_cloud(np.random.default_rng(1).normal(size=(10_000, 3)))
    first, thinned = subsample(cloud, 300, seed=42)
    second, _ = subsample(cloud, 300, seed=42)
    assert thinned and first.count == 300
    assert np.array_equal(first.points, second.points)


def test_subsampling_leaves_a_small_cloud_alone():
    cloud = make_cloud(np.zeros((10, 3)))
    same, thinned = subsample(cloud, 300, seed=1)
    assert not thinned and same.count == 10


def test_reads_a_cloud_that_carries_extra_properties(tmp_path):
    """COLMAP's dense fusion writes normals. We must pick out our six
    properties and ignore the rest rather than refusing the file."""
    path = tmp_path / "fused.ply"
    dtype = np.dtype(
        [
            ("x", "<f4"), ("y", "<f4"), ("z", "<f4"),
            ("nx", "<f4"), ("ny", "<f4"), ("nz", "<f4"),
            ("red", "u1"), ("green", "u1"), ("blue", "u1"),
        ]
    )
    vertices = np.zeros(3, dtype=dtype)
    vertices["x"] = [1, 2, 3]
    vertices["red"] = [255, 0, 0]
    header = (
        "ply\nformat binary_little_endian 1.0\nelement vertex 3\n"
        "property float x\nproperty float y\nproperty float z\n"
        "property float nx\nproperty float ny\nproperty float nz\n"
        "property uchar red\nproperty uchar green\nproperty uchar blue\nend_header\n"
    )
    with path.open("wb") as handle:
        handle.write(header.encode("ascii"))
        vertices.tofile(handle)
    cloud = read_ply(path)
    assert cloud.count == 3
    assert np.allclose(cloud.points[:, 0], [1, 2, 3])
    assert cloud.colors[0, 0] == 255


def test_a_colourless_cloud_reads_back_grey_rather_than_failing(tmp_path):
    path = tmp_path / "plain.ply"
    header = (
        "ply\nformat binary_little_endian 1.0\nelement vertex 2\n"
        "property float x\nproperty float y\nproperty float z\nend_header\n"
    )
    with path.open("wb") as handle:
        handle.write(header.encode("ascii"))
        np.array([(0, 0, 0), (1, 1, 1)], dtype=[("x", "<f4"), ("y", "<f4"), ("z", "<f4")]).tofile(handle)
    cloud = read_ply(path)
    assert cloud.count == 2
    assert (cloud.colors > 0).all()


def test_ascii_ply_is_refused_loudly(tmp_path):
    path = tmp_path / "ascii.ply"
    path.write_text("ply\nformat ascii 1.0\nelement vertex 0\nend_header\n")
    with pytest.raises(ValueError):
        read_ply(path)
