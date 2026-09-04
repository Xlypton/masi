"""Masi rock-scan reconstruction worker.

Turns a climber's phone video of a rock face into a 3D point cloud.

It POLLS the `public.rock_scans` table over Supabase's REST API and never
listens on a port: the primary host is a home gaming PC behind NAT, so there
must be no inbound connection, no public IP and no firewall change. Every
network conversation this process has is one it started.

Layering, outermost first:

* `cli` / `worker`     — the polling loop, signals, backoff.
* `pipeline`           — one job, start to finish.
* `queue`              — the claim protocol and the only writer of the row.
* `frames`, `ply`,
  `manifest`           — pure-ish data steps, unit-testable with no COLMAP.
* `reconstruct.*`      — the ONE replaceable module: frames dir in, poses and
                         points out. Swapping COLMAP for hloc/glomap must not
                         touch anything above it.
"""

WORKER_NAME = "masi-rock-scan-worker"
WORKER_VERSION = "1.0.0"

#: The manifest schema version this worker emits. Must stay in step with
#: `RockScanManifest.currentVersion` in
#: `lib/features/scan/domain/rock_scan_manifest.dart`, which is the
#: authoritative consumer.
MANIFEST_VERSION = 1

__all__ = ["WORKER_NAME", "WORKER_VERSION", "MANIFEST_VERSION"]
