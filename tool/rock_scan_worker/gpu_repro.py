"""Reconstruct a video with the worker's own code, and NOTHING else.

Why this exists. When a scan fails on one machine and succeeds on another, the
worker itself is the worst place to look: a failure there could be the queue,
the network, the service key, the download, ffmpeg, COLMAP, or the box. This
strips all of that away — no Supabase, no job, no polling, no write-back — and
runs only `prepare_frames` + the reconstruction engine on a local file. What
is left when it fails is the actual fault.

It is deliberately the SAME code path the worker uses, not a re-implementation,
so a result here transfers to a result there.

    python gpu_repro.py <video.mp4> <workdir> [auto|on|off]

The third argument is the GPU mode, and running it twice is the whole point:

    python gpu_repro.py capture.mp4 build/repro_gpu on
    python gpu_repro.py capture.mp4 build/repro_cpu off

GPU fails and CPU succeeds  -> the GPU path is at fault. Capture the stderr and
                               widen `_GPU_FAILURE_MARKERS` in
                               reconstruct/colmap.py so `--gpu auto` falls back
                               instead of failing the scan, and add the real
                               string to tests/test_colmap_gpu_fallback.py.
both fail                   -> not the GPU. The stderr says what it is.
both succeed                -> reconstruction is fine standalone; the fault is
                               in the worker's environment (PATH, working
                               directory, or no desktop session for a GPU
                               context when run as a service).

Need a video that is known to reconstruct? `tool/rock_scan_e2e.sh render`
writes one: three textured planes in a dihedral, shot from a camera on a real
arc, which gives SIFT thousands of keypoints and genuine parallax. On Linux
that clip yields 10093 points with 150 of 150 frames registered.
"""

import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))

from rock_scan_worker.config import Config
from rock_scan_worker.frames import prepare_frames
from rock_scan_worker.reconstruct import build_reconstructor
from rock_scan_worker.reconstruct.base import ReconstructionRequest


def main(argv: list[str]) -> int:
    if len(argv) < 3:
        print(__doc__)
        return 2

    video = Path(argv[1])
    if not video.is_file():
        print(f"gpu_repro: no such video: {video}", file=sys.stderr)
        return 1
    work = Path(argv[2])
    work.mkdir(parents=True, exist_ok=True)
    gpu = argv[3] if len(argv) > 3 else "auto"
    if gpu not in ("auto", "on", "off"):
        print(f"gpu_repro: gpu mode must be auto|on|off, got {gpu!r}", file=sys.stderr)
        return 2

    # A url is required by Config but never used: nothing here talks to it.
    config = Config(supabase_url="https://example.invalid", work_dir=str(work), gpu=gpu)
    log = lambda message: print(f"  {message}", flush=True)  # noqa: E731

    started = time.time()
    frames = prepare_frames(video, work / "frames", config=config, log=log)
    print(
        f"frames: {frames.count} kept of {frames.candidates_extracted} extracted "
        f"({time.time() - started:.0f}s)",
        flush=True,
    )

    reconstructor = build_reconstructor(config, log=log)
    reconstructor.preflight()
    started = time.time()
    result = reconstructor.reconstruct(
        ReconstructionRequest(
            frames_dir=frames.frames_dir,
            work_dir=work / "rec",
            frame_count=frames.count,
            progress=lambda done, label: print(f"  [{done * 100:3.0f}%] {label}", flush=True),
            # `auto` and `on` both want the GPU; only `off` refuses it outright.
            use_gpu=(gpu != "off"),
        )
    )
    print(
        f"OK {result.cloud.count} points, {result.frames_registered}/{frames.count} frames "
        f"placed, engine={result.engine} {result.engine_version}, "
        f"used_gpu={result.used_gpu} ({time.time() - started:.0f}s)",
        flush=True,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
