"""Reconstruction back ends, and the registry that chooses between them.

Adding one — hloc, glomap, an OpenMVG bridge — means writing a class with
`preflight` and `reconstruct` and adding a line to `_BUILDERS`. Nothing else
in the worker changes, which is the point of the seam.
"""

from __future__ import annotations

from typing import Callable

from ..config import Config
from ..errors import WorkerError
from .base import (
    ProgressFn,
    ReconstructionRequest,
    ReconstructionResult,
    Reconstructor,
)
from .colmap import ColmapReconstructor

Builder = Callable[[Config, Callable[[str], None]], Reconstructor]

_BUILDERS: dict[str, Builder] = {
    "colmap": lambda config, log: ColmapReconstructor(config, log=log),
}


def register_engine(name: str, builder: Builder) -> None:
    """Add a back end at runtime — used by the tests, and by future engines."""
    _BUILDERS[name] = builder


def available_engines() -> list[str]:
    return sorted(_BUILDERS)


def build_reconstructor(
    config: Config, log: Callable[[str], None] | None = None
) -> Reconstructor:
    builder = _BUILDERS.get(config.engine)
    if builder is None:
        raise WorkerError(
            f"unknown reconstruction engine {config.engine!r}; "
            f"available: {', '.join(available_engines())}"
        )
    return builder(config, log or (lambda _m: None))


__all__ = [
    "ProgressFn",
    "ReconstructionRequest",
    "ReconstructionResult",
    "Reconstructor",
    "available_engines",
    "build_reconstructor",
    "register_engine",
]
