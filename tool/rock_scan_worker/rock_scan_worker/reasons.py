"""Every sentence a climber can be shown when a scan does not work.

`failureReason` is rendered verbatim on a phone, next to a scan the person
walked to a crag to record. So each string here says what happened in plain
language and, where there is one, what to do differently next time. No exit
codes, no exception class names, no "COLMAP mapper produced 0 models".

Centralised in one module so the tests can assert the whole set stays
human — see `tests/test_reasons.py`, which fails on a stack-trace-shaped
string, a bare error code, or a missing full stop.
"""

from __future__ import annotations

#: Words that betray a leaked internal — asserted against in the tests.
FORBIDDEN_SUBSTRINGS = (
    "Traceback",
    "Exception",
    "returncode",
    "stderr",
    "None",
    "COLMAP",
    "colmap",
    "ffmpeg",
    "HTTP",
)


def video_too_short(duration_s: float, minimum_s: float) -> str:
    return (
        f"The video is only {duration_s:.0f} seconds long. "
        f"Record at least {minimum_s:.0f} seconds, walking slowly across the "
        "face so each part is seen from several angles."
    )


def video_unreadable() -> str:
    return (
        "The video could not be read. It may have been cut short while "
        "recording — try filming it again."
    )


def video_missing() -> str:
    return (
        "The uploaded video could not be found in the cloud. Upload it again "
        "from the scan's page."
    )


def too_few_frames(extracted: int, needed: int) -> str:
    return (
        f"Only {extracted} usable still frames came out of this video, and at "
        f"least {needed} are needed. Film a longer, slower pass across the "
        "face, so there is more of it to work from."
    )


def too_blurry(kept: int, needed: int) -> str:
    return (
        f"Most of the video was too blurry to use — only {kept} sharp frames "
        f"of the {needed} needed. Move the phone slowly and steadily, and "
        "avoid filming into bright sun or in fading light."
    )


def not_enough_overlap(registered: int, extracted: int) -> str:
    return (
        f"Only {registered} of {extracted} frames could be lined up with each "
        "other. Move more slowly across the face and keep the camera pointed "
        "at the rock, so each moment of the video overlaps the one before it."
    )


def texture_poor_rock() -> str:
    return (
        "There was not enough visible detail on the rock to match one frame "
        "to the next — very smooth or evenly lit faces are hard to map. Try "
        "again in side light, when shadows pick out the texture."
    )


def reconstruction_empty() -> str:
    return (
        "No 3D shape could be recovered from this video. Film a slow, steady "
        "pass across the whole face, keeping a good arm's length of movement "
        "between where you start and where you finish."
    )


def too_few_points(points: int) -> str:
    return (
        f"The reconstruction produced only {points} points, too few to show "
        "as a face. Film a slower pass with more overlap between frames."
    )


def unexpected() -> str:
    return (
        "Something went wrong while building the 3D model of this scan. The "
        "video is still stored — you can try running it again."
    )
