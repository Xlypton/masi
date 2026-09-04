"""Runtime configuration: env for secrets, CLI flags for behaviour.

The service_role key is read from the environment and lives in exactly one
attribute, which `__repr__` refuses to show. It bypasses RLS — that is the
entire reason the worker can write server-owned columns and the app cannot —
so it must never reach a file in this repo, a log line, or an error message.
`redact()` below is the belt to that braces: everything this package prints
goes through it.
"""

from __future__ import annotations

import os
from dataclasses import dataclass, field, replace
from pathlib import Path

ENV_URL = "SUPABASE_URL"
ENV_KEY = "SUPABASE_SERVICE_ROLE_KEY"

#: Storage bucket holding both the source videos and our artifacts. Created
#: by supabase/migrations/2026-09-04_rock_scans.sql; private, 500 MB objects.
DEFAULT_BUCKET = "rock-scans"
DEFAULT_TABLE = "rock_scans"


@dataclass(frozen=True)
class Config:
    """Everything the worker needs to run one job or a thousand."""

    supabase_url: str
    #: Never logged, never persisted, never in a repr. See `redact`.
    service_role_key: str = field(repr=False, default="")

    bucket: str = DEFAULT_BUCKET
    table: str = DEFAULT_TABLE

    # --- polling -----------------------------------------------------------
    poll_interval_s: float = 20.0
    #: A row stuck in `processing` older than this is claimable again: a
    #: worker that crashes mid-job must not wedge a scan forever. Live jobs
    #: heartbeat their `updatedAt` well inside it (see ScanQueue.heartbeat).
    stale_claim_timeout_s: float = 2 * 60 * 60
    #: How many oldest claimable rows to fetch per poll before giving up on
    #: winning a race this round.
    claim_candidates: int = 5
    #: How many times one scan may be RELEASED back to the queue before this
    #: worker stops trying and marks it failed.
    #:
    #: Without a bound this is a livelock, and it is not hypothetical: the
    #: first real cross-machine run wedged here. A non-zero exit from the
    #: reconstruction engine is classed transient — reasonably, since the
    #: same frames may reconstruct fine on a working box — so the job was
    #: released, re-claimed immediately, and failed again, about every 13
    #: seconds, indefinitely. Nothing was ever written to `failureReason`,
    #: so from the phone the scan simply said "Building the 3D model"
    #: forever, and from the database the fault was invisible.
    #:
    #: Counted per worker PROCESS, not persisted on the row. A restart is an
    #: operator deciding to try again, which is exactly when the count should
    #: reset — and it needs no column, so no schema change and no second
    #: writer of a client-visible field.
    max_release_attempts: int = 3
    #: How often a job in flight bumps `updatedAt` while it is inside a
    #: long-running external command. Must stay comfortably under
    #: `stale_claim_timeout_s`, because it is the only thing between a slow
    #: reconstruction and another worker deciding it died. Also what the
    #: phone's progress bar moves on.
    heartbeat_interval_s: float = 60.0

    # --- pipeline ----------------------------------------------------------
    frame_budget: int = 150
    #: Below this many usable frames a reconstruction is not worth attempting.
    min_frames: int = 20
    #: Candidate frames pulled per kept frame, before sharpness/dedupe.
    candidate_multiplier: float = 3.0
    #: Longest edge of an extracted frame. 1600 keeps SIFT fast without
    #: throwing away the texture COLMAP matches on.
    frame_max_edge: int = 1600
    min_video_duration_s: float = 3.0
    max_points: int = 300_000
    #: Engine-agnostic quality floors, applied by the pipeline rather than
    #: the reconstructor so a new back end inherits them for free.
    min_registered_frames: int = 8
    min_registered_ratio: float = 0.25
    min_points: int = 500
    #: Cameras listed in the manifest. The viewer draws where the climber
    #: walked; a few hundred positions shows that, 150 000 would bloat a row.
    max_manifest_cameras: int = 300
    dense: bool = False
    #: "auto" tries the GPU and falls back to CPU with a loud log line;
    #: "on" refuses to fall back; "off" never asks for it.
    gpu: str = "auto"
    #: Deterministic subsampling, so a re-run of the same scan is comparable.
    random_seed: int = 20260904

    # --- local paths / binaries -------------------------------------------
    work_dir: Path = Path("work")
    keep_work_dir: bool = False
    ffmpeg_bin: str = "ffmpeg"
    ffprobe_bin: str = "ffprobe"
    colmap_bin: str = "colmap"
    engine: str = "colmap"
    #: Wall-clock ceiling for any single external command.
    subprocess_timeout_s: float = 6 * 60 * 60

    # --- modes -------------------------------------------------------------
    #: Read the queue, do the work, write NOTHING back (no row update, no
    #: upload). Artifacts land under work_dir so a human can look at them.
    dry_run: bool = False

    def with_overrides(self, **kwargs: object) -> "Config":
        clean = {k: v for k, v in kwargs.items() if v is not None}
        return replace(self, **clean)  # type: ignore[arg-type]

    @property
    def has_credentials(self) -> bool:
        return bool(self.supabase_url and self.service_role_key)

    def require_credentials(self) -> None:
        missing = [
            name
            for name, value in ((ENV_URL, self.supabase_url), (ENV_KEY, self.service_role_key))
            if not value
        ]
        if missing:
            raise SystemExit(
                "Missing environment variable(s): "
                + ", ".join(missing)
                + ".\n  PowerShell:  $env:"
                + ENV_KEY
                + ' = "<paste the service_role key>"'
                + "\n  bash:        export "
                + ENV_KEY
                + '="<paste the service_role key>"'
                + "\nSee tool/rock_scan_worker/README.md. Never put the key in a file in this repo."
            )


def config_from_env(env: dict[str, str] | None = None) -> Config:
    """Config with only the credential fields filled in from `env`."""
    source = os.environ if env is None else env
    return Config(
        supabase_url=(source.get(ENV_URL) or "").rstrip("/"),
        service_role_key=source.get(ENV_KEY) or "",
    )


_SECRETS: list[str] = []


def register_secret(value: str | None) -> None:
    """Teach `redact` one more string to scrub. Called once at startup."""
    if value and len(value) >= 8 and value not in _SECRETS:
        _SECRETS.append(value)


def clear_secrets() -> None:
    """Test hook; also used when re-configuring in-process."""
    _SECRETS.clear()


def redact(text: object) -> str:
    """`text` with every registered secret replaced by a marker.

    Applied to every log line and every exception message that could have
    passed near a header or a signed URL. It is cheap and it is the only
    thing standing between a stray `raise` and a key in a terminal
    somebody screenshots.
    """
    out = str(text)
    for secret in _SECRETS:
        if secret in out:
            out = out.replace(secret, "***redacted***")
    return out
