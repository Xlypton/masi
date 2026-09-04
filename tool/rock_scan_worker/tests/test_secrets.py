"""The service_role key bypasses RLS. It must not reach a log line, an
exception message, a repr, or any file in this repo."""

from __future__ import annotations

import pytest

from rock_scan_worker import cli
from rock_scan_worker.config import (
    ENV_KEY,
    ENV_URL,
    Config,
    clear_secrets,
    config_from_env,
    redact,
    register_secret,
)
from rock_scan_worker.errors import TransientError
from rock_scan_worker.supabase_client import SupabaseClient, SupabaseHttpError

KEY = "service-role-key-that-must-never-appear-anywhere"


@pytest.fixture(autouse=True)
def _clean_secret_registry():
    clear_secrets()
    yield
    clear_secrets()


def test_the_key_is_not_in_the_config_repr():
    config = Config(supabase_url="https://x.supabase.co", service_role_key=KEY)
    assert KEY not in repr(config)


def test_credentials_come_from_the_environment():
    config = config_from_env({ENV_URL: "https://x.supabase.co/", ENV_KEY: KEY})
    assert config.supabase_url == "https://x.supabase.co"  # trailing slash trimmed
    assert config.service_role_key == KEY
    assert config.has_credentials


def test_redact_scrubs_a_registered_secret_anywhere_it_appears():
    register_secret(KEY)
    assert KEY not in redact(f"Authorization: Bearer {KEY}")
    assert "***redacted***" in redact(f"boom {KEY}")


def test_redact_ignores_something_too_short_to_be_a_secret():
    register_secret("ab")
    assert redact("abcd") == "abcd"


def test_an_http_error_body_is_redacted():
    register_secret(KEY)
    error = SupabaseHttpError(400, f"bad key {KEY}", where="patch rock_scans")
    assert KEY not in str(error)
    assert KEY not in error.body


def test_the_missing_credentials_message_never_contains_a_value():
    config = Config(supabase_url="", service_role_key="")
    with pytest.raises(SystemExit) as caught:
        config.require_credentials()
    message = str(caught.value)
    assert ENV_KEY in message and "PowerShell" in message
    assert "sbp_" not in message


def test_the_logger_redacts_every_line(capsys):
    register_secret(KEY)
    cli.make_logger("info")(f"talking to supabase with {KEY}")
    assert KEY not in capsys.readouterr().err


def test_a_network_failure_message_carries_no_credentials(monkeypatch):
    import requests

    register_secret(KEY)

    class ExplodingSession:
        def request(self, *args, **kwargs):
            raise requests.ConnectionError(f"failed to connect using key {KEY}")

    client = SupabaseClient("https://x.supabase.co", KEY, session=ExplodingSession())
    with pytest.raises(TransientError) as caught:
        client.select("rock_scans")
    assert KEY not in str(caught.value)


def test_doctor_reports_presence_without_revealing_anything(capsys):
    args = cli.build_parser().parse_args(["doctor"])
    import rock_scan_worker.cli as cli_module

    monkey = cli_module.config_from_env
    # No URL, so `doctor` skips the queue probe and this test makes no
    # network call.
    cli_module.config_from_env = lambda env=None: Config(
        supabase_url="", service_role_key=KEY
    )
    try:
        cli.command_doctor(args, lambda _m: None)
    finally:
        cli_module.config_from_env = monkey
    out = capsys.readouterr().out
    assert KEY not in out
    assert "set" in out
    assert str(len(KEY)) not in out, "even the key's length is information about it"
