# Web Port Backlog (post-M2)

The ClimbTopo web/PWA port has shipped its core milestones — Drift persistence on
`WasmDatabase`, the photo byte-store pipeline (IndexedDB via `idb_shim`), thumbnail
generation, AR gray-out, and PWA scaffolding/hosting are all in on `main` (see
`WEB_PORT_BRIEF.md` and the `feat(web): ... (Phase N)` commits). This document tracks
items that were **deliberately deferred** past that initial push so they aren't lost —
things worth doing later, not blockers for the web build to be usable today. Nothing
here blocks shipping; pull items off this list as they become worth the effort.

## Backlog

- [ ] **Browser-executed Drift + byte-store tests.** The existing test suite currently
      runs against the Dart VM (`NativeDatabase.memory()`) or an in-memory fake byte
      store —
      none of them actually exercise `WasmDatabase`/IndexedDB inside a real browser
      engine. Add a `flutter test -d chrome` (or equivalent headless-Chrome) lane so
      WASM-specific bugs (worker startup, OPFS/IndexedDB fallback, asset path
      resolution) get caught before a real user hits them.

- [ ] **OPFS byte-store backend.** The photo byte store is IndexedDB-only today
      (`idb_shim`). Origin Private File System (OPFS) is faster and avoids IndexedDB's
      structured-clone overhead for large blobs, but needs browser-support gating
      (Safari/older browsers lack it) and a fallback path. Worth revisiting once
      IndexedDB proves to be a real perf bottleneck, not before.

- [ ] **`beforeunload`/`visibilitychange`-triggered sync push.** Native pushes on
      `AppLifecycleState.paused`; the web has no exact equivalent — a closed tab or
      navigated-away browser today just waits for the next debounced push. Wire a
      best-effort push on `visibilitychange`/`beforeunload` so a user who closes the
      tab right after drawing a route doesn't lose the sync window. Best-effort only:
      neither event guarantees the async push actually completes before teardown.

- [ ] **Leader-tab election / Web Locks for multi-tab sync.** Today nothing stops two
      tabs of the same account both running the sync orchestrator concurrently. Not
      known to have caused a real race yet (WASM sqlite serializes writes per tab via
      its own worker). Only build a Web Locks–based leader election if multi-tab usage
      actually surfaces a race in practice — speculative hardening otherwise.

- [ ] **Canvas undo keyboard shortcuts (desktop).** The topo canvas undo/redo is
      currently button-only; desktop/browser users expect `Cmd/Ctrl+Z` /
      `Cmd/Ctrl+Shift+Z`. Part of the broader "desktop interaction model" gap
      (no scroll-wheel zoom, no click-drag pan) called out in `WEB_PORT_BRIEF.md` §7;
      undo shortcuts specifically are cheap and worth doing standalone before the full
      responsive/desktop-input pass.

- [ ] **Sentry for Flutter web.** No crash/error reporting is wired for the web target
      (native has none configured either, per current grep — this is net-new for web
      too). Add `sentry_flutter` web support once real browser traffic hits
      production; not worth the setup cost while the web port is still
      internally-verified only.

- [ ] **dart2wasm plugin-blocker re-check on plugin upgrades.** `tool/build_web.sh`
      defaults to `--wasm` (dart2wasm compilation, not just the Skia renderer), which
      only works because every plugin in the dependency graph today happens to use
      `dart:js_interop` rather than the legacy `dart:js`/`dart:html` (which dart2wasm
      cannot compile). This is a fragile balance — re-run `tool/build_web.sh` (or at
      minimum `tool/build_web.sh --gate`) after every plugin version bump to catch a
      newly-introduced `dart:html`/`dart:js` dependency before it silently breaks the
      wasm build; fall back to `--js` only as a last resort.

- [ ] **WebXR (someday).** True in-browser AR (WebXR Device API) as a real alternative
      to the native ARKit viewer. Large effort, no browser-AR story today beyond the
      gray-out placeholder; explicitly a someday/maybe, not a near-term item.

## Notes (already resolved, kept here to prevent re-litigating)

- **Thumbnail generation IS implemented.** `lib/features/topo/data/image_ops/` (native
  + web variants) already generates thumbnails on both platforms — this is not an open
  item, despite earlier planning docs treating it as a gap.
- **OPFS-backed cropping is not needed.** Wall photo slices are stored as
  crop-percentages against the original image (`Photos.kind == slice` +
  crop-rect fields), never as a separately re-encoded image file. There is no
  pixel-level crop/re-encode step on web that would need an OPFS scratch area — the
  percentage-based model that makes slices zoomable/reprojectable on native carries
  over to web unchanged.
