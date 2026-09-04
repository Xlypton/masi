# Rock-scan reconstruction worker

Turns a climber's phone video of a rock face into a 3D point cloud.

It **polls** — it claims work from Supabase over ordinary outbound HTTPS and
never listens on a port. That is the design, not a shortcut: the machine this
runs on is a home gaming PC behind NAT, so there is **no inbound connection,
no public IP and no firewall change** anywhere in this document. Unplug the
machine and scans queue up; plug it back in and they drain.

```
phone → uploads video → Storage `rock-scans`
                          ↓            (row: uploadState=uploaded, status=pending)
                     THIS WORKER  ── polls, claims, reconstructs ──►  cloud.ply + manifest
                          ↓            (row: status=ready, cloudObjectPath, manifestJson)
phone ← pulls the row and downloads the cloud
```

---

## 1. Windows setup (the primary target)

Everything below is PowerShell on the box that has the NVIDIA card. The repo
is already checked out at `C:\Projects\masi`.

### 1.1 Python

Python **3.10 or newer** (`python --version`). Then, from this directory:

```powershell
cd C:\Projects\masi\tool\rock_scan_worker
python -m pip install -r requirements.txt
```

Three pure-wheel dependencies (`requests`, `numpy`, `Pillow`) — no compiler
needed. Add `pytest` if you want to run the tests.

### 1.2 COLMAP — take the CUDA build

Download the **CUDA** Windows binary from the COLMAP releases page
(<https://github.com/colmap/colmap/releases>) — the asset is named like
`COLMAP-3.11.1-windows-cuda.zip`. The `-nocuda` zip also runs, on the CPU,
roughly an order of magnitude slower, and cannot do `--dense` at all.

```powershell
# unzip somewhere permanent, e.g. C:\tools\colmap, then put it on PATH:
[Environment]::SetEnvironmentVariable(
  "Path", $env:Path + ";C:\tools\colmap", "User")
```

Open a NEW shell (PATH changes do not reach an already-open one) and check:

```powershell
colmap -h    # prints "COLMAP 3.x ... with CUDA"  ← the "with CUDA" matters
```

If it says `without CUDA`, you have the wrong zip: the worker will still
work, on the CPU, and will say so in its log every run.

### 1.3 ffmpeg

Download a build from <https://www.gyan.dev/ffmpeg/builds/> (the "essentials"
release is enough), unzip to e.g. `C:\tools\ffmpeg`, and add
`C:\tools\ffmpeg\bin` to PATH the same way. Both `ffmpeg` and `ffprobe` must
be on PATH.

### 1.4 Credentials

The worker authenticates as Supabase's **service_role**, which bypasses RLS —
that is precisely why it can write the server-owned columns the app cannot.
Treat it accordingly.

```powershell
# this shell only:
$env:SUPABASE_URL = "https://<project-ref>.supabase.co"
$env:SUPABASE_SERVICE_ROLE_KEY = "<paste the service_role key>"

# or persistently, for your Windows user (survives reboots):
[Environment]::SetEnvironmentVariable(
  "SUPABASE_URL", "https://<project-ref>.supabase.co", "User")
[Environment]::SetEnvironmentVariable(
  "SUPABASE_SERVICE_ROLE_KEY", "<paste the service_role key>", "User")
```

On Linux/macOS:

```bash
export SUPABASE_URL="https://<project-ref>.supabase.co"
export SUPABASE_SERVICE_ROLE_KEY="<paste the service_role key>"
```

> **The key never goes in a file in this repository.** Not in a `.env`, not
> in a config file, not in a commit — the repo's pre-commit scanner
> (`tool/scan_secrets.dart`) will stop you, and a key that reaches GitHub has
> to be rotated, not deleted. The worker reads it from the environment only,
> keeps it out of its own `repr`, and scrubs it from every log line and
> exception message it emits.

### 1.5 Check the setup

```powershell
python -m rock_scan_worker doctor
```

```
OK    SUPABASE_URL           yourproject.supabase.co
OK    SUPABASE_SERVICE_ROLE_KEY set
OK    ffmpeg                 C:\tools\ffmpeg\bin\ffmpeg.exe
OK    ffprobe                C:\tools\ffmpeg\bin\ffprobe.exe
OK    colmap                 C:\tools\colmap\colmap.exe
OK    colmap version         3.11.1
OK    nvidia gpu             NVIDIA GeForce RTX 4070, 566.36
OK    queue                  3 waiting, 0 processing
```

`doctor` prints whether the key is *set*, never any part of its value.

---

## 2. Running it

```powershell
python -m rock_scan_worker run              # poll forever (the normal mode)
python -m rock_scan_worker once             # one scan, then exit
python -m rock_scan_worker once --scan-id <id>          # one specific scan
python -m rock_scan_worker run --dry-run --once         # change nothing
python -m rock_scan_worker run --max-jobs 5             # cron-shaped run
```

`--dry-run` does the whole job — download, frames, reconstruction, PLY,
manifest — and writes **nothing** back: no row update, no upload. The
artifacts are left in the work directory so you can open `cloud.ply` in
MeshLab or CloudCompare and judge it yourself.

Ctrl-C is safe at any point: the claimed row is **released back to the
queue**, not left stuck in `processing`.

Useful flags: `--frame-budget` (default 150), `--max-points` (300000),
`--gpu auto|on|off`, `--dense`, `--poll-interval`, `--stale-timeout`,
`--work-dir`, `--keep-work-dir`, `--engine`.

### Keeping it running

Task Scheduler → Create Task → *Run whether user is logged on or not*,
trigger *At log on* (or *At startup*), action:

| field | value |
|---|---|
| Program | `python` (or the full path to `python.exe`) |
| Arguments | `-m rock_scan_worker run --work-dir D:\rock-scan-work` |
| Start in | `C:\Projects\masi\tool\rock_scan_worker` |

Set the environment variables at **User** scope (§1.4) so the scheduled task
inherits them. Point `--work-dir` at a drive with room: a phone video plus
its extracted frames is comfortably a few GB while a job is in flight.

---

## 3. Verifying the GPU is actually being used

Three independent checks, in increasing order of trustworthiness:

1. **`colmap -h`** must say `with CUDA`.
2. **The worker's own log**, at the start of every reconstruction:
   ```
   colmap: gpu mode 'auto'; attempting GPU
   ```
   If the card cannot be used you get, instead, exactly one line saying so
   and what it is doing about it:
   ```
   colmap: feature extraction could not use the GPU on this machine;
           falling back to CPU (this will be much slower). Reason: ...
   ```
   That fallback is deliberate — a scan finishing slowly beats a queue that
   stops — but if you see it on the gaming PC, something is wrong: check the
   COLMAP build, and check §1.2.
3. **`nvidia-smi` during a run.** While `feature_extractor` or
   `patch_match_stereo` is working, `colmap.exe` should appear in the process
   list with non-trivial GPU memory. A CPU-only run shows nothing there and
   pins several CPU cores instead.

Use `--gpu on` to make a silent CPU fallback an error rather than a slow
night: the job is released back to the queue and the log says why.

For reference, a genuine CPU-only run in CI on 30 frames at 800×600 takes
about 65 seconds end to end; a CUDA box on a real 150-frame scan should be
in the same ballpark or better despite doing five times the work.

---

## 4. Linux / Docker (secondary target)

```bash
docker build -t masi-rock-scan-worker tool/rock_scan_worker
docker run --rm \
  -e SUPABASE_URL -e SUPABASE_SERVICE_ROLE_KEY \
  -v rock-scan-work:/work \
  masi-rock-scan-worker
```

Ubuntu's packaged COLMAP is **CPU-only**; see the comment at the top of the
`Dockerfile` for the two-line change that bases the image on a CUDA COLMAP
image instead, and add `--gpus all`.

---

## 5. What it writes, and what it must never write

The `rock_scans` row has two owners. The app owns the capture half; this
worker owns the result half and **nothing else**:

| worker-owned | meaning |
|---|---|
| `status` | `pending` → `processing` → `ready` \| `failed` |
| `progressPct` | 0–100, also the heartbeat that proves we are alive |
| `cloudObjectPath` | `<ownerId>/<scanId>/cloud.ply` |
| `manifestJson` | the manifest document (below) |
| `failureReason` | a sentence shown verbatim to a climber |

Plus `updatedAt`, which every writer bumps — omit it and no client ever pulls
the change. The client columns (`uploadState`, `videoObjectPath`, `wallId`,
`sizeBytes`, …) are never in a write body: the queue raises before the
request is made, and `tests/test_queue.py` proves it.

This mirrors `serverOwnedSyncColumns` in
`lib/features/backup/data/sync_remote.dart`, which strips exactly these five
columns out of every client push. A test parses that Dart map and fails if
the two ever disagree.

### The claim protocol

Claimable rows are `uploadState = 'uploaded' AND status = 'pending' AND
deletedAt IS NULL`, oldest `createdAt` first. Claiming is a **conditional
update** — `SET status='processing' WHERE id = ? AND status='pending'` — and
zero rows affected means another worker won the race. Never a SELECT then an
UPDATE.

A row left in `processing` whose `updatedAt` is older than `--stale-timeout`
(default 2 hours) becomes claimable again, so a worker that crashes mid-job
cannot wedge a scan forever.

The other half of that is a **background heartbeat**: while the process is
blocked inside a single long COLMAP stage — feature extraction on 150 frames,
or dense MVS — a daemon thread bumps `updatedAt` every 60 seconds. Without
it, a healthy slow job reports nothing for longer than the stale timeout and
gets handed to a second worker, which is the one race the claim protocol
cannot see from the outside: a slow worker and a dead one look identical.

Run as many workers as you like: correctness does not depend on there being
only one.

---

## 6. The manifest

Written to `manifestJson` on the row and to
`<ownerId>/<scanId>/manifest.json` in Storage. The consumer is
`lib/features/scan/domain/rock_scan_manifest.dart` and **that file is
authoritative** — `tests/test_manifest.py` parses it and fails if this worker
stops emitting exactly the keys it reads.

```json
{"version":1,"engine":"colmap","engineVersion":"3.11.1",
 "framesExtracted":150,"framesRegistered":141,"pointCount":248113,
 "boundsMin":[-6.74,-4.54,5.19],"boundsMax":[2.03,5.49,19.89],
 "cameras":[[5.84,0.72,2.05]],"registeredRatio":0.94,
 "meanReprojectionError":0.389,"metresPerUnit":null,"scaleSource":null}
```

`metresPerUnit` is **null** and will stay null until something in the
pipeline measures a real distance. Structure-from-motion recovers geometry
only up to a similarity transform, so the cloud is in arbitrary units; the
app refuses to show measurements while this is null, and a placeholder `1.0`
would make it show confidently wrong ones instead.

The point cloud is a binary little-endian PLY with exactly
`float x, float y, float z, uchar red, uchar green, uchar blue` — 15 bytes
per vertex — capped at `--max-points` (300 000 by default) by uniform random
subsampling so a phone can open it.

---

## 7. When a scan fails

`failureReason` is shown to a climber verbatim, so it is a sentence with a
next step in it, never an exit code. Every string lives in
`rock_scan_worker/reasons.py` and is tested for readability.

| what happened | what the climber sees | row ends as |
|---|---|---|
| video shorter than 3s | "The video is only 2 seconds long. Record at least…" | `failed` |
| too few usable frames | "Only 11 usable still frames came out of this video…" | `failed` |
| mostly motion blur | "Most of the video was too blurry to use…" | `failed` |
| few frames registered | "Only 12 of 150 frames could be lined up with each other…" | `failed` |
| smooth / flat-lit rock | "There was not enough visible detail on the rock…" | `failed` |
| empty reconstruction | "No 3D shape could be recovered from this video…" | `failed` |
| the video object is gone | "The uploaded video could not be found in the cloud…" | `failed` |
| **our network dropped** | *nothing* | back to `pending` |
| **COLMAP/ffmpeg missing** | *nothing* | back to `pending` |
| **worker stopped (Ctrl-C)** | *nothing* | back to `pending` |

The bottom three are infrastructure, not the climber's video: the row is
released and picked up later rather than burned. The one deliberate
exception is an *unexpected* crash — a bug in this worker — which is marked
`failed` with an invitation to retry, because with no attempt counter in the
schema, releasing it would re-claim the same row forever and starve every
scan behind it.

---

## 8. Tests

```bash
cd tool/rock_scan_worker
python -m pytest -q            # add: pip install pytest
```

Everything that does not need COLMAP runs anywhere in about a second: the
claim protocol and its races, stale reclaim, the column-ownership guard,
frame selection, PLY round-tripping, manifest emission against the Dart
contract, failure classification, secret redaction.

`tests/test_integration.py` is the real thing — it renders a synthetic
textured scene, encodes it with ffmpeg, and reconstructs it with COLMAP,
asserting on the artifacts that come out. It **skips itself** when `ffmpeg`
or `colmap` are absent, and takes about 25 seconds when they are not.

`tests/synthetic_scene.py` explains why the scene is three textured planes
seen from a moving camera rather than one of ffmpeg's test patterns: a test
pattern is 2D, so there is no parallax and nothing to reconstruct.

---

## 9. Swapping the reconstruction engine

The COLMAP/SIFT front end is expected to be replaced — hloc with
SuperPoint/SuperGlue matches texture-poor rock far better, and glomap is much
faster — so it lives behind one narrow interface in
`rock_scan_worker/reconstruct/base.py`:

> a directory of frames in, a coloured point cloud and camera positions out.

To add an engine: write a class with `preflight()` and `reconstruct()`,
register it in `reconstruct/__init__.py`, and select it with `--engine`.
Nothing about the queue, Storage, the schema or the CLI changes — that
separation is the whole point of the seam, and `tests/test_pipeline.py`
exercises the pipeline through a fake reconstructor to keep it honest.
