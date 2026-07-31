#!/usr/bin/env python3
"""Static server for build/web that applies (or deliberately omits) the
cross-origin-isolation headers Cloudflare Pages sets from `web/_headers`.

Why this exists: `flutter drive` has no `--web-header` flag, so the
`-d web-server` device used by `tool/drive_web.sh` can never send COOP/COEP.
Without cross-origin isolation there is no SharedArrayBuffer, drift's probe
never offers `opfsLocks`, and the OPFS half of §1a's
`moveExistingIndexedDbToOpfs: true` is unreachable in CI. This script is how
that half gets proven on real Chrome before shipping.

Proving the move (run all of it from the repo root):

  tool/build_web.sh
  # 1. Serve WITHOUT isolation so drift lands on IndexedDB, then seed a topo.
  python3 tool/serve_web_isolated.py 8087 --no-coop
  #    open http://localhost:8087 in Chrome, sign in, create a topo,
  #    and confirm the console logs `masi/storage: backend=...IndexedDb`.
  #    Stop the server (ctrl-C).
  # 2. Serve WITH isolation on the SAME PORT (same origin == same stored
  #    databases; a different port is a different origin and proves nothing).
  python3 tool/serve_web_isolated.py 8087
  #    reload http://localhost:8087. Expected:
  #      - DevTools console: `masi/storage: backend=opfsLocks durable=true`
  #      - `crossOriginIsolated` is true in the console
  #      - the topo seeded in step 1 is STILL THERE
  #      - Application > Storage shows the IndexedDB `climbtopo` database gone
  #    That is the IndexedDB -> OPFS migration completing without data loss.
"""
import functools
import http.server
import mimetypes
import os
import sys

# Chrome refuses `WebAssembly.instantiateStreaming` on anything that is not
# application/wasm, and Python's mimetypes does not always know .wasm.
mimetypes.add_type("application/wasm", ".wasm")
mimetypes.add_type("application/javascript", ".js")


class Handler(http.server.SimpleHTTPRequestHandler):
    isolated = True

    def end_headers(self):
        if self.isolated:
            # Mirrors web/_headers' `/*` block.
            self.send_header("Cross-Origin-Opener-Policy", "same-origin")
            self.send_header("Cross-Origin-Embedder-Policy", "require-corp")
            self.send_header("Cross-Origin-Resource-Policy", "same-origin")
        self.send_header("Cache-Control", "no-cache")
        super().end_headers()


def main() -> int:
    args = sys.argv[1:]
    isolated = "--no-coop" not in args
    ports = [a for a in args if a.isdigit()]
    port = int(ports[0]) if ports else 8087
    root = os.path.normpath(
        os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "build", "web")
    )
    if not os.path.isdir(root):
        print("FAIL: build/web not found — run tool/build_web.sh first", file=sys.stderr)
        return 2
    Handler.isolated = isolated
    handler = functools.partial(Handler, directory=root)
    print(
        f"serving {root} on http://localhost:{port} "
        f"(cross-origin isolated: {isolated})"
    )
    http.server.ThreadingHTTPServer(("127.0.0.1", port), handler).serve_forever()
    return 0


if __name__ == "__main__":
    sys.exit(main())
