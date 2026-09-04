"""The polling loop: it polls, it never listens, and a flapping home
connection must not turn into a request every twenty seconds all night."""

from __future__ import annotations


from fake_supabase import FakeSupabase, make_row
from rock_scan_worker.errors import ToolMissing, TransientError
from rock_scan_worker.pipeline import OUTCOME_READY, JobOutcome
from rock_scan_worker.queue import ScanQueue
from rock_scan_worker.worker import MAX_BACKOFF_S, Worker


class StubQueue:
    """A queue whose `claim_next` does whatever the test needs."""

    def __init__(self, results):
        self.results = list(results)
        self.calls = 0

    def claim_next(self):
        self.calls += 1
        outcome = self.results[min(self.calls - 1, len(self.results) - 1)]
        if isinstance(outcome, Exception):
            raise outcome
        return outcome


def make_worker(queue, *, config, run_job=None):
    slept: list[float] = []
    worker = Worker(
        config=config,
        client=None,
        queue=queue,
        reconstructor=None,
        log=lambda _m: None,
        sleep=slept.append,
    )
    return worker, slept


def test_an_empty_queue_returns_nothing_and_sleeps(config):
    queue = StubQueue([None])
    worker, slept = make_worker(queue, config=config.with_overrides(poll_interval_s=20.0))
    worker.run_forever(max_jobs=0)
    assert worker.run_once() is None


def test_a_network_failure_backs_off_exponentially(config):
    queue = StubQueue([TransientError("connection reset")])
    worker, slept = make_worker(queue, config=config.with_overrides(poll_interval_s=10.0))

    def stop_after_a_few(seconds):
        slept.append(seconds)
        if len(slept) > 200:
            worker.request_stop()

    worker.sleep = stop_after_a_few
    stats = worker.run_forever()
    assert stats.transient_errors > 0
    # `_nap` sleeps in one-second slices; what matters is that the total
    # wait grows and is capped.
    assert sum(slept) <= MAX_BACKOFF_S * (stats.transient_errors + 1)
    assert stats.claimed == 0, "nothing was claimed, so nothing needed releasing"


def test_a_missing_binary_keeps_polling_rather_than_exiting(config):
    """A service that starts before its PATH is ready should heal itself —
    but say so every time, so the log is not silent about it."""
    queue = StubQueue([ToolMissing("colmap is not on PATH")])
    messages: list[str] = []
    worker = Worker(
        config=config.with_overrides(poll_interval_s=1.0),
        client=None,
        queue=queue,
        reconstructor=None,
        log=messages.append,
        sleep=lambda _s: worker.request_stop(),
    )
    worker.run_forever()
    assert any("colmap" in m for m in messages)
    assert worker.stats.transient_errors == 1


def test_stopping_is_honoured_between_jobs(config):
    queue = StubQueue([None])
    worker = Worker(
        config=config.with_overrides(poll_interval_s=5.0),
        client=None,
        queue=queue,
        reconstructor=None,
        log=lambda _m: None,
        sleep=lambda _s: None,
    )
    worker.request_stop()
    assert worker.run_forever().idle_polls == 0


def test_max_jobs_stops_a_cron_style_run(config, monkeypatch):
    import rock_scan_worker.worker as worker_module

    client = FakeSupabase([make_row(f"s{i}", created_at=i) for i in range(5)])
    queue = ScanQueue(client, config)
    jobs = []

    def fake_run_job(job, **kwargs):
        jobs.append(job.id)
        return JobOutcome(job=job, outcome=OUTCOME_READY)

    monkeypatch.setattr(worker_module, "run_job", fake_run_job)
    worker = Worker(
        config=config,
        client=client,
        queue=queue,
        reconstructor=None,
        log=lambda _m: None,
        sleep=lambda _s: None,
    )
    stats = worker.run_forever(max_jobs=2)
    assert stats.claimed == 2 and stats.ready == 2
    assert jobs == ["s0", "s1"]


def test_stats_separate_failed_from_released(config, monkeypatch):
    import rock_scan_worker.worker as worker_module

    client = FakeSupabase([make_row("s0"), make_row("s1", created_at=2), make_row("s2", created_at=3)])
    queue = ScanQueue(client, config)
    outcomes = iter(["ready", "failed", "released"])

    monkeypatch.setattr(
        worker_module,
        "run_job",
        lambda job, **kwargs: JobOutcome(job=job, outcome=next(outcomes)),
    )
    worker = Worker(
        config=config, client=client, queue=queue, reconstructor=None,
        log=lambda _m: None, sleep=lambda _s: None,
    )
    stats = worker.run_forever(max_jobs=3)
    assert (stats.ready, stats.failed, stats.released) == (1, 1, 1)
