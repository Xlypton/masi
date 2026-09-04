"""Frame selection. Motion blur is the top cause of a failed reconstruction
here, so these tests are about proving the blurred and the redundant get
dropped while coverage of the whole video survives."""

from __future__ import annotations

from pathlib import Path

import numpy as np
import pytest

from rock_scan_worker.config import Config
from rock_scan_worker.frames import (
    FrameCandidate,
    VideoInfo,
    extraction_rate,
    laplacian_variance,
    select_frames,
    signature_distance,
    signature_of,
)

RNG = np.random.default_rng(11)


def textured(seed: int = 0) -> np.ndarray:
    return RNG.integers(0, 255, size=(64, 64)).astype(np.float32)


def blurred(image: np.ndarray) -> np.ndarray:
    """A crude box blur — enough to collapse the Laplacian, which is the
    point: this is what a hand-held pan across a face produces."""
    out = image.copy()
    for _ in range(4):
        out = (
            out
            + np.roll(out, 1, axis=0)
            + np.roll(out, -1, axis=0)
            + np.roll(out, 1, axis=1)
            + np.roll(out, -1, axis=1)
        ) / 5.0
    return out


def candidate(index: int, sharpness: float, signature: np.ndarray) -> FrameCandidate:
    return FrameCandidate(
        index=index,
        timestamp_s=float(index),
        path=Path(f"cand_{index:05d}.jpg"),
        sharpness=sharpness,
        signature=signature,
    )


# -- the measures -----------------------------------------------------------


def test_sharp_frames_score_far_above_blurred_ones():
    sharp = textured()
    assert laplacian_variance(sharp) > laplacian_variance(blurred(sharp)) * 10


def test_a_flat_frame_scores_zero():
    assert laplacian_variance(np.full((32, 32), 128.0)) == pytest.approx(0.0)


def test_a_signature_ignores_a_brightness_change():
    """Phones ramp exposure when they pan onto a sunlit face. That must not
    read as new geometry, or dedupe keeps every frame of the ramp."""
    image = textured()
    assert signature_distance(signature_of(image), signature_of(image + 40.0)) < 1e-5
    assert signature_distance(signature_of(image), signature_of(image * 1.5)) < 1e-5


def test_a_signature_separates_genuinely_different_views():
    assert signature_distance(signature_of(textured()), signature_of(textured())) > 0.5


# -- selection --------------------------------------------------------------


def distinct_signatures(count: int) -> list[np.ndarray]:
    return [signature_of(textured()) for _ in range(count)]


def test_blurred_frames_are_dropped_when_sharp_ones_exist():
    signatures = distinct_signatures(60)
    candidates = [
        candidate(i, 5.0 if i % 2 else 500.0, signatures[i]) for i in range(60)
    ]
    chosen = select_frames(candidates, budget=100, min_frames=10)
    assert chosen, "selection returned nothing"
    assert all(c.sharpness == 500.0 for c in chosen)


def test_near_duplicates_collapse_to_the_sharpest_of_the_run():
    """A climber standing still gives twenty of the same frame. Keeping the
    sharpest of the run, not the first, is what makes that free."""
    same = signature_of(textured())
    candidates = [candidate(i, 100.0 + i, same) for i in range(20)]
    candidates += [candidate(20 + i, 100.0, sig) for i, sig in enumerate(distinct_signatures(20))]
    chosen = select_frames(candidates, budget=100, min_frames=5)
    from_run = [c for c in chosen if c.index < 20]
    assert len(from_run) == 1
    assert from_run[0].index == 19  # the sharpest of the identical run


def test_selection_is_capped_at_the_budget():
    candidates = [candidate(i, 100.0, sig) for i, sig in enumerate(distinct_signatures(400))]
    chosen = select_frames(candidates, budget=150, min_frames=20)
    assert len(chosen) <= 150


def test_thinning_to_the_budget_keeps_the_whole_video_covered():
    """Keeping the 150 sharpest frames would be a scan of whichever ten
    seconds happened to be best lit. Thin across time instead."""
    candidates = [
        candidate(i, 1000.0 if i < 100 else 300.0, sig)
        for i, sig in enumerate(distinct_signatures(400))
    ]
    chosen = select_frames(candidates, budget=100, min_frames=20)
    assert chosen[0].index < 10
    assert chosen[-1].index > 380
    late = [c for c in chosen if c.index >= 100]
    assert len(late) > len(chosen) // 2


def test_output_is_in_time_order():
    candidates = [candidate(i, 100.0 + (i % 7), sig) for i, sig in enumerate(distinct_signatures(50))]
    chosen = select_frames(candidates, budget=30, min_frames=5)
    assert [c.timestamp_s for c in chosen] == sorted(c.timestamp_s for c in chosen)


def test_an_all_blurry_video_still_yields_its_best_frames():
    """The blur floor is relative to this video's own median, so a uniformly
    soft video must not filter itself down to nothing — `prepare_frames`
    decides whether what is left is enough, with a sentence for the climber."""
    candidates = [candidate(i, 1.0 + i * 0.01, sig) for i, sig in enumerate(distinct_signatures(40))]
    chosen = select_frames(candidates, budget=100, min_frames=20)
    assert len(chosen) >= 20


def test_no_candidates_selects_nothing():
    assert select_frames([], budget=100, min_frames=10) == []


# -- extraction rate --------------------------------------------------------


def test_extraction_rate_targets_the_candidate_multiplier():
    config = Config(supabase_url="", frame_budget=150, candidate_multiplier=3.0)
    info = VideoInfo(duration_s=60.0, width=1920, height=1080, fps=30.0)
    rate = extraction_rate(info, config)
    assert 6.0 <= rate <= 9.0  # ~450 candidates over 60 seconds


def test_extraction_rate_never_exceeds_the_source_frame_rate():
    config = Config(supabase_url="", frame_budget=150)
    info = VideoInfo(duration_s=5.0, width=1920, height=1080, fps=24.0)
    assert extraction_rate(info, config) <= 24.0


def test_extraction_rate_survives_a_video_with_no_declared_fps():
    config = Config(supabase_url="", frame_budget=150)
    info = VideoInfo(duration_s=120.0, width=1920, height=1080, fps=0.0)
    assert extraction_rate(info, config) > 0
