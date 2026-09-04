"""One scan, start to finish: download, frames, reconstruct, publish.

Ordering here is chosen so that the expensive, unrecoverable work happens
last and the cheap disqualifications happen first — a three-second video is
rejected before a GPU ever spins up. Progress is reported continuously
because the phone shows it, and because `progressPct` doubles as the
heartbeat that stops another worker reclaiming a healthy job.

The exception policy is the load-bearing part:

* `ScanFailure`   -> this video cannot be reconstructed. Mark `failed` with a
                     sentence the climber can act on.
* `TransientError`-> our problem (network, missing binary, a killed
                     subprocess). Put the row back on the queue untouched;
                     somebody finishes it later.
* anything else   -> a bug in this worker. Marked `failed` with an invitation
                     to retry, deliberately: without a retry counter in the
                     schema, releasing an unknown crash would re-claim the
                     same row forever and starve every scan behind it.
"""

from __future__ import annotations

import shutil
import threading
import traceback
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable

from . import reasons
from .config import Config, redact
from .errors import ScanFailure, TransientError, WorkerError
from .frames import prepare_frames
from .manifest import manifest_for_config, manifest_json
from .ply import subsample, write_ply
from .queue import ScanJob, ScanQueue
from .reconstruct.base import ReconstructionRequest, ReconstructionResult, Reconstructor
from .supabase_client import SupabaseHttpError

#: Progress checkpoints, as percentages of the whole job.
P_DOWNLOAD = 5.0
P_FRAMES = 15.0
P_RECONSTRUCT_START = 30.0
P_RECONSTRUCT_END = 85.0
P_EXPORT = 88.0
P_UPLOAD = 92.0

OUTCOME_READY = "ready"
OUTCOME_FAILED = "failed"
OUTCOME_RELEASED = "released"


class Heartbeat:
    """Keeps `updatedAt` moving while we are blocked inside COLMAP.

    Without this, a reconstruction reports progress only at stage boundaries
    — and a single feature-extraction or dense-MVS stage can run longer than
    the stale-claim timeout, at which point a perfectly healthy job is
    declared dead and handed to a second worker. That is the one race the
    claim protocol cannot fix from the outside, because from the outside a
    slow worker and a dead one look identical. So the worker says so itself,
    on a timer, from a daemon thread.

    It never raises into the reconstruction: if the row stops being ours, it
    records that and the next checkpoint on the main thread acts on it.
    """

    #: Floor on the interval, so a misconfigured `--heartbeat-interval` of 0
    #: cannot turn into a PATCH storm against the database.
    MIN_INTERVAL_S = 5.0

    def __init__(self, queue: ScanQueue, job: ScanJob, *, interval_s: float,
                 log: Callable[[str], None],
                 min_interval_s: float | None = None) -> None:
        self._queue = queue
        self._job = job
        self._interval_s = max(
            self.MIN_INTERVAL_S if min_interval_s is None else min_interval_s,
            interval_s,
        )
        self._log = log
        self._done = threading.Event()
        self._thread: threading.Thread | None = None
        self.pct = 0.0
        self.lost = False

    def __enter__(self) -> "Heartbeat":
        self._thread = threading.Thread(
            target=self._loop, name="rock-scan-heartbeat", daemon=True
        )
        self._thread.start()
        return self

    def __exit__(self, *_exc: object) -> None:
        self._done.set()
        if self._thread is not None:
            self._thread.join(timeout=10.0)

    def _loop(self) -> None:
        while not self._done.wait(self._interval_s):
            try:
                if not self._queue.heartbeat(self._job, self.pct, force=True):
                    self.lost = True
                    self._log(
                        f"scan {self._job.id}: the row stopped being ours mid-job"
                    )
                    return
            except Exception as exc:  # noqa: BLE001 - a heartbeat must never
                # take a job down; a missed beat is survivable, a crashed
                # daemon thread taking the process with it is not.
                self._log(f"scan {self._job.id}: heartbeat failed ({redact(exc)})")


@dataclass
class JobOutcome:
    job: ScanJob
    outcome: str
    reason: str | None = None
    cloud_object_path: str | None = None
    manifest: dict[str, Any] | None = None
    point_count: int = 0
    frames_extracted: int = 0
    frames_registered: int = 0
    detail: str | None = None

    @property
    def ok(self) -> bool:
        return self.outcome == OUTCOME_READY


def run_job(
    job: ScanJob,
    *,
    config: Config,
    client: Any,
    queue: ScanQueue,
    reconstructor: Reconstructor,
    log: Callable[[str], None] | None = None,
    should_stop: Callable[[], bool] | None = None,
) -> JobOutcome:
    """Reconstruct one claimed scan and publish the result.

    `should_stop` is polled at each checkpoint so a Ctrl-C or a service stop
    RELEASES the row instead of leaving it `processing` for two hours until
    the stale sweeper notices.
    """
    emit = log or (lambda _m: None)
    work_dir = Path(config.work_dir) / job.id
    if work_dir.exists():
        shutil.rmtree(work_dir, ignore_errors=True)
    work_dir.mkdir(parents=True, exist_ok=True)

    try:
        outcome = _execute(
            job,
            config=config,
            client=client,
            queue=queue,
            reconstructor=reconstructor,
            work_dir=work_dir,
            emit=emit,
            should_stop=should_stop or (lambda: False),
        )
    except ScanFailure as failure:
        emit(f"scan {job.id}: FAILED — {failure.reason}")
        if failure.detail:
            emit(f"scan {job.id}: detail: {redact(failure.detail)}")
        queue.mark_failed(job, failure.reason)
        outcome = JobOutcome(
            job=job, outcome=OUTCOME_FAILED, reason=failure.reason, detail=failure.detail
        )
    except TransientError as transient:
        emit(f"scan {job.id}: released back to the queue — {redact(transient)}")
        queue.release(job)
        outcome = JobOutcome(
            job=job, outcome=OUTCOME_RELEASED, detail=redact(transient)
        )
    except WorkerError as broken:
        emit(f"scan {job.id}: worker error — {redact(broken)}")
        queue.release(job)
        outcome = JobOutcome(job=job, outcome=OUTCOME_RELEASED, detail=redact(broken))
    except Exception:  # noqa: BLE001 - deliberate catch-all, see module doc
        emit(f"scan {job.id}: unexpected error\n{redact(traceback.format_exc())}")
        reason = reasons.unexpected()
        queue.mark_failed(job, reason)
        outcome = JobOutcome(job=job, outcome=OUTCOME_FAILED, reason=reason)
    finally:
        if not config.keep_work_dir and not config.dry_run:
            shutil.rmtree(work_dir, ignore_errors=True)
    return outcome


def _execute(
    job: ScanJob,
    *,
    config: Config,
    client: Any,
    queue: ScanQueue,
    reconstructor: Reconstructor,
    work_dir: Path,
    emit: Callable[[str], None],
    should_stop: Callable[[], bool],
) -> JobOutcome:
    beat: Heartbeat | None = None

    def checkpoint() -> None:
        if should_stop():
            raise TransientError("the worker was asked to stop")
        if beat is not None and beat.lost:
            # Another worker reclaimed the row as stale. Two workers writing
            # one row is exactly what the claim protocol exists to prevent.
            raise TransientError("another worker reclaimed this scan while we worked on it")

    checkpoint()
    queue.heartbeat(job, P_DOWNLOAD, force=True)

    video = _download_video(job, config=config, client=client, work_dir=work_dir, emit=emit)

    checkpoint()
    queue.heartbeat(job, P_FRAMES, force=True)
    selection = prepare_frames(video, work_dir, config, log=emit)

    # The source video is the biggest thing on disk by an order of magnitude
    # and nothing downstream reads it again.
    try:
        video.unlink()
    except OSError:
        pass

    def progress(fraction: float, label: str) -> None:
        checkpoint()
        pct = P_RECONSTRUCT_START + max(0.0, min(1.0, fraction)) * (
            P_RECONSTRUCT_END - P_RECONSTRUCT_START
        )
        emit(f"scan {job.id}: {label} ({pct:.0f}%)")
        if beat is not None:
            beat.pct = pct
        if not queue.heartbeat(job, pct):
            raise TransientError("another worker reclaimed this scan while we worked on it")

    queue.heartbeat(job, P_RECONSTRUCT_START, force=True)
    with Heartbeat(
        queue, job, interval_s=config.heartbeat_interval_s, log=emit
    ) as beat:
        beat.pct = P_RECONSTRUCT_START
        result: ReconstructionResult = reconstructor.reconstruct(
            ReconstructionRequest(
                frames_dir=selection.frames_dir,
                work_dir=work_dir / "reconstruction",
                frame_count=selection.count,
                use_gpu=config.gpu != "off",
                dense=config.dense,
                progress=progress,
            )
        )
    checkpoint()
    _check_quality(result, frames_used=selection.count, config=config)

    checkpoint()
    queue.heartbeat(job, P_EXPORT, force=True)
    cloud, thinned = subsample(result.cloud, config.max_points, seed=config.random_seed)
    if thinned:
        emit(
            f"scan {job.id}: thinned {result.cloud.count} points to {cloud.count} "
            f"so a phone can open it"
        )
    cloud_path = work_dir / "cloud.ply"
    size = write_ply(cloud_path, cloud)
    emit(f"scan {job.id}: wrote {cloud.count} points ({size / 1e6:.1f} MB)")

    manifest = manifest_for_config(
        config, result=result, cloud=cloud, frames_extracted=selection.count
    )
    document = manifest_json(manifest)
    (work_dir / "manifest.json").write_text(document, encoding="utf-8")

    queue.heartbeat(job, P_UPLOAD, force=True)
    if config.dry_run:
        emit(
            f"scan {job.id}: dry run — artifacts left in {work_dir}, "
            f"would upload to {job.cloud_object_path}"
        )
    else:
        client.upload_object(
            config.bucket,
            job.cloud_object_path,
            cloud_path,
            content_type="application/octet-stream",
        )
        client.upload_bytes(
            config.bucket,
            job.manifest_object_path,
            document.encode("utf-8"),
            content_type="application/json",
        )
        emit(f"scan {job.id}: uploaded {job.cloud_object_path}")

    if not queue.mark_ready(
        job, cloud_object_path=job.cloud_object_path, manifest_json=document
    ):
        # The artifacts are uploaded and correct; only the row write lost a
        # race. Transient, so the scan gets picked up and finished cleanly.
        raise TransientError("could not mark the scan ready — the row is no longer ours")

    return JobOutcome(
        job=job,
        outcome=OUTCOME_READY,
        cloud_object_path=job.cloud_object_path,
        manifest=manifest,
        point_count=cloud.count,
        frames_extracted=selection.count,
        frames_registered=result.frames_registered,
    )


def _download_video(
    job: ScanJob,
    *,
    config: Config,
    client: Any,
    work_dir: Path,
    emit: Callable[[str], None],
) -> Path:
    if not job.video_object_path:
        raise ScanFailure(
            reasons.video_missing(), detail="row has uploadState=uploaded but no videoObjectPath"
        )
    destination = work_dir / "source.mp4"
    emit(f"scan {job.id}: downloading {job.video_object_path}")
    try:
        written = client.download_object(
            config.bucket, job.video_object_path, destination
        )
    except SupabaseHttpError as http_error:
        if http_error.status in (400, 404):
            # Storage answers 400 for a missing key on some paths; either way
            # the object is not there, and no retry will conjure it.
            raise ScanFailure(
                reasons.video_missing(), detail=f"storage said {http_error.status}"
            ) from None
        raise
    if written <= 0:
        raise ScanFailure(reasons.video_unreadable(), detail="downloaded zero bytes")
    emit(f"scan {job.id}: downloaded {written / 1e6:.1f} MB")
    return destination


def _check_quality(
    result: ReconstructionResult, *, frames_used: int, config: Config
) -> None:
    """Engine-agnostic gates: did we get a reconstruction worth showing?

    Lives here rather than in the back end so that a future engine inherits
    the same standard, and so the sentences a climber sees do not depend on
    which reconstructor happened to run.
    """
    registered = result.frames_registered
    ratio = registered / frames_used if frames_used else 0.0
    if registered < config.min_registered_frames or ratio < config.min_registered_ratio:
        raise ScanFailure(
            reasons.not_enough_overlap(registered, frames_used),
            detail=f"registered {registered}/{frames_used} (ratio {ratio:.2f})",
        )
    if result.cloud.count < config.min_points:
        raise ScanFailure(
            reasons.too_few_points(result.cloud.count),
            detail=f"point count {result.cloud.count} < {config.min_points}",
        )


__all__ = [
    "Heartbeat",
    "JobOutcome",
    "OUTCOME_FAILED",
    "OUTCOME_READY",
    "OUTCOME_RELEASED",
    "run_job",
]
