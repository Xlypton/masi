<p align="center">
  <img src="assets/icons/masi/masi_boulder_logo.svg" alt="Masi logo" width="200">
</p>

# Masi

A local-first Flutter app for climbers to **document, browse, and share** rock-climbing
routes. The core is a **visual-first topo editor**: photograph a rock face, optionally
slice a panorama into wall segments, and draw route lines directly onto the photo on a
zoomable canvas. Route lines are stored as vector (percentage-based) coordinates, not
burned into the image, so they stay zoomable, tappable, and re-projectable across
slices and screen sizes. Full product spec: [`MASI.md`](MASI.md).

**iOS is the primary target.** Data is local-first (Drift/SQLite), with an optional
Supabase backend for auth, cross-device sync, and the community features below.

## Features

- Photo ingestion, panorama slicing, and a pinch/zoom/pan topo canvas for drawing
  route lines, symbols, and multi-pitch markers directly on a photo.
- Area → Sector → Wall organization with full offline CRUD.
- Grade systems (French, UIAA), route metadata, beta video links, style tags, stars.
- Cloud sync (push/pull, tombstoned soft-deletes), a community map + feed for shared
  topos, comments, likes, and a personal ascent logbook.
- An AR route viewer (iOS only, ARKit) that drapes stored route lines over the live
  camera feed via planar image alignment.
- **Web/PWA (in progress):** a browser build of the same app is being ported behind
  conditional imports (native code paths are untouched). See the **Web (PWA)**
  section below.

## Toolchain

Flutter 3.44.2, Dart 3.12.2, Xcode 26.6. This is a Homebrew Flutter install, so
prefix every `flutter`/`dart`/`pod`/`xcrun` command with:

```bash
export PATH="/opt/homebrew/bin:$PATH"
```

iOS uses Swift Package Manager, not CocoaPods — there is intentionally no
`ios/Podfile`.

## Build & test

```bash
export PATH="/opt/homebrew/bin:$PATH" && flutter pub get
export PATH="/opt/homebrew/bin:$PATH" && flutter analyze     # must be 0 issues
export PATH="/opt/homebrew/bin:$PATH" && flutter test        # unit + widget tests, must be green
```

Run on iOS Simulator or a physical device the usual way (`flutter run`), or drive the
scripted UI flows under `integration_test/` with `flutter drive` (see `CLAUDE.md` for
the full simulator/screenshot verification loop).

## Web (PWA)

The web port lives behind `dart.library.io` / `dart.library.js_interop` conditional
imports (DB connection, photo byte-storage, image ops, AR support) so the native app
is unaffected. Persistence uses Drift's `WasmDatabase` (SQLite compiled to WASM,
IndexedDB-backed via `idb_shim`); photos are stored as bytes rather than files on
disk. AR is grayed out on web (no WebXR yet) since there is no ARKit equivalent in
the browser.

Build and gate-check the web bundle with:

```bash
export PATH="/opt/homebrew/bin:$PATH" && tool/build_web.sh          # wasm build (default)
export PATH="/opt/homebrew/bin:$PATH" && tool/build_web.sh --gate    # gate checks only, no build
export PATH="/opt/homebrew/bin:$PATH" && tool/build_web.sh --js      # legacy JS/CanvasKit build
```

`tool/build_web.sh` enforces that no `dart:io` import leaks into the web bundle
outside a `*_native.dart` file, and checks the pinned `sqlite3.wasm`/
`drift_worker.js` assets under `web/` are current with the resolved `drift` version.
Serving the build requires cross-origin isolation headers (`COOP`/`COEP` +
`application/wasm` content-type) — see [`HOSTING.md`](HOSTING.md) for ready-made
Cloudflare Pages (`web/_headers`) and Firebase Hosting (`firebase.json`) configs.

The headline web feature is **shareable, read-only topo links**: a shared wall's topo
can be opened by anyone via a plain URL (`/community/topo/:wallId`), with no account
needed to view it — the same visual topo canvas used for editing, rendered read-only
in the browser.

Deferred web-port work (things intentionally left for later, not blockers) is tracked
in [`docs/web-port-backlog.md`](docs/web-port-backlog.md).

## Project docs

- [`MASI.md`](MASI.md) — full product/architecture spec.
- [`CLAUDE.md`](CLAUDE.md) — project instructions, toolchain quirks, verification loop.
- [`DESIGN.md`](DESIGN.md) — visual/design language.
- [`ICONS-README.md`](ICONS-README.md) — masi icon set (MasiIcon usage, generation, migration map).
- [`WEB_PORT_BRIEF.md`](WEB_PORT_BRIEF.md) — planning brief for the web port.
- [`HOSTING.md`](HOSTING.md) — PWA hosting/header requirements.
- [`docs/USER_STORIES.md`](docs/USER_STORIES.md) — user stories.
- [`docs/DESIGN_RUBRIC.md`](docs/DESIGN_RUBRIC.md) — design review rubric.
- [`docs/web-port-backlog.md`](docs/web-port-backlog.md) — deferred post-web-port items.
