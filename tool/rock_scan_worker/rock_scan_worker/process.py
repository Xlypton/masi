"""Running external binaries, with the failure modes named properly.

Three things every call site would otherwise get wrong: a missing binary is
`FileNotFoundError` on Linux and a `WinError 2` on Windows and both mean
"deployment problem, retry the job elsewhere" rather than "this video is
bad"; a hung COLMAP needs a wall-clock ceiling or the worker never polls
again; and stderr is where every useful diagnostic lives, so it has to be
captured and kept even on success.
"""

from __future__ import annotations

import shutil
import subprocess
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Sequence

from .config import redact
from .errors import ToolMissing, TransientError


@dataclass(frozen=True)
class CommandResult:
    args: tuple[str, ...]
    returncode: int
    stdout: str
    stderr: str

    @property
    def ok(self) -> bool:
        return self.returncode == 0

    def tail(self, lines: int = 12) -> str:
        """The last few stderr lines — what you actually want in a log."""
        text = (self.stderr or self.stdout or "").strip()
        return "\n".join(text.splitlines()[-lines:])

    def first_error_line(self) -> str:
        """The first line that says something, for a one-line log message.

        `tail` is the wrong end when the process crashed: COLMAP prints its
        diagnosis first and then a stack trace, so the last three lines are
        hex addresses and the FIRST line is `qt.qpa.xcb: could not connect
        to display`.
        """
        for line in (self.stderr or self.stdout or "").splitlines():
            stripped = line.strip()
            if stripped and not stripped.startswith(("@", "***", "PC:")):
                return stripped
        return f"exit code {self.returncode}"


def which(binary: str) -> str | None:
    return shutil.which(binary)


def run(
    args: Sequence[str],
    *,
    timeout_s: float,
    cwd: Path | None = None,
    log: Callable[[str], None] | None = None,
    check: bool = False,
) -> CommandResult:
    printable = [str(a) for a in args]
    if log:
        log("run: " + " ".join(printable))
    try:
        completed = subprocess.run(  # noqa: S603 - argv list, never a shell
            printable,
            cwd=str(cwd) if cwd else None,
            capture_output=True,
            text=True,
            errors="replace",
            timeout=timeout_s,
            check=False,
        )
    except FileNotFoundError:
        raise ToolMissing(
            f"{printable[0]!r} is not on PATH on this machine. "
            "Install it (see tool/rock_scan_worker/README.md) or pass an explicit path."
        ) from None
    except PermissionError as exc:
        raise ToolMissing(f"{printable[0]!r} is not executable: {redact(exc)}") from None
    except subprocess.TimeoutExpired:
        raise TransientError(
            f"{printable[0]!r} did not finish within {timeout_s:.0f}s and was killed"
        ) from None

    result = CommandResult(
        args=tuple(printable),
        returncode=completed.returncode,
        stdout=completed.stdout or "",
        stderr=completed.stderr or "",
    )
    if check and not result.ok:
        raise TransientError(
            f"{printable[0]} exited {result.returncode}\n{redact(result.tail())}"
        )
    return result
