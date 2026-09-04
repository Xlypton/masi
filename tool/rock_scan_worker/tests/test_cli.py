"""Argument plumbing. Cheap tests, but a `--dry-run` that silently does not
reach the config is a flag that writes to the live database."""

from __future__ import annotations

from pathlib import Path

import pytest

from rock_scan_worker import cli
from rock_scan_worker.config import Config


def parse(argv: list[str]):
    return cli.build_parser().parse_args(argv)


def test_dry_run_reaches_the_config():
    assert cli.config_from_args(parse(["run", "--dry-run"])).dry_run is True
    assert cli.config_from_args(parse(["run"])).dry_run is False


def test_flags_override_the_defaults():
    config = cli.config_from_args(
        parse(
            [
                "run", "--frame-budget", "40", "--max-points", "1000",
                "--stale-timeout", "600", "--poll-interval", "5",
                "--gpu", "off", "--dense", "--work-dir", "/tmp/scan-work",
            ]
        )
    )
    assert config.frame_budget == 40
    assert config.max_points == 1_000
    assert config.stale_claim_timeout_s == 600
    assert config.poll_interval_s == 5
    assert config.gpu == "off"
    assert config.dense is True
    assert config.work_dir == Path("/tmp/scan-work")


def test_unset_flags_leave_the_defaults_alone():
    config = cli.config_from_args(parse(["run"]))
    defaults = Config(supabase_url="")
    assert config.frame_budget == defaults.frame_budget
    assert config.max_points == defaults.max_points
    assert config.gpu == defaults.gpu
    assert config.stale_claim_timeout_s == defaults.stale_claim_timeout_s


def test_once_is_a_single_job_mode():
    assert parse(["once"]).command == "once"
    assert parse(["run", "--once"]).once is True


def test_a_missing_key_exits_with_instructions_for_both_shells(monkeypatch):
    monkeypatch.delenv("SUPABASE_SERVICE_ROLE_KEY", raising=False)
    monkeypatch.setenv("SUPABASE_URL", "https://x.supabase.co")
    with pytest.raises(SystemExit) as caught:
        cli.command_run(parse(["run", "--once"]), lambda _m: None)
    message = str(caught.value)
    assert "PowerShell" in message and "export" in message


def test_missing_binaries_exit_with_the_tools_code(monkeypatch):
    monkeypatch.setenv("SUPABASE_URL", "https://x.supabase.co")
    monkeypatch.setenv("SUPABASE_SERVICE_ROLE_KEY", "not-a-real-key")
    monkeypatch.setattr(cli, "which", lambda _binary: None)
    code = cli.command_run(parse(["run", "--once", "--colmap-bin", "nope"]), lambda _m: None)
    assert code == cli.EXIT_TOOLS_MISSING


def test_gpu_choices_are_constrained():
    with pytest.raises(SystemExit):
        parse(["run", "--gpu", "maybe"])
