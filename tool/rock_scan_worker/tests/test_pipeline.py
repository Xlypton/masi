"""One job, end to end, with a fake reconstructor and a fake Supabase.

The reconstruction step is behind a seam precisely so this is possible with
no COLMAP installed: what these tests exercise is everything AROUND it —
which column gets written when, what a climber is told, and the difference
between failing a scan and putting it back on the queue."""

from __future__ import annotations

from pathlib import Path

import numpy as np
import pytest

from fake_supabase import FakeSupabase, make_row
from rock_scan_worker import pipeline as pipeline_module
from rock_scan_worker.errors import ScanFailure, ToolMissing, TransientError
from rock_scan_worker.frames import FrameSelection
from rock_scan_worker.pipeline import (
    OUTCOME_FAILED,
    OUTCOME_READY,
    OUTCOME_RELEASED,
    run_job,
)
from rock_scan_worker.ply import make_cloud
from rock_scan_worker.queue import CLIENT_OWNED_COLUMNS, WRITABLE_COLUMNS, ScanQueue
from rock_scan_worker.reconstruct.base import ReconstructionRequest, ReconstructionResult
from rock_scan_worker.supabase_client import SupabaseHttpError

NOW = 5_000_000


class FakeReconstructor:
    """The seam's test double: frames dir in, points and cameras out."""

    name = "fake"

    def __init__(self, *, result: ReconstructionResult | None = None, raises: Exception | None = None):
        self.result = result
        self.raises = raises
        self.requests: list[ReconstructionRequest] = []

    def preflight(self) -> None:
        if isinstance(self.raises, ToolMissing):
            raise self.raises

    def reconstruct(self, request: ReconstructionRequest) -> ReconstructionResult:
        self.requests.append(request)
        request.progress(0.5, "halfway")
        if self.raises is not None:
            raise self.raises
        assert self.result is not None
        return self.result


def good_result(points: int = 5_000, registered: int = 100) -> ReconstructionResult:
    rng = np.random.default_rng(3)
    return ReconstructionResult(
        cloud=make_cloud(rng.normal(size=(points, 3)) * 4.0, rng.integers(0, 256, size=(points, 3))),
        cameras=tuple((float(i), 0.0, 0.0) for i in range(registered)),
        frames_registered=registered,
        mean_reprojection_error=0.7,
        engine="fake",
        engine_version="0.1",
    )


@pytest.fixture
def seeded(monkeypatch, config, tmp_path):
    """A claimed job, with frame extraction stubbed out (no ffmpeg here)."""

    def fake_prepare(video: Path, work_dir: Path, cfg, log=None) -> FrameSelection:
        frames_dir = work_dir / "frames"
        frames_dir.mkdir(parents=True, exist_ok=True)
        paths = []
        for index in range(120):
            frame = frames_dir / f"frame_{index:05d}.jpg"
            frame.write_bytes(b"jpeg")
            paths.append(frame)
        return FrameSelection(frames_dir=frames_dir, frames=tuple(paths), candidates_extracted=360)

    monkeypatch.setattr(pipeline_module, "prepare_frames", fake_prepare)
    client = FakeSupabase([make_row("scan-1", owner_id="uid-1")])
    queue = ScanQueue(client, config, clock=lambda: NOW)
    job = queue.claim_next()
    assert job is not None
    return client, queue, job


# -- the happy path ---------------------------------------------------------


def test_a_good_scan_becomes_ready_with_artifacts_and_a_manifest(seeded, config):
    client, queue, job = seeded
    outcome = run_job(
        job, config=config, client=client, queue=queue, reconstructor=FakeReconstructor(result=good_result())
    )
    assert outcome.outcome == OUTCOME_READY

    row = client.rows["scan-1"]
    assert row["status"] == "ready"
    assert row["progressPct"] == 100
    assert row["cloudObjectPath"] == "uid-1/scan-1/cloud.ply"
    assert row["failureReason"] is None
    assert '"version":1' in row["manifestJson"]

    assert set(client.uploads) == {"uid-1/scan-1/cloud.ply", "uid-1/scan-1/manifest.json"}
    assert client.uploads["uid-1/scan-1/cloud.ply"].startswith(b"ply\nformat binary_little_endian")


def test_the_pipeline_never_writes_a_client_owned_column(seeded, config):
    client, queue, job = seeded
    run_job(job, config=config, client=client, queue=queue, reconstructor=FakeReconstructor(result=good_result()))
    written = client.written_columns()
    assert written <= WRITABLE_COLUMNS
    assert not (written & CLIENT_OWNED_COLUMNS)


def test_progress_climbs_while_the_job_runs(seeded, config):
    client, queue, job = seeded
    run_job(job, config=config, client=client, queue=queue, reconstructor=FakeReconstructor(result=good_result()))
    reported = [c.values["progressPct"] for c in client.patches if "progressPct" in c.values]
    assert reported == sorted(reported)
    assert reported[-1] == 100


def test_the_point_cloud_is_capped_so_a_phone_can_open_it(seeded, config):
    client, queue, job = seeded
    small = config.with_overrides(max_points=1_000)
    outcome = run_job(
        job, config=small, client=client, queue=queue, reconstructor=FakeReconstructor(result=good_result(points=50_000))
    )
    assert outcome.point_count == 1_000
    assert outcome.manifest["pointCount"] == 1_000


def test_the_source_video_is_deleted_once_frames_are_out(seeded, config):
    client, queue, job = seeded
    kept = config.with_overrides(keep_work_dir=True)
    run_job(job, config=kept, client=client, queue=queue, reconstructor=FakeReconstructor(result=good_result()))
    assert not (Path(kept.work_dir) / job.id / "source.mp4").exists()


# -- failures the climber is told about -------------------------------------


def test_a_scan_failure_marks_the_row_failed_with_a_readable_sentence(seeded, config):
    client, queue, job = seeded
    reason = "Not enough overlap between frames — try moving more slowly across the face."
    outcome = run_job(
        job, config=config, client=client, queue=queue,
        reconstructor=FakeReconstructor(raises=ScanFailure(reason, detail="mapper exit 1")),
    )
    assert outcome.outcome == OUTCOME_FAILED
    row = client.rows["scan-1"]
    assert row["status"] == "failed"
    assert row["failureReason"] == reason
    assert "mapper" not in row["failureReason"]


def test_too_few_registered_frames_fails_with_the_overlap_advice(seeded, config):
    client, queue, job = seeded
    outcome = run_job(
        job, config=config, client=client, queue=queue,
        reconstructor=FakeReconstructor(result=good_result(registered=4)),
    )
    assert outcome.outcome == OUTCOME_FAILED
    assert "4 of 120" in client.rows["scan-1"]["failureReason"]


def test_a_reconstruction_with_almost_no_points_fails(seeded, config):
    client, queue, job = seeded
    outcome = run_job(
        job, config=config, client=client, queue=queue,
        reconstructor=FakeReconstructor(result=good_result(points=10)),
    )
    assert outcome.outcome == OUTCOME_FAILED
    assert "10 points" in client.rows["scan-1"]["failureReason"]


def test_a_missing_video_object_fails_the_scan_rather_than_retrying_forever(seeded, config):
    client, queue, job = seeded
    client.download_error = SupabaseHttpError(404, "Object not found", where="download")
    outcome = run_job(
        job, config=config, client=client, queue=queue, reconstructor=FakeReconstructor(result=good_result())
    )
    assert outcome.outcome == OUTCOME_FAILED
    assert "could not be found" in client.rows["scan-1"]["failureReason"]


def test_an_unexpected_bug_fails_the_scan_with_an_invitation_to_retry(seeded, config):
    """Deliberate: with no attempt counter in the schema, releasing an
    unknown crash would re-claim the same row forever and starve the queue."""
    client, queue, job = seeded
    outcome = run_job(
        job, config=config, client=client, queue=queue,
        reconstructor=FakeReconstructor(raises=ZeroDivisionError("boom")),
    )
    assert outcome.outcome == OUTCOME_FAILED
    reason = client.rows["scan-1"]["failureReason"]
    assert "try running it again" in reason
    assert "ZeroDivision" not in reason


# -- infrastructure trouble puts the scan back ------------------------------


def test_a_dropped_network_releases_the_scan_instead_of_burning_it(seeded, config):
    client, queue, job = seeded
    client.download_error = TransientError("network error: connection reset")
    outcome = run_job(
        job, config=config, client=client, queue=queue, reconstructor=FakeReconstructor(result=good_result())
    )
    assert outcome.outcome == OUTCOME_RELEASED
    row = client.rows["scan-1"]
    assert row["status"] == "pending", "an infrastructure blip must not fail a climber's scan"
    assert row["failureReason"] is None


def test_a_missing_colmap_releases_the_scan(seeded, config):
    client, queue, job = seeded
    outcome = run_job(
        job, config=config, client=client, queue=queue,
        reconstructor=FakeReconstructor(raises=ToolMissing("colmap is not on PATH")),
    )
    assert outcome.outcome == OUTCOME_RELEASED
    assert client.rows["scan-1"]["status"] == "pending"


def test_losing_the_row_mid_job_stops_us_writing_over_the_new_owner(seeded, config):
    client, queue, job = seeded

    class Stealing(FakeReconstructor):
        def reconstruct(self, request):
            client.rows["scan-1"]["status"] = "pending"  # reclaimed as stale
            return super().reconstruct(request)

    outcome = run_job(
        job, config=config, client=client, queue=queue, reconstructor=Stealing(result=good_result())
    )
    assert outcome.outcome == OUTCOME_RELEASED
    assert client.rows["scan-1"]["status"] == "pending"
    assert client.rows["scan-1"]["cloudObjectPath"] is None


def test_a_stop_request_releases_the_claimed_scan(seeded, config):
    client, queue, job = seeded
    outcome = run_job(
        job, config=config, client=client, queue=queue,
        reconstructor=FakeReconstructor(result=good_result()), should_stop=lambda: True,
    )
    assert outcome.outcome == OUTCOME_RELEASED
    assert client.rows["scan-1"]["status"] == "pending"


# -- dry run ----------------------------------------------------------------


def test_dry_run_touches_neither_the_row_nor_storage(seeded, config):
    client, queue, job = seeded
    dry = config.with_overrides(dry_run=True)
    dry_queue = ScanQueue(client, dry, clock=lambda: NOW)
    outcome = run_job(
        job, config=dry, client=client, queue=dry_queue, reconstructor=FakeReconstructor(result=good_result())
    )
    assert outcome.outcome == OUTCOME_READY
    assert client.uploads == {}
    row = client.rows["scan-1"]
    assert row["cloudObjectPath"] is None and row["manifestJson"] is None
    # ...and the artifacts are on disk for a human to look at.
    assert (Path(dry.work_dir) / job.id / "cloud.ply").is_file()
    assert (Path(dry.work_dir) / job.id / "manifest.json").is_file()
