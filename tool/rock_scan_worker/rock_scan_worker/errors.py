"""The two kinds of bad news, and why the distinction is the whole design.

A `ScanFailure` is the JOB's fault: this particular video cannot be turned
into a point cloud, and no amount of retrying changes that. It carries a
`reason` that is shown VERBATIM to a climber, so it is written as a sentence
a person can act on, never as a stack trace or an exit code.

A `TransientError` is the WORKER's fault, or the network's: the job is fine,
we just could not do it right now. The row goes back to `pending` and someone
picks it up later. Burning a scan because the worker's home broadband dropped
would be the worst bug this thing could have.
"""

from __future__ import annotations


class WorkerError(Exception):
    """Base for everything this package raises deliberately."""


class ScanFailure(WorkerError):
    """Terminal for this job. `reason` is climber-facing prose."""

    def __init__(self, reason: str, *, detail: str | None = None) -> None:
        super().__init__(detail or reason)
        self.reason = reason
        self.detail = detail


class TransientError(WorkerError):
    """Infrastructure, not the video. Retry the same row later."""


class ToolMissing(TransientError):
    """A required external binary (ffmpeg, COLMAP) is not on PATH.

    Deliberately transient: a worker box missing COLMAP is a deployment
    problem, and marking every scan `failed` would destroy a queue of
    perfectly good videos while someone fixes their PATH. `cli doctor` and
    the startup preflight are what stop the loop spinning on it forever.
    """


class OwnershipLost(WorkerError):
    """Another worker took the row while we were working on it."""
