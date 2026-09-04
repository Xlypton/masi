"""The claim protocol: the only place in this worker that writes a row.

Three invariants, and every one of them has teeth in the tests:

1. **The worker owns five columns and nothing else.** `status`,
   `progressPct`, `cloudObjectPath`, `manifestJson`, `failureReason` — the
   exact set `serverOwnedSyncColumns` in `lib/features/backup/data/
   sync_remote.dart` strips out of every client push. Plus `updatedAt`, which
   we MUST bump or the client's pull filter never sees the change. Anything
   else in a write body is a bug, so `_assert_writable` raises rather than
   letting it reach the network.

2. **Claiming is one conditional UPDATE.** `SET status='processing' WHERE
   id = ? AND status = 'pending'`, and zero rows back means another worker
   won. A SELECT-then-UPDATE would hand the same video to two GPUs.

3. **A crashed worker must not wedge a scan forever.** A row left in
   `processing` whose `updatedAt` is older than the stale timeout is
   claimable again, under exactly the same conditional-update discipline
   (`AND status='processing' AND "updatedAt" < cutoff`). Live jobs heartbeat
   their progress well inside the timeout, which is what keeps a slow-but-
   healthy reconstruction from being stolen out from under itself.
"""

from __future__ import annotations

import threading
import time
from dataclasses import dataclass, field
from typing import Any, Callable, Mapping

from .config import Config
from .errors import WorkerError

#: Written by the reconstruction worker. Mirrors `serverOwnedSyncColumns`.
WORKER_OWNED_COLUMNS = frozenset(
    {"status", "progressPct", "cloudObjectPath", "manifestJson", "failureReason"}
)

#: Written by the app. The worker touching any of these would fight the
#: client's full-state re-push and lose a climber's capture state.
CLIENT_OWNED_COLUMNS = frozenset(
    {
        "id",
        "createdAt",
        "deletedAt",
        "remoteId",
        "dirty",
        "ownerId",
        "wallId",
        "uploadState",
        "videoObjectPath",
        "durationMs",
        "sizeBytes",
    }
)

#: `updatedAt` is not "owned" by either side; it is the sync engine's clock
#: and every writer bumps it. Without it the client's pull never notices us.
WRITABLE_COLUMNS = WORKER_OWNED_COLUMNS | {"updatedAt"}

STATUS_PENDING = "pending"
STATUS_PROCESSING = "processing"
STATUS_READY = "ready"
STATUS_FAILED = "failed"

UPLOAD_UPLOADED = "uploaded"

#: `failureReason` is shown verbatim on a phone. Anything past this is not a
#: sentence a climber reads, it is a stack trace someone forgot to map.
MAX_FAILURE_REASON_CHARS = 400


def now_ms() -> int:
    """Milliseconds since the epoch — the repo-wide timestamp unit."""
    return int(time.time() * 1000)


@dataclass(frozen=True)
class ScanJob:
    """One claimed row, flattened to what the pipeline actually needs."""

    id: str
    wall_id: str
    owner_id: str | None
    video_object_path: str | None
    size_bytes: int | None
    duration_ms: int | None
    created_at: int
    #: `updatedAt` as it stood when WE claimed it.
    claimed_at: int
    row: Mapping[str, Any] = field(default_factory=dict, repr=False)

    @property
    def artifact_prefix(self) -> str:
        """`<ownerId>/<scanId>` — where our artifacts go.

        Falls back to the video's own folder when `ownerId` is null (a row
        written by an older client), because that folder is by storage policy
        the owner's uid. Only then does it fall back to a literal, which at
        least keeps artifacts of unknown provenance out of a real user's
        prefix.
        """
        owner = (self.owner_id or "").strip()
        if not owner and self.video_object_path:
            head = self.video_object_path.lstrip("/").split("/", 1)[0]
            owner = head.strip()
        return f"{owner or 'unknown-owner'}/{self.id}"

    @property
    def cloud_object_path(self) -> str:
        return f"{self.artifact_prefix}/cloud.ply"

    @property
    def manifest_object_path(self) -> str:
        return f"{self.artifact_prefix}/manifest.json"


def job_from_row(row: Mapping[str, Any]) -> ScanJob:
    return ScanJob(
        id=str(row["id"]),
        wall_id=str(row.get("wallId") or ""),
        owner_id=(str(row["ownerId"]) if row.get("ownerId") else None),
        video_object_path=(
            str(row["videoObjectPath"]) if row.get("videoObjectPath") else None
        ),
        size_bytes=_as_int(row.get("sizeBytes")),
        duration_ms=_as_int(row.get("durationMs")),
        created_at=_as_int(row.get("createdAt")) or 0,
        claimed_at=_as_int(row.get("updatedAt")) or 0,
        row=dict(row),
    )


def _as_int(value: Any) -> int | None:
    if isinstance(value, bool) or value is None:
        return None
    try:
        return int(value)
    except (TypeError, ValueError):
        return None


def _assert_writable(values: Mapping[str, Any]) -> None:
    forbidden = set(values) - WRITABLE_COLUMNS
    if forbidden:
        # Deliberately loud and deliberately before the request is made.
        raise WorkerError(
            "worker tried to write column(s) it does not own: "
            + ", ".join(sorted(forbidden))
            + f" (writable: {', '.join(sorted(WRITABLE_COLUMNS))})"
        )


class ScanQueue:
    """Claim / heartbeat / finish, over any object with `select` + `patch`."""

    def __init__(
        self,
        client: Any,
        config: Config,
        *,
        clock: Callable[[], int] = now_ms,
        log: Callable[[str], None] | None = None,
    ) -> None:
        self._client = client
        self._config = config
        self._clock = clock
        self._log = log or (lambda _msg: None)
        self._last_heartbeat_ms = 0
        self._last_progress_pct: int | None = None
        # A background heartbeat writes from another thread while the main
        # one is blocked in COLMAP, and `requests.Session` is not documented
        # thread-safe. One lock over the single write path is the whole fix.
        self._write_lock = threading.Lock()

    # -- reads --------------------------------------------------------------

    def claimable_rows(self, limit: int | None = None) -> list[dict[str, Any]]:
        """Fresh work, oldest first — exactly the partial index's predicate."""
        return self._client.select(
            self._config.table,
            params={
                "uploadState": f"eq.{UPLOAD_UPLOADED}",
                "status": f"eq.{STATUS_PENDING}",
                "deletedAt": "is.null",
                "order": "createdAt.asc",
                "limit": str(limit or self._config.claim_candidates),
            },
        )

    def stale_rows(self, limit: int | None = None) -> list[dict[str, Any]]:
        """Rows abandoned mid-reconstruction by a worker that died."""
        cutoff = self._clock() - int(self._config.stale_claim_timeout_s * 1000)
        return self._client.select(
            self._config.table,
            params={
                "status": f"eq.{STATUS_PROCESSING}",
                "deletedAt": "is.null",
                "updatedAt": f"lt.{cutoff}",
                "order": "updatedAt.asc",
                "limit": str(limit or self._config.claim_candidates),
            },
        )

    def get_row(self, scan_id: str) -> dict[str, Any] | None:
        rows = self._client.select(
            self._config.table, params={"id": f"eq.{scan_id}", "limit": "1"}
        )
        return rows[0] if rows else None

    # -- claiming -----------------------------------------------------------

    def claim_next(self) -> ScanJob | None:
        """The oldest claimable row we win the race for, else None.

        Fresh `pending` work first; only when there is none do we look for
        rows a dead worker left in `processing`. That ordering matters: a
        climber waiting on a brand-new scan should not queue behind the
        recovery of one that already had its chance.
        """
        for row in self.claimable_rows():
            job = self._try_claim_pending(row)
            if job is not None:
                return job

        for row in self.stale_rows():
            job = self._try_reclaim_stale(row)
            if job is not None:
                return job
        return None

    def claim_specific(self, scan_id: str) -> ScanJob | None:
        """Claim one named row, for `--scan-id`. Same conditional update."""
        row = self.get_row(scan_id)
        if row is None:
            raise WorkerError(f"no rock_scans row with id {scan_id}")
        if row.get("deletedAt") is not None:
            raise WorkerError(f"scan {scan_id} is deleted")
        if row.get("uploadState") != UPLOAD_UPLOADED:
            raise WorkerError(
                f"scan {scan_id} has uploadState={row.get('uploadState')!r}; "
                "its video is not in Storage yet"
            )
        status = row.get("status")
        if status == STATUS_PENDING:
            return self._try_claim_pending(row)
        if status == STATUS_PROCESSING:
            return self._try_reclaim_stale(row, ignore_cutoff=True)
        raise WorkerError(f"scan {scan_id} is already {status!r}")

    def _try_claim_pending(self, row: Mapping[str, Any]) -> ScanJob | None:
        scan_id = str(row.get("id") or "")
        if not scan_id:
            return None
        updated = self._patch(
            filters={"id": f"eq.{scan_id}", "status": f"eq.{STATUS_PENDING}"},
            values={
                "status": STATUS_PROCESSING,
                "progressPct": 0,
                "failureReason": None,
            },
        )
        if not updated:
            self._log(f"scan {scan_id}: claimed by another worker first")
            return None
        # Merge over the row we listed: a real PostgREST representation is
        # already complete, but a --dry-run PATCH only echoes what it would
        # have written, and the pipeline still needs the client-owned fields.
        return self._begin({**row, **updated[0]})

    def _try_reclaim_stale(
        self, row: Mapping[str, Any], *, ignore_cutoff: bool = False
    ) -> ScanJob | None:
        scan_id = str(row.get("id") or "")
        if not scan_id:
            return None
        filters = {"id": f"eq.{scan_id}", "status": f"eq.{STATUS_PROCESSING}"}
        if not ignore_cutoff:
            # Re-asserting the cutoff in the WHERE is what makes reclaim safe:
            # if the owning worker heartbeat between our SELECT and this
            # PATCH, the row no longer matches and we lose the race cleanly.
            cutoff = self._clock() - int(self._config.stale_claim_timeout_s * 1000)
            filters["updatedAt"] = f"lt.{cutoff}"
        updated = self._patch(
            filters=filters,
            values={
                "status": STATUS_PROCESSING,
                "progressPct": 0,
                "failureReason": None,
            },
        )
        if not updated:
            self._log(f"scan {scan_id}: stale reclaim lost the race")
            return None
        self._log(f"scan {scan_id}: reclaimed from a worker that stopped reporting")
        return self._begin({**row, **updated[0]})

    def _begin(self, row: Mapping[str, Any]) -> ScanJob:
        self._last_heartbeat_ms = self._clock()
        self._last_progress_pct = 0
        return job_from_row(row)

    # -- progress and finishing ---------------------------------------------

    def heartbeat(
        self,
        job: ScanJob,
        progress_pct: float,
        *,
        force: bool = False,
        min_interval_s: float = 20.0,
    ) -> bool:
        """Bump `progressPct` + `updatedAt` while we still own the row.

        Doubles as the anti-stale-reclaim heartbeat, which is why it writes
        on a timer even when the percentage has not moved. Returns False if
        the row is no longer ours — the caller decides whether to abandon.
        """
        pct = max(0, min(100, int(round(progress_pct))))
        elapsed_s = (self._clock() - self._last_heartbeat_ms) / 1000.0
        if not force and pct == self._last_progress_pct and elapsed_s < min_interval_s:
            return True
        updated = self._patch(
            filters={"id": f"eq.{job.id}", "status": f"eq.{STATUS_PROCESSING}"},
            values={"progressPct": pct},
        )
        self._last_heartbeat_ms = self._clock()
        self._last_progress_pct = pct
        return bool(updated)

    def mark_ready(
        self, job: ScanJob, *, cloud_object_path: str, manifest_json: str
    ) -> bool:
        updated = self._patch(
            filters={"id": f"eq.{job.id}", "status": f"eq.{STATUS_PROCESSING}"},
            values={
                "status": STATUS_READY,
                "progressPct": 100,
                "cloudObjectPath": cloud_object_path,
                "manifestJson": manifest_json,
                "failureReason": None,
            },
        )
        return bool(updated)

    def mark_failed(self, job: ScanJob, reason: str) -> bool:
        updated = self._patch(
            filters={"id": f"eq.{job.id}", "status": f"eq.{STATUS_PROCESSING}"},
            values={
                "status": STATUS_FAILED,
                "progressPct": None,
                "failureReason": clamp_reason(reason),
            },
        )
        return bool(updated)

    def release(self, job: ScanJob) -> bool:
        """Put the row back on the queue, untouched otherwise.

        For infrastructure trouble — our network died, COLMAP vanished, the
        process was asked to stop. The scan is fine; we just are not the ones
        finishing it right now.

        Deliberately writes NO `failureReason`. Recording the transient's own
        text here was tried and reverted: that column is a sentence rendered
        verbatim next to a scan on a phone (see `reasons.py`), and a release
        carries engine and network wording that has no business there. The
        cost is that a repeatedly-failing job is not diagnosable from the
        database alone — the detail lives on the worker's console. What makes
        that acceptable is the release BOUND
        (`Config.max_release_attempts`): after it, the job is marked failed
        with a human sentence, so the climber is told something true even
        though the operator still needs the log for the why.
        """
        updated = self._patch(
            filters={"id": f"eq.{job.id}", "status": f"eq.{STATUS_PROCESSING}"},
            values={"status": STATUS_PENDING, "progressPct": None},
        )
        return bool(updated)

    # -- the single write path ----------------------------------------------

    def _patch(
        self, *, filters: Mapping[str, str], values: Mapping[str, Any]
    ) -> list[dict[str, Any]]:
        body = dict(values)
        # Every write bumps the sync clock. Set here, once, so no caller can
        # forget it and quietly ship a change no client will ever pull.
        body["updatedAt"] = self._clock()
        _assert_writable(body)
        if self._config.dry_run:
            self._log(f"dry-run: would PATCH {filters} <- {sorted(body)}")
            return [{"id": _id_from_filter(filters), **body}]
        with self._write_lock:
            return self._client.patch(self._config.table, filters=filters, values=body)


def clamp_reason(reason: str) -> str:
    text = " ".join(str(reason).split())
    if len(text) <= MAX_FAILURE_REASON_CHARS:
        return text
    return text[: MAX_FAILURE_REASON_CHARS - 1].rstrip() + "…"


def _id_from_filter(filters: Mapping[str, str]) -> str:
    raw = filters.get("id", "")
    return raw[3:] if raw.startswith("eq.") else raw
