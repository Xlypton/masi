"""Command line: `run` for the daemon, `once` for a human, `doctor` for setup.

`doctor` exists because every problem this worker has on a fresh Windows box
looks the same from the outside — scans sit at `pending` forever — and the
causes are all different: no env vars, COLMAP not on PATH, a CPU-only COLMAP
build, a revoked key. It names which one, without ever printing the key.
"""

from __future__ import annotations

import argparse
import signal
import sys
import time
from pathlib import Path
from typing import Callable, Sequence

from . import WORKER_NAME, WORKER_VERSION
from .config import (
    ENV_KEY,
    ENV_URL,
    Config,
    config_from_env,
    redact,
    register_secret,
)
from .errors import ToolMissing, TransientError, WorkerError
from .process import run as run_command, which
from .queue import ScanQueue
from .reconstruct import build_reconstructor
from .supabase_client import SupabaseClient
from .worker import Worker

EXIT_OK = 0
EXIT_ERROR = 1
EXIT_TOOLS_MISSING = 3


def make_logger(level: str = "info") -> Callable[[str], None]:
    quiet = level.lower() in ("warn", "warning", "error")

    def log(message: str) -> None:
        if quiet and not message.lower().startswith(("error", "cannot", "scan")):
            return
        stamp = time.strftime("%H:%M:%S")
        print(f"[{stamp}] {redact(message)}", file=sys.stderr, flush=True)

    return log


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="rock_scan_worker",
        description=(
            "Masi rock-scan reconstruction worker: polls Supabase for uploaded "
            "climbing videos and turns them into 3D point clouds."
        ),
    )
    parser.add_argument("--version", action="version", version=f"{WORKER_NAME} {WORKER_VERSION}")
    sub = parser.add_subparsers(dest="command", required=True)

    run_parser = sub.add_parser("run", help="poll the queue and process scans")
    _add_common(run_parser)
    run_parser.add_argument(
        "--once",
        action="store_true",
        help="process at most one scan, then exit (no daemon)",
    )
    run_parser.add_argument(
        "--scan-id",
        help="process this specific rock_scans row instead of polling",
    )
    run_parser.add_argument(
        "--max-jobs", type=int, help="stop after this many scans (for a cron-style run)"
    )

    once_parser = sub.add_parser(
        "once", help="alias for `run --once`, for a human testing one job"
    )
    _add_common(once_parser)
    once_parser.add_argument("--scan-id", help="process this specific rock_scans row")

    doctor_parser = sub.add_parser(
        "doctor", help="check credentials, binaries, GPU and queue reachability"
    )
    _add_common(doctor_parser)
    return parser


def _add_common(parser: argparse.ArgumentParser) -> None:
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help=(
            "do all the work but write nothing back: no row update, no upload. "
            "Artifacts are left in the work directory."
        ),
    )
    parser.add_argument("--work-dir", type=Path, help="scratch directory (default: ./work)")
    parser.add_argument("--keep-work-dir", action="store_true", help="do not delete scratch files")
    parser.add_argument("--poll-interval", type=float, help="seconds between empty-queue polls")
    parser.add_argument(
        "--stale-timeout",
        type=float,
        help="seconds after which a 'processing' row is reclaimable (default 7200)",
    )
    parser.add_argument("--frame-budget", type=int, help="frames to feed the reconstruction (default 150)")
    parser.add_argument("--max-points", type=int, help="cap on points in the cloud (default 300000)")
    parser.add_argument("--dense", action="store_true", help="run dense MVS (needs CUDA; much slower)")
    parser.add_argument(
        "--gpu",
        choices=("auto", "on", "off"),
        help="auto (try GPU, fall back to CPU), on (require it), off (never)",
    )
    parser.add_argument("--engine", help="reconstruction back end (default: colmap)")
    parser.add_argument("--colmap-bin", help="path to the colmap executable")
    parser.add_argument("--ffmpeg-bin", help="path to the ffmpeg executable")
    parser.add_argument("--ffprobe-bin", help="path to the ffprobe executable")
    parser.add_argument("--log-level", default="info", choices=("debug", "info", "warn"))


def config_from_args(args: argparse.Namespace) -> Config:
    config = config_from_env().with_overrides(
        work_dir=getattr(args, "work_dir", None),
        keep_work_dir=True if getattr(args, "keep_work_dir", False) else None,
        poll_interval_s=getattr(args, "poll_interval", None),
        stale_claim_timeout_s=getattr(args, "stale_timeout", None),
        frame_budget=getattr(args, "frame_budget", None),
        max_points=getattr(args, "max_points", None),
        dense=True if getattr(args, "dense", False) else None,
        gpu=getattr(args, "gpu", None),
        engine=getattr(args, "engine", None),
        colmap_bin=getattr(args, "colmap_bin", None),
        ffmpeg_bin=getattr(args, "ffmpeg_bin", None),
        ffprobe_bin=getattr(args, "ffprobe_bin", None),
        dry_run=True if getattr(args, "dry_run", False) else None,
    )
    register_secret(config.service_role_key)
    return config


def _make_worker(config: Config, log: Callable[[str], None]) -> Worker:
    client = SupabaseClient(config.supabase_url, config.service_role_key)
    queue = ScanQueue(client, config, log=log)
    return Worker(
        config=config,
        client=client,
        queue=queue,
        reconstructor=build_reconstructor(config, log),
        log=log,
    )


def _install_signal_handlers(worker: Worker, log: Callable[[str], None]) -> None:
    def handler(signum: int, _frame: object) -> None:
        log(f"signal {signum} received; finishing up and releasing any claimed scan")
        worker.request_stop()

    for name in ("SIGINT", "SIGTERM", "SIGBREAK"):
        sig = getattr(signal, name, None)
        if sig is not None:
            try:
                signal.signal(sig, handler)
            except (ValueError, OSError):
                pass  # not the main thread, or not supported on this platform


def command_run(args: argparse.Namespace, log: Callable[[str], None]) -> int:
    config = config_from_args(args)
    config.require_credentials()
    if config.dry_run:
        log("DRY RUN: no row will be updated and nothing will be uploaded")

    worker = _make_worker(config, log)
    _install_signal_handlers(worker, log)

    try:
        worker.reconstructor.preflight()
    except ToolMissing as missing:
        log(f"preflight failed: {redact(missing)}")
        return EXIT_TOOLS_MISSING
    if which(config.ffmpeg_bin) is None or which(config.ffprobe_bin) is None:
        log(
            f"preflight failed: {config.ffmpeg_bin!r}/{config.ffprobe_bin!r} not on PATH. "
            "See tool/rock_scan_worker/README.md."
        )
        return EXIT_TOOLS_MISSING

    scan_id = getattr(args, "scan_id", None)
    single = getattr(args, "once", False) or args.command == "once" or bool(scan_id)

    try:
        if single:
            outcome = worker.run_once(scan_id)
            if outcome is None:
                log("nothing to do: no scan is uploaded and waiting")
                return EXIT_OK
            log(
                f"scan {outcome.job.id}: {outcome.outcome}"
                + (f" — {outcome.reason}" if outcome.reason else "")
            )
            return EXIT_OK if outcome.outcome != "failed" else EXIT_OK
        stats = worker.run_forever(max_jobs=getattr(args, "max_jobs", None))
        log(
            f"stopped after {stats.claimed} scans "
            f"({stats.ready} ready, {stats.failed} failed, {stats.released} released)"
        )
        return EXIT_OK
    except WorkerError as broken:
        log(f"error: {redact(broken)}")
        return EXIT_ERROR
    except KeyboardInterrupt:
        log("interrupted")
        return EXIT_OK


def command_doctor(args: argparse.Namespace, log: Callable[[str], None]) -> int:
    config = config_from_args(args)
    problems = 0

    def report(name: str, ok: bool, detail: str) -> None:
        nonlocal problems
        if not ok:
            problems += 1
        print(f"{'OK  ' if ok else 'FAIL'}  {name:<22} {detail}")

    # Credentials: presence only. The key itself is never printed, and its
    # length is not printed either — that is still information about a secret.
    host = config.supabase_url.split("//")[-1].split("/")[0] if config.supabase_url else ""
    report(ENV_URL, bool(config.supabase_url), host or "not set")
    report(ENV_KEY, bool(config.service_role_key), "set" if config.service_role_key else "not set")

    for binary in (config.ffmpeg_bin, config.ffprobe_bin):
        path = which(binary)
        report(binary, path is not None, path or "not on PATH")

    colmap_path = which(config.colmap_bin)
    report(config.colmap_bin, colmap_path is not None, colmap_path or "not on PATH")
    if colmap_path:
        try:
            reconstructor = build_reconstructor(config, log)
            version = getattr(reconstructor, "version", lambda: None)()
        except WorkerError:
            version = None
        report("colmap version", version is not None, version or "could not be determined")

    nvidia = which("nvidia-smi")
    if nvidia:
        result = run_command(
            [nvidia, "--query-gpu=name,driver_version", "--format=csv,noheader"],
            timeout_s=30.0,
        )
        gpu = result.stdout.strip().splitlines()[0] if result.ok and result.stdout.strip() else ""
        report("nvidia gpu", bool(gpu), gpu or "nvidia-smi gave no device")
    else:
        # Not a failure: CPU reconstruction works, it is only slow.
        print("WARN  nvidia-smi             not found — reconstruction will run on the CPU")

    if config.has_credentials:
        try:
            client = SupabaseClient(config.supabase_url, config.service_role_key)
            queue = ScanQueue(client, config, log=log)
            waiting = queue.claimable_rows(limit=100)
            processing = client.select(
                config.table,
                params={"status": "eq.processing", "deletedAt": "is.null", "limit": "100"},
            )
            report(
                "queue",
                True,
                f"{len(waiting)} waiting, {len(processing)} processing",
            )
        except (WorkerError, TransientError) as exc:
            report("queue", False, redact(exc))
    else:
        report("queue", False, "skipped: credentials are not set")

    print()
    print("engine:", config.engine, "| gpu mode:", config.gpu, "| frame budget:", config.frame_budget)
    return EXIT_OK if problems == 0 else EXIT_ERROR


def main(argv: Sequence[str] | None = None) -> int:
    args = build_parser().parse_args(list(argv) if argv is not None else None)
    log = make_logger(args.log_level)
    if args.command == "doctor":
        return command_doctor(args, log)
    return command_run(args, log)


if __name__ == "__main__":  # pragma: no cover
    raise SystemExit(main())
