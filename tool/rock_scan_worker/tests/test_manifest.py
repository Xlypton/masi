"""The manifest is a wire contract with `rock_scan_manifest.dart`. These
tests read that Dart file and hold us to it, rather than trusting a copy of
the field list that would drift the first time either side changed."""

from __future__ import annotations

import json
import re

import numpy as np
import pytest

from rock_scan_worker import MANIFEST_VERSION
from rock_scan_worker.manifest import build_manifest, manifest_json
from rock_scan_worker.ply import make_cloud
from rock_scan_worker.reconstruct.base import ReconstructionResult


@pytest.fixture(scope="session")
def dart_manifest_keys(repo_root) -> set[str]:
    source = repo_root / "lib" / "features" / "scan" / "domain" / "rock_scan_manifest.dart"
    if not source.is_file():
        pytest.skip(f"{source} not found; running outside the Masi checkout")
    return set(re.findall(r"decoded\['(\w+)'\]", source.read_text(encoding="utf-8")))


@pytest.fixture
def sample_cloud():
    points = np.array([[0.0, 0.0, 0.0], [1.0, 2.0, 3.0], [-1.0, 0.5, 2.0]], dtype=np.float32)
    return make_cloud(points, np.full((3, 3), 128, dtype=np.uint8))


@pytest.fixture
def sample_result():
    return ReconstructionResult(
        cameras=((0.0, 0.0, 0.0), (1.0, 0.0, 0.0), (2.0, 0.0, 0.0)),
        frames_registered=120,
        mean_reprojection_error=0.8123456,
        engine="colmap",
        engine_version="3.9.1",
    )


def test_emits_exactly_the_keys_the_dart_reader_looks_for(
    sample_result, sample_cloud, dart_manifest_keys
):
    manifest = build_manifest(result=sample_result, cloud=sample_cloud, frames_extracted=150)
    assert set(manifest) == dart_manifest_keys


def test_version_is_the_only_key_the_reader_requires(sample_result, sample_cloud):
    manifest = build_manifest(result=sample_result, cloud=sample_cloud, frames_extracted=150)
    assert manifest["version"] == MANIFEST_VERSION == 1


def test_metres_per_unit_is_null_for_an_arbitrary_scale_reconstruction(
    sample_result, sample_cloud
):
    """SfM is defined only up to a similarity transform. A placeholder 1.0
    would make the app show a climber measurements that are simply wrong."""
    manifest = build_manifest(result=sample_result, cloud=sample_cloud, frames_extracted=150)
    assert manifest["metresPerUnit"] is None
    assert manifest["scaleSource"] is None


def test_scale_source_is_dropped_when_there_is_no_scale(sample_cloud):
    result = ReconstructionResult(metres_per_unit=None, scale_source="baseline")
    manifest = build_manifest(result=result, cloud=sample_cloud, frames_extracted=10)
    assert manifest["scaleSource"] is None


@pytest.mark.parametrize("bad", [0.0, -1.0, float("nan"), float("inf")])
def test_a_nonsense_scale_is_reported_as_no_scale(sample_cloud, bad):
    result = ReconstructionResult(metres_per_unit=bad, scale_source="gps")
    manifest = build_manifest(result=result, cloud=sample_cloud, frames_extracted=10)
    assert manifest["metresPerUnit"] is None
    assert manifest["scaleSource"] is None


def test_a_real_measured_scale_survives(sample_cloud):
    result = ReconstructionResult(metres_per_unit=0.37, scale_source="baseline")
    manifest = build_manifest(result=result, cloud=sample_cloud, frames_extracted=10)
    assert manifest["metresPerUnit"] == pytest.approx(0.37)
    assert manifest["scaleSource"] == "baseline"


def test_bounds_are_the_cloud_bounding_box(sample_result, sample_cloud):
    manifest = build_manifest(result=sample_result, cloud=sample_cloud, frames_extracted=150)
    assert manifest["boundsMin"] == [-1.0, 0.0, 0.0]
    assert manifest["boundsMax"] == [1.0, 2.0, 3.0]
    assert manifest["pointCount"] == 3


def test_an_empty_cloud_reports_null_bounds_rather_than_zeros(sample_result):
    manifest = build_manifest(
        result=sample_result, cloud=make_cloud(np.zeros((0, 3))), frames_extracted=150
    )
    assert manifest["boundsMin"] is None
    assert manifest["boundsMax"] is None
    assert manifest["pointCount"] == 0


def test_registered_ratio_matches_the_counts(sample_result, sample_cloud):
    manifest = build_manifest(result=sample_result, cloud=sample_cloud, frames_extracted=150)
    assert manifest["framesExtracted"] == 150
    assert manifest["framesRegistered"] == 120
    assert manifest["registeredRatio"] == pytest.approx(0.8)


def test_cameras_are_xyz_triples_and_capped_across_the_whole_path(sample_cloud):
    cameras = tuple((float(i), 0.0, 0.0) for i in range(1000))
    result = ReconstructionResult(cameras=cameras, frames_registered=1000)
    manifest = build_manifest(
        result=result, cloud=sample_cloud, frames_extracted=1000, max_cameras=300
    )
    listed = manifest["cameras"]
    assert len(listed) == 300
    assert all(len(c) == 3 for c in listed)
    # Spread across the trail, not the first 300 frames of it.
    assert listed[0][0] == 0.0
    assert listed[-1][0] == 999.0


def test_the_document_is_json_the_dart_reader_can_parse(sample_result, sample_cloud):
    manifest = build_manifest(result=sample_result, cloud=sample_cloud, frames_extracted=150)
    document = manifest_json(manifest)
    assert json.loads(document) == manifest
    assert "\n" not in document


def test_non_finite_numbers_never_reach_the_document(sample_cloud):
    result = ReconstructionResult(
        cameras=((float("nan"), 0.0, 0.0), (1.0, 1.0, 1.0)),
        mean_reprojection_error=float("inf"),
        frames_registered=2,
    )
    manifest = build_manifest(result=result, cloud=sample_cloud, frames_extracted=2)
    assert manifest["meanReprojectionError"] is None
    assert manifest["cameras"] == [[1.0, 1.0, 1.0]]
    json.loads(manifest_json(manifest))  # allow_nan=False would raise
