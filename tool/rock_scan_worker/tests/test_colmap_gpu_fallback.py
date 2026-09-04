"""GPU selection. The box that matters has CUDA; this one does not, and the
worker has to be explicit and survivable either way."""

from __future__ import annotations

import pytest

from rock_scan_worker.config import Config
from rock_scan_worker.errors import TransientError
from rock_scan_worker.process import CommandResult
from rock_scan_worker.reconstruct import colmap as colmap_module
from rock_scan_worker.reconstruct.base import ReconstructionRequest
from rock_scan_worker.reconstruct.colmap import ColmapReconstructor, _looks_like_gpu_failure

#: Verbatim from COLMAP 3.9.1 built without CUDA, on a headless machine: it
#: falls back to SiftGPU over OpenGL and dies on the Qt platform plugin. Note
#: that it never mentions a GPU, which is why matching on "cuda" alone is not
#: enough.
HEADLESS_NO_CUDA_STDERR = (
    "qt.qpa.xcb: could not connect to display \n"
    'qt.qpa.plugin: Could not load the Qt platform plugin "xcb" in "" even though it was found.\n'
    "*** SIGABRT (@0x31c7) received by PID 12743\n"
)


def result(returncode: int, stderr: str = "") -> CommandResult:
    return CommandResult(args=("colmap",), returncode=returncode, stdout="", stderr=stderr)


@pytest.mark.parametrize(
    "stderr",
    [
        HEADLESS_NO_CUDA_STDERR,
        "ERROR: Cannot use GPU without CUDA support",
        "Failed to create OpenGL context",
        "SiftGPU not fully supported",
    ],
)
def test_recognises_every_shape_of_missing_gpu(stderr):
    assert _looks_like_gpu_failure(result(1, stderr))


def test_does_not_mistake_a_real_error_for_a_missing_gpu():
    assert not _looks_like_gpu_failure(result(1, "ERROR: Failed to read image frame_00007.jpg"))


def build(monkeypatch, gpu: str, outcomes: list[CommandResult]) -> tuple[ColmapReconstructor, list[list[str]], list[str]]:
    calls: list[list[str]] = []
    logs: list[str] = []
    served = 0

    def fake_run(args, **kwargs):
        # Counted separately from `calls`, which tests clear to isolate a
        # later stage.
        nonlocal served
        calls.append(list(args))
        outcome = outcomes[min(served, len(outcomes) - 1)]
        served += 1
        return outcome

    monkeypatch.setattr(colmap_module, "run", fake_run)
    config = Config(supabase_url="", gpu=gpu)
    return ColmapReconstructor(config, log=logs.append), calls, logs


def request(tmp_path) -> ReconstructionRequest:
    return ReconstructionRequest(
        frames_dir=tmp_path / "frames", work_dir=tmp_path / "rec", frame_count=30
    )


def test_auto_falls_back_to_cpu_and_says_so(monkeypatch, tmp_path):
    reconstructor, calls, logs = build(
        monkeypatch, "auto", [result(1, HEADLESS_NO_CUDA_STDERR), result(0)]
    )
    reconstructor._feature_extractor(tmp_path / "db", request(tmp_path))
    assert calls[0][-1] == "1", "the first attempt must ask for the GPU"
    assert calls[1][-1] == "0", "the retry must be on the CPU"
    assert any("falling back to CPU" in line for line in logs)
    assert any("slower" in line for line in logs)


def test_the_cpu_decision_sticks_for_later_steps(monkeypatch, tmp_path):
    """Re-probing the GPU on every stage would waste a minute per scan and
    fill the log with the same failure three times."""
    reconstructor, calls, _ = build(
        monkeypatch, "auto", [result(1, HEADLESS_NO_CUDA_STDERR), result(0)]
    )
    reconstructor._feature_extractor(tmp_path / "db", request(tmp_path))
    calls.clear()
    reconstructor._matcher(tmp_path / "db", request(tmp_path))
    assert calls[0][-1] == "0"


def test_gpu_off_never_asks_for_one(monkeypatch, tmp_path):
    reconstructor, calls, _ = build(monkeypatch, "off", [result(0)])
    reconstructor._feature_extractor(tmp_path / "db", request(tmp_path))
    assert calls[0][-1] == "0"
    assert len(calls) == 1


def test_gpu_on_refuses_the_silent_cpu_fallback(monkeypatch, tmp_path):
    """A CUDA box that quietly drops to CPU turns a 4-minute scan into an
    hour, so `--gpu on` makes that loud instead."""
    reconstructor, _, _ = build(monkeypatch, "on", [result(1, HEADLESS_NO_CUDA_STDERR)])
    with pytest.raises(TransientError) as caught:
        reconstructor._feature_extractor(tmp_path / "db", request(tmp_path))
    assert "gpu" in str(caught.value).lower()


def test_a_non_gpu_failure_is_transient_not_a_scan_failure(monkeypatch, tmp_path):
    reconstructor, _, _ = build(monkeypatch, "auto", [result(2, "ERROR: database is locked")])
    with pytest.raises(TransientError):
        reconstructor._feature_extractor(tmp_path / "db", request(tmp_path))
