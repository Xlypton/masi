"""The background heartbeat: the one thing standing between a slow-but-alive
reconstruction and another worker declaring it dead."""

from __future__ import annotations

import time

import pytest

from fake_supabase import FakeSupabase, make_row
from rock_scan_worker.pipeline import Heartbeat
from rock_scan_worker.queue import ScanQueue


@pytest.fixture
def claimed(config):
    client = FakeSupabase([make_row("s1")])
    queue = ScanQueue(client, config)
    job = queue.claim_next()
    assert job is not None
    return client, queue, job


def wait_for(predicate, timeout_s: float = 5.0) -> bool:
    deadline = time.monotonic() + timeout_s
    while time.monotonic() < deadline:
        if predicate():
            return True
        time.sleep(0.02)
    return False


def test_it_keeps_updated_at_moving_while_a_long_stage_runs(claimed, config):
    client, queue, job = claimed
    before = len(client.patches)
    with Heartbeat(queue, job, interval_s=0.02, log=lambda _m: None, min_interval_s=0.01) as beat:
        beat.pct = 55.0
        assert wait_for(lambda: len(client.patches) >= before + 2), "no beats"
    beats = [c for c in client.patches[before:] if "progressPct" in c.values]
    assert beats and all(c.values["progressPct"] == 55 for c in beats)
    assert all("updatedAt" in c.values for c in beats)


def test_it_stops_when_the_stage_finishes(claimed, config):
    client, queue, job = claimed
    with Heartbeat(queue, job, interval_s=0.02, log=lambda _m: None, min_interval_s=0.01):
        assert wait_for(lambda: len(client.patches) >= 2)
    settled = len(client.patches)
    time.sleep(0.3)
    assert len(client.patches) == settled, "the thread outlived its job"


def test_losing_the_row_is_recorded_rather_than_raised(claimed, config):
    """A daemon thread cannot raise into the reconstruction, so it records
    the loss and the next checkpoint on the main thread acts on it."""
    client, queue, job = claimed
    with Heartbeat(queue, job, interval_s=0.02, log=lambda _m: None, min_interval_s=0.01) as beat:
        client.rows["s1"]["status"] = "pending"  # reclaimed by someone else
        assert wait_for(lambda: beat.lost)
    assert beat.lost


def test_a_failing_heartbeat_never_takes_the_job_down(claimed, config):
    client, queue, job = claimed
    messages: list[str] = []

    def explode(*_args, **_kwargs):
        raise ConnectionResetError("the router rebooted")

    client.patch = explode
    with Heartbeat(queue, job, interval_s=0.02, log=messages.append, min_interval_s=0.01) as beat:
        assert wait_for(lambda: any("heartbeat failed" in m for m in messages))
    assert not beat.lost, "a missed beat is survivable; it is not a lost claim"


def test_the_interval_has_a_floor_so_it_cannot_hammer_the_database(claimed, config):
    _client, queue, job = claimed
    assert Heartbeat(queue, job, interval_s=0.0, log=lambda _m: None)._interval_s >= 5.0
    assert Heartbeat.MIN_INTERVAL_S >= 5.0
