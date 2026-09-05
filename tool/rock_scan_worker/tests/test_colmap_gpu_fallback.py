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

#: Verbatim from a real COLMAP 4.2.0 (CUDA) run on Windows, passed the pre-4.0
#: flag name. COLMAP 4.0 renamed `--Sift{Extraction,Matching}.use_gpu` to
#: `--Feature{Extraction,Matching}.use_gpu` when it added non-SIFT extractors
#: (ALIKED, LoMa) — this is a version-skew CLI break, not a missing GPU, and
#: retrying on CPU would fail identically because it is the same unrecognised
#: flag either way.
WINDOWS_COLMAP4_UNRECOGNISED_OPTION_STDERR = (
    "E20260904 20:35:20.298997  6848 base_option_manager.cc:265] "
    "Failed to parse options - unrecognised option '--SiftExtraction.use_gpu'.\n"
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


def test_an_unrecognised_option_is_not_mistaken_for_a_missing_gpu():
    """The pre-4.0 flag name against a 4.x binary is a CLI version mismatch,
    not a GPU problem — falling back to CPU here would just repeat the same
    unrecognised-option error, so this must raise TransientError instead of
    triggering the (useless) CPU retry."""
    assert not _looks_like_gpu_failure(result(1, WINDOWS_COLMAP4_UNRECOGNISED_OPTION_STDERR))


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
    reconstructor = ColmapReconstructor(config, log=logs.append)
    # Pin to a pre-4.0 version so every test below — none of which is about
    # flag-name selection — gets the legacy `Sift*.use_gpu` names without an
    # extra `colmap -h` call (and thus an extra, unexpected `run()` call)
    # sneaking into `calls`. See test_gpu_flag_name_* for the thing this skips.
    reconstructor._version = "3.9.1"
    return reconstructor, calls, logs


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


def test_reports_the_gpu_it_actually_used_not_the_one_it_was_allowed(monkeypatch, tmp_path):
    """`used_gpu` is a diagnostic, so it has to be true.

    It used to be reported as `_gpu_ok`, which only means "the GPU has not
    been proven broken" — so a run that never asked for one still claimed
    it had used it. That is the wrong answer in exactly the case the field
    exists for: comparing a machine whose reconstructions work against one
    whose do not.
    """
    reconstructor, calls, _ = build(monkeypatch, "off", [result(0)])
    reconstructor._feature_extractor(tmp_path / "db", request(tmp_path))
    assert calls[0][-1] == "0", "sanity: this run is CPU-only"
    assert reconstructor._used_gpu is False


def test_a_gpu_step_that_succeeds_is_recorded_as_one(monkeypatch, tmp_path):
    reconstructor, calls, _ = build(monkeypatch, "auto", [result(0)])
    reconstructor._feature_extractor(tmp_path / "db", request(tmp_path))
    assert calls[0][-1] == "1", "sanity: this run asked for the GPU and got it"
    assert reconstructor._used_gpu is True


def test_a_cpu_fallback_is_not_recorded_as_a_gpu_run(monkeypatch, tmp_path):
    reconstructor, _, _ = build(
        monkeypatch, "auto", [result(1, HEADLESS_NO_CUDA_STDERR), result(0)]
    )
    reconstructor._feature_extractor(tmp_path / "db", request(tmp_path))
    assert reconstructor._used_gpu is False, (
        "the work was done on the CPU, however much the GPU was wanted"
    )


@pytest.mark.parametrize(
    "version, extraction_flag, matching_flag",
    [
        ("3.9.1", "SiftExtraction.use_gpu", "SiftMatching.use_gpu"),
        ("4.2.0", "FeatureExtraction.use_gpu", "FeatureMatching.use_gpu"),
        # A version colmap has not shipped yet must still resolve — the
        # comparison is ">= 4.0.0", not "== a version we have seen".
        ("5.0.0", "FeatureExtraction.use_gpu", "FeatureMatching.use_gpu"),
    ],
)
def test_gpu_flag_name_matches_the_installed_colmap_version(
    monkeypatch, tmp_path, version, extraction_flag, matching_flag
):
    """The actual bug: COLMAP 4.0 renamed `Sift*.use_gpu` to `Feature*.use_gpu`
    when it added non-SIFT extractors (ALIKED, LoMa). A worker hard-coded to
    the pre-4.0 name gets `unrecognised option` on a fresh 4.x Windows install
    and TransientError on every attempt — CPU fallback does not help, because
    it is the same unrecognised flag regardless of the value passed."""
    reconstructor, calls, _ = build(monkeypatch, "auto", [result(0)])
    reconstructor._version = version

    reconstructor._feature_extractor(tmp_path / "db", request(tmp_path))
    assert f"--{extraction_flag}" in calls[0]

    calls.clear()
    reconstructor._matcher(tmp_path / "db", request(tmp_path))
    assert f"--{matching_flag}" in calls[0]


def test_gpu_flag_name_falls_back_to_legacy_when_version_is_unknown(monkeypatch, tmp_path):
    """`colmap -h` failing to yield a parseable version must not crash flag
    selection — it should behave exactly as it always has (pre-4.0 names).

    `outcomes[0]` serves the `version()` probe this triggers (empty
    stdout/stderr, so no version parses out of it); `outcomes[1]` serves the
    real `feature_extractor` call.
    """
    reconstructor, calls, _ = build(monkeypatch, "auto", [result(1), result(0)])
    reconstructor._version = None  # undo the pin `build()` sets, to force the probe

    reconstructor._feature_extractor(tmp_path / "db", request(tmp_path))
    assert "--SiftExtraction.use_gpu" in calls[-1]


#: Verbatim from COLMAP 4.2.0 (CUDA) on a GTX 1060 (Pascal, sm_61): the
#: prebuilt release embeds no kernel for that compute capability, so every
#: per-image CUDA call fails — and COLMAP logs it per image and STILL EXITS 0,
#: having extracted nothing. Note it never says "cuda".
PASCAL_NO_KERNEL_IMAGE_STDERR = (
    "E20260904 22:31:09.104881 12044 cuda_check.cc:33] Cannot copy from device: "
    "no kernel image is available for execution on the device\n"
) * 3

#: A HEALTHY CUDA run. Nothing is wrong here, but the text mentions a GPU in
#: the ordinary way a working build does — which is exactly the shape that
#: must not be mistaken for a failure when the command exited 0.
HEALTHY_CUDA_STDOUT = (
    "I20260904 22:31:09.104881 12044 feature_extraction.cc:251] "
    "Creating SIFT GPU feature extractor\n"
    "CUDA device 0: NVIDIA GeForce RTX 4070 (compute 8.9)\n"
    "Processed file [150/150]\n"
)


def test_a_gpu_that_fails_silently_on_exit_zero_still_falls_back(monkeypatch, tmp_path):
    """The second half of the COLMAP 4.x Windows bug, which had no test.

    A CUDA architecture mismatch makes every per-image call fail, but COLMAP
    calls that a warning and exits 0 having processed nothing. Checking the
    markers only on a non-zero exit therefore missed it entirely, and the run
    went on to fail much later in the mapper with a far vaguer message.
    """
    reconstructor, calls, logs = build(
        monkeypatch, "auto", [result(0, PASCAL_NO_KERNEL_IMAGE_STDERR), result(0)]
    )
    reconstructor._feature_extractor(tmp_path / "db", request(tmp_path))

    assert calls[0][-1] == "1", "the first attempt must ask for the GPU"
    assert calls[1][-1] == "0", "and exit 0 must NOT stop the CPU retry"
    assert any("falling back to CPU" in line for line in logs)
    assert reconstructor._used_gpu is False, (
        "a GPU that produced nothing was not the GPU that did the work"
    )


def test_a_healthy_gpu_run_is_not_dropped_to_the_cpu(monkeypatch, tmp_path):
    """The false positive the narrow marker list exists to prevent.

    `cuda`, `display` and `opengl` are ordinary words a working CUDA build
    prints. They are fine as evidence after a non-zero exit — at worst one
    wasted CPU retry — but on exit 0 they are not evidence of anything, and
    acting on them would silently strand a healthy machine on the CPU for the
    rest of the run and every run after it. Nothing would ever report that.
    """
    served = CommandResult(
        args=("colmap",), returncode=0, stdout=HEALTHY_CUDA_STDOUT, stderr=""
    )
    reconstructor, calls, logs = build(monkeypatch, "auto", [served])
    reconstructor._feature_extractor(tmp_path / "db", request(tmp_path))

    assert len(calls) == 1, "a successful GPU run must not be retried at all"
    assert calls[0][-1] == "1"
    assert reconstructor._used_gpu is True
    assert not any("falling back" in line for line in logs)


def test_the_silent_marker_is_still_caught_on_a_normal_failure():
    """Narrowing the exit-0 check must not narrow the exit-non-zero one."""
    assert _looks_like_gpu_failure(result(1, PASCAL_NO_KERNEL_IMAGE_STDERR))
