"""`failureReason` is rendered verbatim on a phone, next to a scan somebody
walked to a crag to record. These tests hold the whole vocabulary to that."""

from __future__ import annotations

import inspect

import pytest

from rock_scan_worker import reasons
from rock_scan_worker.reasons import FORBIDDEN_SUBSTRINGS

SAMPLE_ARGS = {
    "video_too_short": (2.0, 3.0),
    "too_few_frames": (11, 20),
    "too_blurry": (4, 20),
    "not_enough_overlap": (12, 150),
    "too_few_points": (37,),
    "engine_kept_failing": (3,),
}


def all_reasons() -> dict[str, str]:
    out = {}
    for name, function in vars(reasons).items():
        if name.startswith("_") or not inspect.isfunction(function):
            continue
        out[name] = function(*SAMPLE_ARGS.get(name, ()))
    return out


def test_there_is_a_sentence_for_every_failure_mode_we_map():
    names = set(all_reasons())
    assert {
        "video_too_short",
        "video_unreadable",
        "video_missing",
        "too_few_frames",
        "too_blurry",
        "not_enough_overlap",
        "texture_poor_rock",
        "reconstruction_empty",
        "too_few_points",
        "unexpected",
        "engine_kept_failing",
    } <= names


@pytest.mark.parametrize("name,text", sorted(all_reasons().items()))
def test_every_reason_reads_like_a_sentence_to_a_person(name, text):
    assert text[0].isupper(), f"{name} does not start a sentence"
    assert text.rstrip().endswith("."), f"{name} does not end one"
    assert 40 <= len(text) <= 400, f"{name} is {len(text)} characters"
    assert "\n" not in text


@pytest.mark.parametrize("name,text", sorted(all_reasons().items()))
def test_no_reason_leaks_an_internal(name, text):
    for forbidden in FORBIDDEN_SUBSTRINGS:
        assert forbidden not in text, f"{name} leaks {forbidden!r} to a climber"


@pytest.mark.parametrize("name,text", sorted(all_reasons().items()))
def test_every_reason_tells_the_climber_something_actionable(name, text):
    """Not decoration: "reconstruction failed" with no next step is exactly
    the message that makes someone drive back to the crag and repeat the
    same mistake."""
    hints = ("try", "record", "film", "move", "upload", "again", "slowly")
    assert any(hint in text.lower() for hint in hints), f"{name} offers no next step"


def test_the_numbers_in_a_reason_are_the_real_ones():
    assert "12 of 150" in reasons.not_enough_overlap(12, 150)
    assert "2 seconds" in reasons.video_too_short(2.0, 3.0)
    assert "37 points" in reasons.too_few_points(37)
