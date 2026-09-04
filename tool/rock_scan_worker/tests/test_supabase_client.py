"""HTTP error classification. Getting this wrong is how a climber's scan gets
marked `failed` because a home router rebooted."""

from __future__ import annotations

from pathlib import Path

import pytest
import requests

from rock_scan_worker.errors import TransientError
from rock_scan_worker.supabase_client import SupabaseClient, SupabaseHttpError


class FakeResponse:
    def __init__(self, status_code=200, payload=None, text="", content=b"{}", chunks=None):
        self.status_code = status_code
        self._payload = payload if payload is not None else []
        self.text = text
        self.content = content
        self._chunks = chunks or [b"video-bytes"]

    def json(self):
        return self._payload

    def iter_content(self, chunk_size=1):
        yield from self._chunks


class FakeSession:
    def __init__(self, response=None, raises=None):
        self.response = response or FakeResponse()
        self.raises = raises
        self.calls: list[dict] = []

    def request(self, method, url, **kwargs):
        self.calls.append({"method": method, "url": url, **kwargs})
        if self.raises is not None:
            raise self.raises
        return self.response


def client(session) -> SupabaseClient:
    return SupabaseClient("https://x.supabase.co", "key-key-key", session=session)


@pytest.mark.parametrize("status", [408, 429, 500, 502, 503, 504])
def test_a_retryable_status_is_transient(status):
    with pytest.raises(TransientError):
        client(FakeSession(FakeResponse(status_code=status, text="upstream sad"))).select("rock_scans")


@pytest.mark.parametrize("status", [400, 401, 403, 404, 422])
def test_a_client_error_is_reported_as_itself(status):
    with pytest.raises(SupabaseHttpError) as caught:
        client(FakeSession(FakeResponse(status_code=status, text="nope"))).select("rock_scans")
    assert caught.value.status == status


@pytest.mark.parametrize(
    "exception",
    [requests.ConnectionError("reset"), requests.Timeout("slow"), requests.TooManyRedirects("loop")],
)
def test_every_network_failure_is_transient(exception):
    with pytest.raises(TransientError):
        client(FakeSession(raises=exception)).select("rock_scans")


def test_patch_asks_for_the_representation_so_row_count_is_knowable():
    session = FakeSession(FakeResponse(payload=[{"id": "a"}], content=b"[]"))
    rows = client(session).patch(
        "rock_scans", filters={"id": "eq.a", "status": "eq.pending"}, values={"status": "processing"}
    )
    assert rows == [{"id": "a"}]
    headers = session.calls[0]["headers"]
    assert headers["Prefer"] == "return=representation"
    assert session.calls[0]["params"] == {"id": "eq.a", "status": "eq.pending"}


def test_an_empty_patch_response_means_zero_rows_matched():
    session = FakeSession(FakeResponse(payload=[], content=b""))
    assert client(session).patch("rock_scans", filters={"id": "eq.a"}, values={}) == []


def test_credentials_travel_in_headers_never_in_the_url():
    session = FakeSession()
    client(session).select("rock_scans")
    call = session.calls[0]
    assert "key-key-key" not in call["url"]
    assert call["headers"]["apikey"] == "key-key-key"
    assert call["headers"]["Authorization"] == "Bearer key-key-key"


def test_download_streams_to_disk_and_reports_the_size(tmp_path: Path):
    session = FakeSession(FakeResponse(chunks=[b"abc", b"defg"]))
    destination = tmp_path / "nested" / "video.mp4"
    written = client(session).download_object("rock-scans", "uid/scan/source.mp4", destination)
    assert written == 7
    assert destination.read_bytes() == b"abcdefg"


def test_a_download_larger_than_the_ceiling_is_stopped(tmp_path: Path):
    session = FakeSession(FakeResponse(chunks=[b"x" * 100] * 10))
    with pytest.raises(TransientError):
        client(session).download_object(
            "rock-scans", "uid/scan/source.mp4", tmp_path / "v.mp4", max_bytes=150
        )


def test_object_keys_with_awkward_characters_are_encoded_but_keep_their_folders():
    session = FakeSession()
    client(session).download_object("rock-scans", "uid 1/scan#2/source.mp4", Path("/dev/null"))
    url = session.calls[0]["url"]
    assert "uid%201/scan%232/source.mp4" in url


def test_upload_upserts_so_a_re_run_replaces_the_old_artifact(tmp_path: Path):
    source = tmp_path / "cloud.ply"
    source.write_bytes(b"ply")
    session = FakeSession()
    client(session).upload_object("rock-scans", "uid/scan/cloud.ply", source)
    assert session.calls[0]["headers"]["x-upsert"] == "true"
    assert session.calls[0]["data"] == b"ply"
