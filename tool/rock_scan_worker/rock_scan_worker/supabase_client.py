"""A small, explicit Supabase client: PostgREST rows plus Storage objects.

Deliberately not the `supabase` SDK. This process needs four verbs — select,
conditional patch, download an object, upload an object — and in exchange for
writing them by hand we get: a single dependency (`requests`), an exact say
over what a "conditional update" means (the claim protocol lives or dies on
`Prefer: return=representation` telling us the ROW COUNT), and control over
error classification, which is the difference between failing a climber's
scan and retrying it.

Nothing here ever logs a header. The key is passed per-request and scrubbed
from any message that escapes, via `config.redact`.
"""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any, Iterable, Mapping

import requests

from .config import redact
from .errors import TransientError, WorkerError

#: Statuses that mean "ask again later", not "this request was wrong".
_RETRYABLE_STATUS = frozenset({408, 409, 425, 429, 500, 502, 503, 504})

JsonDict = dict[str, Any]


class SupabaseHttpError(WorkerError):
    """A 4xx that is genuinely our request's fault."""

    def __init__(self, status: int, body: str, *, where: str) -> None:
        super().__init__(f"{where}: HTTP {status}: {redact(body)[:400]}")
        self.status = status
        self.body = redact(body)
        self.where = where


class SupabaseClient:
    """REST + Storage over one pooled `requests.Session`."""

    def __init__(
        self,
        url: str,
        service_role_key: str,
        *,
        timeout_s: float = 30.0,
        session: requests.Session | None = None,
    ) -> None:
        self._url = url.rstrip("/")
        self._key = service_role_key
        self._timeout = timeout_s
        self._session = session or requests.Session()

    # -- plumbing -----------------------------------------------------------

    def _headers(self, extra: Mapping[str, str] | None = None) -> dict[str, str]:
        headers = {
            "apikey": self._key,
            "Authorization": f"Bearer {self._key}",
        }
        if extra:
            headers.update(extra)
        return headers

    def _request(
        self,
        method: str,
        path: str,
        *,
        where: str,
        params: Mapping[str, str] | None = None,
        json_body: Any = None,
        data: bytes | None = None,
        headers: Mapping[str, str] | None = None,
        stream: bool = False,
        timeout_s: float | None = None,
    ) -> requests.Response:
        url = f"{self._url}{path}"
        try:
            response = self._session.request(
                method,
                url,
                params=dict(params or {}),
                json=json_body,
                data=data,
                headers=self._headers(headers),
                stream=stream,
                timeout=timeout_s or self._timeout,
            )
        except requests.RequestException as exc:  # DNS, refused, reset, timeout
            raise TransientError(f"{where}: network error: {redact(exc)}") from None

        if response.status_code in _RETRYABLE_STATUS:
            raise TransientError(
                f"{where}: HTTP {response.status_code} (retryable): "
                f"{redact(response.text)[:200]}"
            )
        if response.status_code >= 400:
            raise SupabaseHttpError(response.status_code, response.text, where=where)
        return response

    # -- rows ---------------------------------------------------------------

    def select(
        self,
        table: str,
        *,
        params: Mapping[str, str] | None = None,
    ) -> list[JsonDict]:
        query = {"select": "*"}
        query.update(params or {})
        response = self._request(
            "GET", f"/rest/v1/{table}", where=f"select {table}", params=query
        )
        payload = response.json()
        return payload if isinstance(payload, list) else []

    def patch(
        self,
        table: str,
        *,
        filters: Mapping[str, str],
        values: Mapping[str, Any],
    ) -> list[JsonDict]:
        """Conditional UPDATE. Returns the rows actually changed.

        The returned LENGTH is the claim protocol's whole safety argument: an
        empty list means the WHERE did not match any more, i.e. another
        worker got there first. Never fold this into a select-then-update.
        """
        response = self._request(
            "PATCH",
            f"/rest/v1/{table}",
            where=f"patch {table}",
            params=dict(filters),
            json_body=dict(values),
            headers={
                "Content-Type": "application/json",
                "Prefer": "return=representation",
            },
        )
        if not response.content:
            return []
        payload = response.json()
        return payload if isinstance(payload, list) else []

    # -- storage ------------------------------------------------------------

    def download_object(
        self,
        bucket: str,
        object_path: str,
        destination: Path,
        *,
        max_bytes: int | None = None,
    ) -> int:
        """Stream `bucket/object_path` to `destination`; returns byte count."""
        response = self._request(
            "GET",
            f"/storage/v1/object/{bucket}/{_quote_object(object_path)}",
            where=f"download {bucket}/{object_path}",
            stream=True,
            timeout_s=max(self._timeout, 300.0),
        )
        destination.parent.mkdir(parents=True, exist_ok=True)
        written = 0
        try:
            with destination.open("wb") as handle:
                for chunk in response.iter_content(chunk_size=1 << 20):
                    if not chunk:
                        continue
                    written += len(chunk)
                    if max_bytes is not None and written > max_bytes:
                        raise TransientError(
                            f"download {bucket}/{object_path}: larger than the "
                            f"{max_bytes} byte ceiling"
                        )
                    handle.write(chunk)
        except requests.RequestException as exc:
            raise TransientError(f"download {bucket}/{object_path}: {redact(exc)}") from None
        return written

    def upload_object(
        self,
        bucket: str,
        object_path: str,
        source: Path,
        *,
        content_type: str = "application/octet-stream",
    ) -> str:
        """Upsert a local file to `bucket/object_path`; returns the key."""
        payload = source.read_bytes()
        self._request(
            "POST",
            f"/storage/v1/object/{bucket}/{_quote_object(object_path)}",
            where=f"upload {bucket}/{object_path}",
            data=payload,
            headers={
                "Content-Type": content_type,
                "x-upsert": "true",
                "Cache-Control": "3600",
            },
            timeout_s=max(self._timeout, 300.0),
        )
        return object_path

    def upload_bytes(
        self,
        bucket: str,
        object_path: str,
        payload: bytes,
        *,
        content_type: str = "application/octet-stream",
    ) -> str:
        self._request(
            "POST",
            f"/storage/v1/object/{bucket}/{_quote_object(object_path)}",
            where=f"upload {bucket}/{object_path}",
            data=payload,
            headers={
                "Content-Type": content_type,
                "x-upsert": "true",
                "Cache-Control": "3600",
            },
            timeout_s=max(self._timeout, 300.0),
        )
        return object_path


def _quote_object(object_path: str) -> str:
    """Percent-encode an object key, keeping `/` as the folder separator."""
    from urllib.parse import quote

    return quote(object_path.lstrip("/"), safe="/")


def describe_rows(rows: Iterable[JsonDict]) -> str:
    """Compact, secret-free debug rendering of a row list."""
    return json.dumps(
        [{k: r.get(k) for k in ("id", "status", "uploadState", "updatedAt")} for r in rows],
        sort_keys=True,
    )
