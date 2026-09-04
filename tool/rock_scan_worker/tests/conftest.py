"""Shared fixtures. Adds the worker package to `sys.path` so the tests run
with a bare `pytest` from this directory, with nothing installed."""

from __future__ import annotations

import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from rock_scan_worker.config import Config  # noqa: E402


@pytest.fixture
def config(tmp_path: Path) -> Config:
    return Config(
        supabase_url="https://example.supabase.co",
        service_role_key="not-a-real-key-0123456789",
        work_dir=tmp_path / "work",
        poll_interval_s=0.0,
        stale_claim_timeout_s=7200.0,
    )


@pytest.fixture(scope="session")
def repo_root() -> Path:
    """The Masi checkout, so the contract tests can read the Dart source."""
    return ROOT.parent.parent


@pytest.fixture(scope="session")
def dart_server_owned_columns(repo_root: Path) -> set[str]:
    """`serverOwnedSyncColumns['rock_scans']` as the Dart client declares it.

    Parsed rather than duplicated: this set IS the boundary between the two
    writers, and a copy in a Python constant would drift silently the first
    time somebody adds a column on the Dart side.
    """
    import re

    source = repo_root / "lib" / "features" / "backup" / "data" / "sync_remote.dart"
    if not source.is_file():
        pytest.skip(f"{source} not found; running outside the Masi checkout")
    text = source.read_text(encoding="utf-8")
    match = re.search(
        r"serverOwnedSyncColumns\s*=\s*\{.*?'rock_scans'\s*:\s*\{(.*?)\}",
        text,
        re.DOTALL,
    )
    if match is None:
        pytest.skip("serverOwnedSyncColumns['rock_scans'] not found in sync_remote.dart")
    return set(re.findall(r"'([A-Za-z]+)'", match.group(1)))
