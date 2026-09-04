"""A PostgREST-shaped fake: enough filter semantics to test the real thing.

The claim protocol's correctness lives entirely in *what the WHERE clause
matched*, so a fake that ignores filters would pass every test while the real
worker handed one video to two GPUs. This one implements `eq.`, `is.null`,
`lt.`, `gt.`, `order` and `limit` against in-memory rows, records every write,
and offers `on_patch` so a test can simulate another worker winning the race
in the window between our SELECT and our PATCH.
"""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable, Mapping


@dataclass
class PatchCall:
    table: str
    filters: dict[str, str]
    values: dict[str, Any]
    matched: int


class FakeSupabase:
    def __init__(self, rows: list[dict[str, Any]] | None = None) -> None:
        self.rows: dict[str, dict[str, Any]] = {
            str(row["id"]): dict(row) for row in (rows or [])
        }
        self.patches: list[PatchCall] = []
        self.uploads: dict[str, bytes] = {}
        self.objects: dict[str, bytes] = {}
        #: Called with (filters, values) BEFORE a patch is applied, so a test
        #: can mutate rows to simulate a concurrent worker.
        self.on_patch: Callable[[Mapping[str, str], Mapping[str, Any]], None] | None = None
        self.download_error: Exception | None = None

    # -- rows ---------------------------------------------------------------

    def select(self, table: str, *, params: Mapping[str, str] | None = None) -> list[dict[str, Any]]:
        params = dict(params or {})
        limit = int(params.pop("limit", "1000"))
        order = params.pop("order", None)
        params.pop("select", None)
        matched = [row for row in self.rows.values() if _matches(row, params)]
        if order:
            column, _, direction = order.partition(".")
            matched.sort(
                key=lambda r: _sort_key(r.get(column)),
                reverse=direction == "desc",
            )
        return [dict(row) for row in matched[:limit]]

    def patch(
        self,
        table: str,
        *,
        filters: Mapping[str, str],
        values: Mapping[str, Any],
    ) -> list[dict[str, Any]]:
        if self.on_patch is not None:
            self.on_patch(filters, values)
        updated: list[dict[str, Any]] = []
        for row in self.rows.values():
            if _matches(row, filters):
                row.update(values)
                updated.append(dict(row))
        self.patches.append(
            PatchCall(
                table=table,
                filters=dict(filters),
                values=dict(values),
                matched=len(updated),
            )
        )
        return updated

    # -- storage ------------------------------------------------------------

    def download_object(
        self, bucket: str, object_path: str, destination: Path, *, max_bytes: int | None = None
    ) -> int:
        if self.download_error is not None:
            raise self.download_error
        payload = self.objects.get(object_path, b"fake video bytes")
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes(payload)
        return len(payload)

    def upload_object(
        self, bucket: str, object_path: str, source: Path, *, content_type: str = ""
    ) -> str:
        self.uploads[object_path] = source.read_bytes()
        return object_path

    def upload_bytes(
        self, bucket: str, object_path: str, payload: bytes, *, content_type: str = ""
    ) -> str:
        self.uploads[object_path] = payload
        return object_path

    # -- assertions ---------------------------------------------------------

    def written_columns(self) -> set[str]:
        columns: set[str] = set()
        for call in self.patches:
            columns.update(call.values)
        return columns


def _matches(row: Mapping[str, Any], filters: Mapping[str, str]) -> bool:
    for column, expression in filters.items():
        operator, _, operand = str(expression).partition(".")
        value = row.get(column)
        if operator == "eq":
            if str(value) != operand:
                return False
        elif operator == "neq":
            if str(value) == operand:
                return False
        elif operator == "is":
            if operand == "null" and value is not None:
                return False
            if operand == "not.null" and value is None:
                return False
        elif operator == "lt":
            if value is None or float(value) >= float(operand):
                return False
        elif operator == "gt":
            if value is None or float(value) <= float(operand):
                return False
        else:
            raise AssertionError(f"fake does not implement operator {operator!r}")
    return True


def _sort_key(value: Any) -> tuple[int, float, str]:
    if value is None:
        return (0, 0.0, "")
    if isinstance(value, (int, float)) and not isinstance(value, bool):
        return (1, float(value), "")
    return (2, 0.0, str(value))


def make_row(
    scan_id: str,
    *,
    created_at: int = 1_000,
    updated_at: int | None = None,
    status: str = "pending",
    upload_state: str = "uploaded",
    deleted_at: int | None = None,
    owner_id: str | None = "owner-1",
    wall_id: str = "wall-1",
    video_object_path: str | None = None,
    **extra: Any,
) -> dict[str, Any]:
    row: dict[str, Any] = {
        "id": scan_id,
        "createdAt": created_at,
        "updatedAt": created_at if updated_at is None else updated_at,
        "deletedAt": deleted_at,
        "remoteId": None,
        "dirty": False,
        "ownerId": owner_id,
        "wallId": wall_id,
        "uploadState": upload_state,
        "videoObjectPath": video_object_path
        if video_object_path is not None
        else f"{owner_id}/{scan_id}/source.mp4",
        "durationMs": 30_000,
        "sizeBytes": 12_345_678,
        "status": status,
        "progressPct": None,
        "cloudObjectPath": None,
        "manifestJson": None,
        "failureReason": None,
    }
    row.update(extra)
    return row
