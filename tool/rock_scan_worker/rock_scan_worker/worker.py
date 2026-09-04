"""The polling loop.

It POLLS. It never listens on a port, and that is not an implementation
detail — the primary host is a gaming PC on a home connection behind NAT, so
an inbound design would need a public IP, a port forward and a firewall hole
on a machine that also plays games. Every connection here is outbound to
Supabase over HTTPS, which needs nothing configured anywhere.

The loop is therefore boring on purpose: claim, work, repeat; sleep
`poll_interval_s` when the queue is empty; back off exponentially when the
NETWORK is the thing failing, so a dropped home connection does not turn into
a request every twenty seconds for six hours.
"""

from __future__ import annotations

import time
from dataclasses import dataclass, field
from typing import Any, Callable

from .config import Config, redact
from .errors import ToolMissing, TransientError, WorkerError
from .pipeline import (
    JobOutcome,
    OUTCOME_FAILED,
    OUTCOME_READY,
    OUTCOME_RELEASED,
    run_job,
)
from .queue import ScanQueue
from .reconstruct.base import Reconstructor

#: Ceiling on the network backoff. Long enough to be gentle on a flapping
#: connection, short enough that a worker recovers unattended overnight.
MAX_BACKOFF_S = 10 * 60


@dataclass
class WorkerStats:
    claimed: int = 0
    ready: int = 0
    failed: int = 0
    released: int = 0
    idle_polls: int = 0
    transient_errors: int = 0

    def record(self, outcome: JobOutcome) -> None:
        self.claimed += 1
        if outcome.outcome == OUTCOME_READY:
            self.ready += 1
        elif outcome.outcome == OUTCOME_FAILED:
            self.failed += 1
        else:
            self.released += 1


@dataclass
class Worker:
    config: Config
    client: Any
    queue: ScanQueue
    reconstructor: Reconstructor
    log: Callable[[str], None] = lambda message: None
    sleep: Callable[[float], None] = time.sleep
    stats: WorkerStats = field(default_factory=WorkerStats)
    _stopping: bool = False
    #: How many times each scan has been released back to the queue by THIS
    #: process. The bound this feeds (`config.max_release_attempts`) is what
    #: stops a deterministic fault from being retried forever — see the
    #: config field's note for the run that made it necessary.
    _releases: dict[str, int] = field(default_factory=dict)

    def request_stop(self) -> None:
        """Ask the loop, and the job in flight, to wind up cleanly."""
        self._stopping = True

    @property
    def stopping(self) -> bool:
        return self._stopping

    def run_once(self, scan_id: str | None = None) -> JobOutcome | None:
        """Claim and process at most one scan. None when the queue is empty."""
        job = (
            self.queue.claim_specific(scan_id)
            if scan_id
            else self.queue.claim_next()
        )
        if job is None:
            return None
        attempt = self._releases.get(job.id, 0) + 1
        self.log(
            f"scan {job.id}: claimed (wall {job.wall_id}, "
            f"{(job.size_bytes or 0) / 1e6:.1f} MB video)"
            + (f", attempt {attempt}" if attempt > 1 else "")
        )
        outcome = run_job(
            job,
            config=self.config,
            client=self.client,
            queue=self.queue,
            reconstructor=self.reconstructor,
            log=self.log,
            should_stop=lambda: self._stopping,
            attempt=attempt,
            final_attempt=attempt >= self.config.max_release_attempts,
        )
        # A release is only worth counting when we mean to try again. A stop
        # request also releases, and holding that against the scan would make
        # a couple of Ctrl-Cs enough to have the next run give up on a job
        # that was never actually tried.
        if outcome.outcome == OUTCOME_RELEASED and not self._stopping:
            self._releases[job.id] = attempt
        else:
            self._releases.pop(job.id, None)
        self.stats.record(outcome)
        self.log(f"scan {job.id}: {outcome.outcome}")
        return outcome

    def run_forever(self, max_jobs: int | None = None) -> WorkerStats:
        backoff = 0.0
        while not self._stopping:
            if max_jobs is not None and self.stats.claimed >= max_jobs:
                break
            try:
                outcome = self.run_once()
            except TransientError as transient:
                # The CLAIM itself failed — network, or Supabase having a
                # moment. Nothing was claimed, so nothing needs releasing.
                self.stats.transient_errors += 1
                backoff = min(max(backoff * 2, self.config.poll_interval_s), MAX_BACKOFF_S)
                self.log(
                    f"queue unreachable ({redact(transient)}); retrying in {backoff:.0f}s"
                )
                self._nap(backoff)
                continue
            except ToolMissing as missing:
                # Nothing to claim work with. Keep polling rather than
                # exiting so a service that starts before its PATH is ready
                # heals itself, but say so every time.
                self.stats.transient_errors += 1
                backoff = min(max(backoff * 2, self.config.poll_interval_s), MAX_BACKOFF_S)
                self.log(f"cannot process scans: {redact(missing)}; retrying in {backoff:.0f}s")
                self._nap(backoff)
                continue
            except WorkerError as broken:
                self.log(f"queue error: {redact(broken)}")
                self._nap(self.config.poll_interval_s)
                continue

            backoff = 0.0
            if outcome is None:
                self.stats.idle_polls += 1
                self._nap(self.config.poll_interval_s)
            elif outcome.outcome == OUTCOME_RELEASED:
                # Wait before trying again. The loop used to fall straight
                # through here, so a released job was re-claimed by the same
                # worker within milliseconds and the retry never got the
                # chance to be transient — which is how a failing scan turned
                # into a 13-second cycle that re-downloaded the video and
                # re-ran the engine indefinitely.
                self._nap(self.config.poll_interval_s)
        return self.stats

    def _nap(self, seconds: float) -> None:
        """Sleep in slices so a stop request is honoured promptly."""
        remaining = max(0.0, seconds)
        while remaining > 0 and not self._stopping:
            slice_s = min(1.0, remaining)
            self.sleep(slice_s)
            remaining -= slice_s
