"""Video in, a set of frames worth reconstructing out.

Blind `fps=2` extraction is the single biggest own goal available here.
Handheld phone video of a rock face is full of motion blur, and a blurred
frame does not merely fail to help — it poisons matching, because SIFT finds
keypoints on smear that exist in no other view. It is also full of near
duplicates, from the seconds the climber stood still, and those cost
matching time quadratically while adding no new geometry.

So: extract generously, then choose. Two cheap measures do almost all the
work — variance of the Laplacian for sharpness, and a 16x16 normalised
thumbnail for "have I already seen this". The selection itself
(`select_frames`) is a pure function over those measures, which is why it is
testable with no ffmpeg anywhere in sight.
"""

from __future__ import annotations

import json
import math
import os
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Sequence

import numpy as np

from . import reasons
from .config import Config
from .errors import ScanFailure
from .process import CommandResult, run

#: Edge length of the thumbnail every duplicate comparison happens on.
SIGNATURE_EDGE = 16
#: Edge length of the grayscale image sharpness is measured on. Small on
#: purpose: it makes the measure comparable between phones with wildly
#: different sensor resolutions, and it is 40x faster.
SHARPNESS_EDGE = 320
#: Frames dimmer/flatter than this fraction of the video's MEDIAN sharpness
#: are treated as motion-blurred. Relative, not absolute, because absolute
#: Laplacian variance is meaningless across cameras and lighting.
BLUR_RELATIVE_FLOOR = 0.35
#: How near-duplicate detection is tuned. The distance scale here is video
#: dependent — measured on rendered 36-frame footage of a textured dihedral,
#: SUCCESSIVE frames of a steady pan sit around 0.016 while frames ten apart
#: sit around 0.20 — so a fixed absolute threshold is either useless or
#: catastrophic depending on how fast the climber walked. (An early fixed
#: 0.18 collapsed a perfectly good 36-frame pan to 2 frames.)
#:
#: So the threshold is a FRACTION of this video's own median frame-to-frame
#: distance, floored and capped. Deliberately forgiving: dropping a genuinely
#: novel frame costs coverage of the wall, while keeping a near-duplicate
#: only costs matching time.
DUPLICATE_FRACTION = 0.35
DUPLICATE_DISTANCE_MIN = 0.004
DUPLICATE_DISTANCE_MAX = 0.15


@dataclass(frozen=True)
class VideoInfo:
    duration_s: float
    width: int
    height: int
    fps: float

    @property
    def is_usable(self) -> bool:
        return self.duration_s > 0 and self.width > 0 and self.height > 0


@dataclass(frozen=True)
class FrameCandidate:
    """One extracted still, with the two numbers selection runs on."""

    index: int
    timestamp_s: float
    path: Path
    sharpness: float
    signature: np.ndarray = None  # type: ignore[assignment]


@dataclass(frozen=True)
class FrameSelection:
    frames_dir: Path
    frames: tuple[Path, ...]
    candidates_extracted: int

    @property
    def count(self) -> int:
        return len(self.frames)


# --------------------------------------------------------------------------
# pure measurement + selection (no ffmpeg, no disk beyond reading one image)
# --------------------------------------------------------------------------


def laplacian_variance(gray: np.ndarray) -> float:
    """Variance of a 4-neighbour Laplacian — the standard blur proxy.

    High on crisp rock texture, near zero on smear. Computed by slicing
    rather than a convolution library so this file needs only numpy.
    """
    image = np.asarray(gray, dtype=np.float32)
    if image.ndim != 2 or image.shape[0] < 3 or image.shape[1] < 3:
        return 0.0
    centre = image[1:-1, 1:-1]
    lap = (
        4.0 * centre
        - image[:-2, 1:-1]
        - image[2:, 1:-1]
        - image[1:-1, :-2]
        - image[1:-1, 2:]
    )
    return float(np.var(lap))


def signature_of(gray: np.ndarray) -> np.ndarray:
    """A contrast-normalised thumbnail: 'what does this frame look like'.

    Normalising by standard deviation is what makes the comparison survive
    the auto-exposure ramp every phone does when it pans onto a sunlit face —
    without it, a brightness change reads as new geometry.
    """
    image = np.asarray(gray, dtype=np.float32)
    std = float(image.std())
    if std < 1e-6:
        return np.zeros_like(image, dtype=np.float32)
    return (image - float(image.mean())) / std


def signature_distance(left: np.ndarray, right: np.ndarray) -> float:
    if left is None or right is None:
        return math.inf
    if left.shape != right.shape:
        return math.inf
    return float(np.mean(np.abs(left - right)))


def duplicate_threshold(
    candidates: Sequence[FrameCandidate],
    *,
    fraction: float = DUPLICATE_FRACTION,
    floor: float = DUPLICATE_DISTANCE_MIN,
    ceiling: float = DUPLICATE_DISTANCE_MAX,
) -> float:
    """"Same shot" distance for THIS video, from its own frame-to-frame pace.

    A steady walk past a face and a slow lean into one hold produce distance
    scales an order of magnitude apart, and the only thing that reliably
    tells them apart is the video itself.
    """
    distances = [
        signature_distance(candidates[i].signature, candidates[i + 1].signature)
        for i in range(len(candidates) - 1)
    ]
    finite = [d for d in distances if math.isfinite(d)]
    if not finite:
        return floor
    return float(min(max(fraction * float(np.median(finite)), floor), ceiling))


def select_frames(
    candidates: Sequence[FrameCandidate],
    *,
    budget: int,
    min_frames: int,
    blur_relative_floor: float = BLUR_RELATIVE_FLOOR,
    duplicate_distance: float | None = None,
) -> list[FrameCandidate]:
    """Choose up to `budget` sharp, non-redundant frames, in time order.

    Four passes, in this order for a reason:

    1. Drop the blurred tail, relative to this video's own median.
    2. Collapse near-duplicate runs, keeping the SHARPEST of each run rather
       than the first — standing still and then moving on is exactly when the
       sharpest frame of a cluster is the last one.
    3. If that still leaves more than the budget, thin uniformly ACROSS TIME,
       never by score: a scan that keeps only the sharpest 150 frames is a
       scan of whichever ten seconds happened to be best lit.
    4. Never return fewer than the caller can use — the failure is raised by
       `prepare_frames`, which knows whether the shortfall was blur or a
       three-second video.
    """
    ordered = sorted(candidates, key=lambda c: (c.timestamp_s, c.index))
    if not ordered:
        return []
    if duplicate_distance is None:
        duplicate_distance = duplicate_threshold(ordered)

    sharpnesses = np.array([c.sharpness for c in ordered], dtype=np.float64)
    median = float(np.median(sharpnesses))
    floor = median * float(blur_relative_floor)
    sharp = [c for c in ordered if c.sharpness >= floor]

    # A whole video below its own median floor is impossible; a video where
    # the floor eats too much is not. Back off to the sharpest `min_frames`
    # rather than failing a scan the filter was only supposed to tidy.
    if len(sharp) < min_frames:
        keep_n = min(len(ordered), max(min_frames, 1))
        best = sorted(ordered, key=lambda c: c.sharpness, reverse=True)[:keep_n]
        sharp = sorted(best, key=lambda c: (c.timestamp_s, c.index))

    kept: list[FrameCandidate] = []
    for candidate in sharp:
        if not kept:
            kept.append(candidate)
            continue
        if signature_distance(kept[-1].signature, candidate.signature) < duplicate_distance:
            if candidate.sharpness > kept[-1].sharpness:
                kept[-1] = candidate
            continue
        kept.append(candidate)

    if len(kept) > budget > 0:
        picks = np.linspace(0, len(kept) - 1, num=budget)
        kept = [kept[int(round(i))] for i in picks]
        # linspace can round two neighbours onto one index at tight budgets.
        seen: set[int] = set()
        unique: list[FrameCandidate] = []
        for frame in kept:
            if frame.index in seen:
                continue
            seen.add(frame.index)
            unique.append(frame)
        kept = unique
    return kept


# --------------------------------------------------------------------------
# ffmpeg-facing half
# --------------------------------------------------------------------------


def probe_video(video: Path, config: Config) -> VideoInfo:
    result = run(
        [
            config.ffprobe_bin,
            "-v",
            "error",
            "-print_format",
            "json",
            "-show_format",
            "-show_streams",
            str(video),
        ],
        timeout_s=min(config.subprocess_timeout_s, 120.0),
    )
    if not result.ok:
        raise ScanFailure(reasons.video_unreadable(), detail=result.tail())
    try:
        payload = json.loads(result.stdout or "{}")
    except json.JSONDecodeError:
        raise ScanFailure(reasons.video_unreadable(), detail="probe output was not JSON") from None

    streams = [s for s in payload.get("streams", []) if s.get("codec_type") == "video"]
    if not streams:
        raise ScanFailure(reasons.video_unreadable(), detail="no video stream")
    stream = streams[0]

    duration = _as_float(payload.get("format", {}).get("duration")) or _as_float(
        stream.get("duration")
    )
    info = VideoInfo(
        duration_s=duration or 0.0,
        width=int(stream.get("width") or 0),
        height=int(stream.get("height") or 0),
        fps=_parse_rate(stream.get("avg_frame_rate")) or _parse_rate(stream.get("r_frame_rate")) or 0.0,
    )
    if not info.is_usable:
        raise ScanFailure(reasons.video_unreadable(), detail=f"probe gave {info}")
    return info


def extraction_rate(info: VideoInfo, config: Config) -> float:
    """Frames per second to pull, so we end near `candidate_multiplier` x budget."""
    wanted = max(config.frame_budget, config.min_frames) * max(config.candidate_multiplier, 1.0)
    duration = max(info.duration_s, 0.1)
    rate = wanted / duration
    if info.fps > 0:
        rate = min(rate, info.fps)
    return max(min(rate, 30.0), 0.2)


def _scale_filter(max_edge: int) -> str:
    """Fit inside a `max_edge` box WITHOUT upscaling a smaller video."""
    return (
        f"scale='if(gt(iw,ih),min({max_edge},iw),-2)'"
        f":'if(gt(iw,ih),-2,min({max_edge},ih))':flags=lanczos"
    )


def extract_candidates(
    video: Path,
    out_dir: Path,
    info: VideoInfo,
    config: Config,
    *,
    log: Callable[[str], None] | None = None,
) -> list[Path]:
    out_dir.mkdir(parents=True, exist_ok=True)
    rate = extraction_rate(info, config)
    result: CommandResult = run(
        [
            config.ffmpeg_bin,
            "-hide_banner",
            "-loglevel",
            "error",
            "-nostdin",
            "-i",
            str(video),
            "-vf",
            f"fps={rate:.4f},{_scale_filter(config.frame_max_edge)}",
            "-q:v",
            "2",
            "-f",
            "image2",
            str(out_dir / "cand_%05d.jpg"),
        ],
        timeout_s=config.subprocess_timeout_s,
        log=log,
    )
    frames = sorted(out_dir.glob("cand_*.jpg"))
    if not frames and not result.ok:
        raise ScanFailure(reasons.video_unreadable(), detail=result.tail())
    return frames


def analyse_candidates(paths: Sequence[Path], rate: float) -> list[FrameCandidate]:
    """Measure sharpness and appearance for every extracted still."""
    from PIL import Image  # imported here so the pure helpers need no Pillow

    out: list[FrameCandidate] = []
    for index, path in enumerate(sorted(paths)):
        try:
            with Image.open(path) as image:
                image.draft("L", (SHARPNESS_EDGE, SHARPNESS_EDGE))  # fast JPEG downscale
                gray = image.convert("L")
                sharp_img = gray.resize((SHARPNESS_EDGE, SHARPNESS_EDGE))
                sig_img = gray.resize((SIGNATURE_EDGE, SIGNATURE_EDGE))
                sharpness = laplacian_variance(np.asarray(sharp_img, dtype=np.float32))
                signature = signature_of(np.asarray(sig_img, dtype=np.float32))
        except OSError:
            # A truncated still from a truncated video: skip it, do not fail
            # the whole scan over one frame ffmpeg half-wrote.
            continue
        out.append(
            FrameCandidate(
                index=index,
                timestamp_s=index / rate if rate > 0 else float(index),
                path=path,
                sharpness=sharpness,
                signature=signature,
            )
        )
    return out


def prepare_frames(
    video: Path,
    work_dir: Path,
    config: Config,
    *,
    log: Callable[[str], None] | None = None,
) -> FrameSelection:
    """`probe -> extract -> measure -> select -> lay out`, with real errors."""
    emit = log or (lambda _m: None)
    info = probe_video(video, config)
    emit(
        f"video: {info.width}x{info.height}, {info.duration_s:.1f}s, "
        f"{info.fps:.1f} fps"
    )
    if info.duration_s < config.min_video_duration_s:
        raise ScanFailure(
            reasons.video_too_short(info.duration_s, config.min_video_duration_s)
        )

    candidates_dir = work_dir / "candidates"
    rate = extraction_rate(info, config)
    paths = extract_candidates(video, candidates_dir, info, config, log=log)
    emit(f"extracted {len(paths)} candidate frames at {rate:.2f} fps")
    if len(paths) < config.min_frames:
        raise ScanFailure(reasons.too_few_frames(len(paths), config.min_frames))

    candidates = analyse_candidates(paths, rate)
    if len(candidates) < config.min_frames:
        raise ScanFailure(reasons.too_few_frames(len(candidates), config.min_frames))

    chosen = select_frames(
        candidates, budget=config.frame_budget, min_frames=config.min_frames
    )
    emit(f"selected {len(chosen)} frames of {len(candidates)} after sharpness + dedupe")
    if len(chosen) < config.min_frames:
        raise ScanFailure(reasons.too_blurry(len(chosen), config.min_frames))

    frames_dir = work_dir / "frames"
    frames_dir.mkdir(parents=True, exist_ok=True)
    final: list[Path] = []
    for position, candidate in enumerate(chosen, start=1):
        target = frames_dir / f"frame_{position:05d}.jpg"
        os.replace(candidate.path, target)
        final.append(target)

    # The rejects are the bulk of the bytes on disk and nothing downstream
    # reads them; a long scan session would otherwise fill the drive.
    for leftover in candidates_dir.glob("cand_*.jpg"):
        try:
            leftover.unlink()
        except OSError:
            pass

    return FrameSelection(
        frames_dir=frames_dir,
        frames=tuple(final),
        candidates_extracted=len(candidates),
    )


def _as_float(value: object) -> float | None:
    try:
        out = float(value)  # type: ignore[arg-type]
    except (TypeError, ValueError):
        return None
    return out if math.isfinite(out) and out > 0 else None


def _parse_rate(raw: object) -> float | None:
    if not isinstance(raw, str) or "/" not in raw:
        return _as_float(raw)
    num, _, den = raw.partition("/")
    try:
        numerator, denominator = float(num), float(den)
    except ValueError:
        return None
    if denominator == 0:
        return None
    value = numerator / denominator
    return value if math.isfinite(value) and value > 0 else None


__all__ = [
    "FrameCandidate",
    "FrameSelection",
    "VideoInfo",
    "analyse_candidates",
    "extract_candidates",
    "extraction_rate",
    "laplacian_variance",
    "prepare_frames",
    "probe_video",
    "duplicate_threshold",
    "select_frames",
    "signature_distance",
    "signature_of",
]
