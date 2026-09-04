"""The real thing: a video in, a point cloud out, no fakes in the middle.

These are skipped when `ffmpeg`/`colmap` are not on PATH, which is the normal
state of a laptop and of CI. When they ARE present this is the only test that
proves the parts fit: ffmpeg really extracts frames the selector likes,
COLMAP really registers them, the binary model parser really reads what
COLMAP really wrote, and the PLY the phone would download really parses.

The scene is synthetic but not a test pattern — `synthetic_scene.py` renders
three textured planes in a corner from a camera on a moving arc, because
ffmpeg's own `testsrc2` has no parallax and reconstructs to nothing. See that
module for the reasoning.
"""

from __future__ import annotations

import shutil
from pathlib import Path

import pytest

import synthetic_scene
from fake_supabase import FakeSupabase, make_row
from rock_scan_worker.config import Config
from rock_scan_worker.errors import ScanFailure
from rock_scan_worker.frames import prepare_frames
from rock_scan_worker.pipeline import OUTCOME_READY, run_job
from rock_scan_worker.ply import read_ply
from rock_scan_worker.queue import ScanQueue
from rock_scan_worker.reconstruct.colmap import ColmapReconstructor

HAVE_FFMPEG = shutil.which("ffmpeg") is not None and shutil.which("ffprobe") is not None
HAVE_COLMAP = shutil.which("colmap") is not None

needs_ffmpeg = pytest.mark.skipif(not HAVE_FFMPEG, reason="ffmpeg/ffprobe not on PATH")
needs_colmap = pytest.mark.skipif(not HAVE_COLMAP, reason="colmap not on PATH")


@pytest.fixture(scope="module")
def rendered_video(tmp_path_factory) -> Path:
    if not HAVE_FFMPEG:
        pytest.skip("ffmpeg not on PATH")
    destination = tmp_path_factory.mktemp("scene") / "scan.mp4"
    return synthetic_scene.render_video(
        destination, count=28, fps=5, width=640, height=480, focal=560.0
    )


def integration_config(tmp_path: Path) -> Config:
    return Config(
        supabase_url="https://example.supabase.co",
        service_role_key="not-a-real-key",
        work_dir=tmp_path / "work",
        frame_budget=24,
        min_frames=8,
        min_registered_frames=8,
        min_points=200,
        frame_max_edge=640,
        # `auto` on purpose: this exercises the real GPU probe. On a CUDA box
        # it reconstructs on the GPU; on a headless CPU-only COLMAP it fails
        # the probe and falls back, which is the path most likely to rot.
        gpu="auto",
        keep_work_dir=True,
    )


# -- ffmpeg only ------------------------------------------------------------


@needs_ffmpeg
@pytest.mark.integration
def test_real_ffmpeg_extraction_yields_frames_the_selector_keeps(rendered_video, tmp_path):
    config = integration_config(tmp_path)
    selection = prepare_frames(rendered_video, tmp_path / "work", config)
    assert selection.count >= config.min_frames
    assert selection.count <= config.frame_budget
    assert all(path.is_file() and path.stat().st_size > 0 for path in selection.frames)
    # The dedupe must not eat a genuine moving pan (it once did: an absolute
    # threshold collapsed 36 real frames to 2).
    assert selection.count >= selection.candidates_extracted * 0.5


@needs_ffmpeg
@pytest.mark.integration
def test_a_real_too_short_video_gets_the_climber_facing_sentence(tmp_path):
    short = synthetic_scene.render_video(
        tmp_path / "short.mp4", count=6, fps=6, width=320, height=240, focal=280.0
    )
    config = integration_config(tmp_path)
    with pytest.raises(ScanFailure) as caught:
        prepare_frames(short, tmp_path / "work-short", config)
    assert "seconds long" in caught.value.reason
    assert "ffmpeg" not in caught.value.reason.lower()


# -- the whole pipeline -----------------------------------------------------


@needs_ffmpeg
@needs_colmap
@pytest.mark.integration
@pytest.mark.slow
def test_a_real_video_reconstructs_end_to_end(rendered_video, tmp_path):
    config = integration_config(tmp_path)
    client = FakeSupabase([make_row("scan-real", owner_id="uid-real")])
    client.objects["uid-real/scan-real/source.mp4"] = rendered_video.read_bytes()
    queue = ScanQueue(client, config)
    job = queue.claim_next()
    assert job is not None

    logs: list[str] = []
    outcome = run_job(
        job,
        config=config,
        client=client,
        queue=queue,
        reconstructor=ColmapReconstructor(config, log=logs.append),
        log=logs.append,
    )

    assert outcome.outcome == OUTCOME_READY, f"reconstruction failed: {outcome.reason}\n" + "\n".join(logs[-15:])

    # The row a phone will pull.
    row = client.rows["scan-real"]
    assert row["status"] == "ready"
    assert row["progressPct"] == 100
    assert row["cloudObjectPath"] == "uid-real/scan-real/cloud.ply"
    assert row["failureReason"] is None

    # The artifacts a phone will download.
    assert set(client.uploads) == {
        "uid-real/scan-real/cloud.ply",
        "uid-real/scan-real/manifest.json",
    }
    cloud_path = tmp_path / "downloaded.ply"
    cloud_path.write_bytes(client.uploads["uid-real/scan-real/cloud.ply"])
    cloud = read_ply(cloud_path)
    assert cloud.count >= 200
    assert cloud.count == outcome.manifest["pointCount"]

    manifest = outcome.manifest
    assert manifest["version"] == 1
    assert manifest["engine"] == "colmap"
    assert manifest["engineVersion"] and manifest["engineVersion"][0].isdigit()
    assert manifest["framesRegistered"] >= 8
    assert manifest["registeredRatio"] >= 0.5
    assert 0 < manifest["meanReprojectionError"] < 5.0
    assert len(manifest["cameras"]) == manifest["framesRegistered"]
    assert manifest["boundsMin"] and manifest["boundsMax"]
    assert manifest["boundsMax"][0] > manifest["boundsMin"][0]
    # Nothing in this pipeline measures anything real, so it must say so.
    assert manifest["metresPerUnit"] is None
    assert manifest["scaleSource"] is None

    # Whichever way the GPU probe went, it is on the record — and on a
    # no-CUDA build the fallback itself must be in there too.
    assert any("gpu mode" in line for line in logs), (
        "the GPU/CPU decision must be visible in the log"
    )
    if not any("attempting GPU" in line for line in logs):
        assert any("running on CPU" in line for line in logs)
