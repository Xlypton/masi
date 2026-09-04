"""The claim protocol. If any test in this file goes red, two workers can end
up reconstructing the same climber's video, or a crashed worker can wedge a
scan in `processing` forever."""

from __future__ import annotations

import pytest

from fake_supabase import FakeSupabase, make_row
from rock_scan_worker.errors import WorkerError
from rock_scan_worker.queue import (
    CLIENT_OWNED_COLUMNS,
    WORKER_OWNED_COLUMNS,
    WRITABLE_COLUMNS,
    ScanQueue,
    clamp_reason,
    job_from_row,
)

NOW = 10_000_000


def make_queue(client: FakeSupabase, config, now: int = NOW) -> ScanQueue:
    return ScanQueue(client, config, clock=lambda: now)


# -- what is claimable ------------------------------------------------------


def test_claims_the_oldest_uploaded_pending_row(config):
    client = FakeSupabase(
        [
            make_row("newer", created_at=2_000),
            make_row("older", created_at=1_000),
        ]
    )
    job = make_queue(client, config).claim_next()
    assert job is not None and job.id == "older"
    assert client.rows["older"]["status"] == "processing"
    assert client.rows["newer"]["status"] == "pending"


@pytest.mark.parametrize(
    "row",
    [
        make_row("not-uploaded", upload_state="pending"),
        make_row("still-uploading", upload_state="uploading"),
        make_row("deleted", deleted_at=123),
        make_row("already-done", status="ready"),
        make_row("already-failed", status="failed"),
    ],
    ids=lambda r: r["id"],
)
def test_ignores_rows_that_are_not_claimable(config, row):
    client = FakeSupabase([row])
    assert make_queue(client, config).claim_next() is None


def test_claim_marks_processing_and_clears_a_previous_failure(config):
    client = FakeSupabase([make_row("s1", failureReason="an older attempt failed")])
    job = make_queue(client, config).claim_next()
    assert job is not None
    row = client.rows["s1"]
    assert row["status"] == "processing"
    assert row["progressPct"] == 0
    assert row["failureReason"] is None
    assert row["updatedAt"] == NOW


# -- atomicity --------------------------------------------------------------


def test_a_second_worker_loses_the_race_and_gets_nothing(config):
    """The row is stolen between our SELECT and our PATCH. The conditional
    update must match zero rows, and we must not process it."""
    client = FakeSupabase([make_row("contended")])

    def steal(filters, _values):
        if filters.get("status") == "eq.pending":
            # Exactly what a real competing worker's claim does, including
            # the updatedAt bump that protects it from the stale sweeper.
            client.rows["contended"].update({"status": "processing", "updatedAt": NOW})
            client.on_patch = None  # only steal it once

    client.on_patch = steal
    assert make_queue(client, config).claim_next() is None


def test_claim_moves_on_to_the_next_row_when_it_loses_a_race(config):
    client = FakeSupabase([make_row("stolen", created_at=1), make_row("free", created_at=2)])

    def steal(filters, _values):
        if filters.get("id") == "eq.stolen":
            client.rows["stolen"].update({"status": "processing", "updatedAt": NOW})
            client.on_patch = None

    client.on_patch = steal
    job = make_queue(client, config).claim_next()
    assert job is not None and job.id == "free"


def test_claim_filters_on_status_not_just_id(config):
    """The `status=eq.pending` half of the WHERE is the entire safety
    argument — a filter on `id` alone would be a select-then-update."""
    client = FakeSupabase([make_row("s1")])
    make_queue(client, config).claim_next()
    claim = client.patches[0]
    assert claim.filters["id"] == "eq.s1"
    assert claim.filters["status"] == "eq.pending"


# -- stale reclaim ----------------------------------------------------------


def test_reclaims_a_row_abandoned_by_a_dead_worker(config):
    stale_at = NOW - int(config.stale_claim_timeout_s * 1000) - 1
    client = FakeSupabase([make_row("abandoned", status="processing", updated_at=stale_at)])
    job = make_queue(client, config).claim_next()
    assert job is not None and job.id == "abandoned"
    assert client.rows["abandoned"]["updatedAt"] == NOW


def test_does_not_steal_a_row_a_live_worker_is_still_heartbeating(config):
    recent = NOW - 60_000
    client = FakeSupabase([make_row("in-flight", status="processing", updated_at=recent)])
    assert make_queue(client, config).claim_next() is None
    assert client.rows["in-flight"]["updatedAt"] == recent


def test_stale_reclaim_reasserts_the_cutoff_in_the_where_clause(config):
    """If the owner heartbeats between our SELECT and our PATCH, the row must
    stop matching — otherwise reclaim races are won by whoever is slower."""
    stale_at = NOW - int(config.stale_claim_timeout_s * 1000) - 1
    client = FakeSupabase([make_row("abandoned", status="processing", updated_at=stale_at)])

    def heartbeat(filters, _values):
        if "updatedAt" in filters:
            client.rows["abandoned"]["updatedAt"] = NOW - 1_000
            client.on_patch = None

    client.on_patch = heartbeat
    assert make_queue(client, config).claim_next() is None


def test_fresh_work_is_preferred_over_stale_recovery(config):
    stale_at = NOW - int(config.stale_claim_timeout_s * 1000) - 1
    client = FakeSupabase(
        [
            make_row("stale", status="processing", created_at=1, updated_at=stale_at),
            make_row("fresh", created_at=9_999),
        ]
    )
    job = make_queue(client, config).claim_next()
    assert job is not None and job.id == "fresh"


# -- ownership of columns ---------------------------------------------------


def test_worker_owned_columns_match_the_dart_sync_contract(dart_server_owned_columns):
    assert WORKER_OWNED_COLUMNS == dart_server_owned_columns


def test_writable_is_the_worker_set_plus_updated_at():
    assert WRITABLE_COLUMNS == WORKER_OWNED_COLUMNS | {"updatedAt"}
    assert not (WRITABLE_COLUMNS & CLIENT_OWNED_COLUMNS)


def test_every_write_path_touches_only_worker_owned_columns(config):
    client = FakeSupabase([make_row("s1"), make_row("s2"), make_row("s3")])
    queue = make_queue(client, config)

    job = queue.claim_next()
    assert job is not None
    queue.heartbeat(job, 42, force=True)
    queue.mark_ready(job, cloud_object_path="owner-1/s1/cloud.ply", manifest_json="{}")

    second = queue.claim_next()
    assert second is not None
    queue.mark_failed(second, "Not enough overlap between frames.")

    third = queue.claim_next()
    assert third is not None
    queue.release(third)

    written = client.written_columns()
    assert written <= WRITABLE_COLUMNS, f"wrote columns it does not own: {written - WRITABLE_COLUMNS}"
    assert not (written & CLIENT_OWNED_COLUMNS)


def test_every_write_bumps_updated_at(config):
    client = FakeSupabase([make_row("s1")])
    queue = make_queue(client, config)
    job = queue.claim_next()
    assert job is not None
    queue.heartbeat(job, 50, force=True)
    queue.mark_ready(job, cloud_object_path="p", manifest_json="{}")
    for call in client.patches:
        assert call.values["updatedAt"] == NOW, (
            "a write without updatedAt is a change no client will ever pull"
        )


def test_a_write_body_with_a_client_column_raises_before_the_network(config):
    client = FakeSupabase([make_row("s1")])
    queue = make_queue(client, config)
    with pytest.raises(WorkerError) as caught:
        queue._patch(filters={"id": "eq.s1"}, values={"uploadState": "pending"})
    assert "uploadState" in str(caught.value)
    assert not client.patches, "the request must not be made at all"


# -- finishing --------------------------------------------------------------


def test_mark_ready_sets_the_result_columns(config):
    client = FakeSupabase([make_row("s1")])
    queue = make_queue(client, config)
    job = queue.claim_next()
    assert job is not None
    assert queue.mark_ready(job, cloud_object_path="owner-1/s1/cloud.ply", manifest_json='{"version":1}')
    row = client.rows["s1"]
    assert row["status"] == "ready"
    assert row["progressPct"] == 100
    assert row["cloudObjectPath"] == "owner-1/s1/cloud.ply"
    assert row["manifestJson"] == '{"version":1}'
    assert row["failureReason"] is None


def test_release_puts_the_row_back_on_the_queue(config):
    client = FakeSupabase([make_row("s1")])
    queue = make_queue(client, config)
    job = queue.claim_next()
    assert job is not None
    assert queue.release(job)
    assert client.rows["s1"]["status"] == "pending"
    assert client.rows["s1"]["progressPct"] is None
    assert client.rows["s1"]["failureReason"] is None


def test_finishing_a_row_we_no_longer_own_reports_failure(config):
    client = FakeSupabase([make_row("s1")])
    queue = make_queue(client, config)
    job = queue.claim_next()
    assert job is not None
    client.rows["s1"]["status"] = "pending"  # reclaimed by somebody else
    assert queue.mark_ready(job, cloud_object_path="p", manifest_json="{}") is False
    assert queue.heartbeat(job, 90, force=True) is False


def test_heartbeat_is_throttled_but_forceable(config):
    client = FakeSupabase([make_row("s1")])
    now = NOW
    queue = ScanQueue(client, config, clock=lambda: now)
    job = queue.claim_next()
    assert job is not None
    before = len(client.patches)
    queue.heartbeat(job, 0)  # same percentage, no time passed
    assert len(client.patches) == before
    queue.heartbeat(job, 0, force=True)
    assert len(client.patches) == before + 1


def test_failure_reason_is_clamped_to_something_a_phone_can_show():
    long_reason = "word " * 400
    clamped = clamp_reason(long_reason)
    assert len(clamped) <= 400
    assert clamped.endswith("…")
    assert clamp_reason("  spaced   out\n text ") == "spaced out text"


# -- job shape --------------------------------------------------------------


def test_artifact_paths_are_owner_scoped():
    job = job_from_row(make_row("scan-9", owner_id="uid-7"))
    assert job.artifact_prefix == "uid-7/scan-9"
    assert job.cloud_object_path == "uid-7/scan-9/cloud.ply"
    assert job.manifest_object_path == "uid-7/scan-9/manifest.json"


def test_artifact_prefix_falls_back_to_the_video_folder_when_owner_is_null():
    row = make_row("scan-9", owner_id=None, video_object_path="uid-3/scan-9/source.mp4")
    assert job_from_row(row).artifact_prefix == "uid-3/scan-9"


def test_claim_specific_refuses_a_row_whose_video_is_not_uploaded(config):
    client = FakeSupabase([make_row("s1", upload_state="pending")])
    with pytest.raises(WorkerError):
        make_queue(client, config).claim_specific("s1")
