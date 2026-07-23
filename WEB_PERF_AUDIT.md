# Masi — Web Performance Audit (2026-07-23)

Complaint: **sluggish animations + poor performance on web (skwasm PWA)**. Five read-only
investigation agents swept render cost, widget rebuilds, image pipeline, startup/data-layer,
and build/hosting config. Live prod (`https://climb-masi.pages.dev`) was checked directly.

**Infra is NOT the cause.** Renderer (dart2wasm/skwasm with a canvaskit fallback) and
COOP/COEP headers are correctly configured and verified live (`crossOriginIsolated == true`).
The interactive jank is in **Dart widget code**; the load-time cost is in **boot sequencing +
cache headers**. Prioritized below; each item has `file:line` and a concrete fix.

---

## P0 — root causes of the sluggishness

### A. Blur chrome is everywhere and stacks over moving content (skwasm's most expensive op)
`GlassChrome` (`lib/features/topo/presentation/canvas_chrome.dart:128-141`) wraps an
`ImageFilter.blur` (sigma 18/30) and is the app's universal floating-chrome material:
- **Nav bar** — `lib/app/nav_shell.dart:93`, permanently on all 3 tabs, `extendBody:true`, blurring whatever scrolls under it.
- **Topo canvas** — up to **4–5 simultaneous** blurs over the photo the user is actively pinch/pan/drawing on: title pill `topo_canvas_screen.dart:1088`, bottom action cluster `:1499`, expanded legend `:1801`, collapsed legend chip `:1877`, symbol palette `symbol_palette_bar.dart:108`.
- **AR** — `_ArStatus` pill `ar_screen.dart:1047`, blurring a **continuously-updating live camera feed** every frame; worse, it sits over an `HtmlElementView` DOM `<video>` (`ar_camera_view_web.dart:141`) that `BackdropFilter` can't cheaply/correctly sample on web.
- Bonus waste: `GlassChrome`'s `BoxShadow` (blurRadius 24) is painted **inside** the `ClipRRect` that bounds it (`canvas_chrome.dart:113-141`), so the shadow blur is computed then clipped away — pure wasted paint on nearly every chrome element.

**Fix:** on web (`kIsWeb`), swap `GlassChrome`'s `BackdropFilter` for a solid/translucent
`MasiColors.chrome`-tinted container at the one shared call site (every consumer inherits it).
iOS keeps the real glass. Move/drop the clipped `BoxShadow`.

### B. The whole draw screen + legend rebuild on every pointer-move while drawing a route
`DrawState` (`lib/features/topo/application/draw_controller.dart`) has **no `operator==`**, and
`addPoint()` does `copyWith(currentPoints:[...])` on every pointer sample → a new object → every
watcher notified dozens of times/sec. Two large consumers watch the **whole** object but read
only a few fields:
- `topo_canvas_screen.dart:925` — top-level screen `build()` (reads only `.mode/.routes/.activePhotoId/.selectedRouteId/.switchTargetPhotoId`, never `.currentPoints`).
- `route_legend.dart:159` — embedded legend `ListView.builder` (reads only `.routes/.selectedRouteId`).

Only `TopoCanvas`'s `CustomPaint` legitimately needs per-point repaint. The pattern is already
solved in the same feature — `symbol_palette_bar.dart:102` uses `.select`.

**Fix:** `ref.watch(drawControllerProvider(id).select((s) => (s.mode, s.routes, …)))` (Dart
records have structural `==`) at both sites; optionally add `operator==` to `DrawState`.

### C. Full synchronous JPEG decode on every photo attach (main-thread freeze)
`extractGpsFromImageBytes` (`lib/core/location/photo_gps.dart:37`) calls `img.decodeImage(bytes)`
— a full pure-Dart pixel decode of the **original** 12MP photo — just to read 2 EXIF GPS tags,
then discards the pixels. Awaited synchronously (no isolate; `compute()` is a no-op on web) from
`topo_canvas_gps.dart:83`, called on every attach/replace (`topo_canvas_screen.dart:633`) and new
topo (`topos_screen.dart:496`). Freezes the web main thread for hundreds of ms–seconds.

**Fix:** read EXIF without decoding pixels — `package:exif` (parses APP1/TIFF IFD directly) or a
marker scan to the first `Exif\0\0` segment. Removes ~100% of the cost on every platform.

### D. Zero `RepaintBoundary` in the entire codebase
Confirmed by grep — the string never appears in `lib/`. The topo `CustomPaint`
(`topo_canvas.dart:1002,1028`), AR overlay (`ar_screen.dart:891`), and every shimmer tile share
paint/composite scope with their expensive neighbors (decoded photo, live camera). So a
frequent canvas/overlay repaint forces re-composite of siblings that didn't change.

**Fix:** wrap each `CustomPaint`/animated widget in its own `RepaintBoundary`. Lowest-risk,
high-value change in the audit.

---

## P1 — notable, compounding

- **Full-dataset sync pull, no delta, per-row DB writes** — `sync_remote.dart` (`fetchOwnRows`/`fetchSharedTopos`/`fetchSharedAscents`, no `updatedAt>since` watermark, no pagination) + `backup_repository.dart:63-88` `importSnapshot` loops `await insertOnConflictUpdate` per row (no `db.batch()`). Every sign-in/resume/refresh re-fetches everything and re-imports row-by-row. **Fix:** batch imports via `db.batch`, add incremental watermark, paginate shared. *(Architectural — own effort, higher risk.)*
- **Pull auto-triggers a redundant full push ~2s later** — `sync_orchestrator.dart:159` `db.tableUpdates().listen(_scheduleDebouncedPush)` can't tell a pull's own writes from a user edit, so `pushOwn()` re-reads/re-`toJson()`s all 9 own tables right after a pull. **Fix:** flag sync-originated writes so they don't re-trigger push.
- **Boot blocks first paint** — `main.dart:49,72-74` awaits `Supabase.initialize()` (network) **and** `warmDocsPath()` (a no-op on web) before `runApp()`. **Fix:** don't gate `runApp` on `Supabase.initialize`; surface auth-restore-pending as app state.
- **Blanket `no-cache` on 4–7 MB binaries** — `web/_headers:32-36`. `main.dart.wasm` (4.2 MB), `sqlite3.wasm`/`drift_worker.js` (already hand-versioned in `.drift_asset_versions`) all pay a conditional-GET round trip every load. **Fix:** carve `Cache-Control: public, max-age=31536000, immutable` for the versioned assets; keep the unversioned shell on no-cache.
- **No code-splitting** — `router.dart:10-13` imports `ArScreen`/`CommunityScreen`/`CommunityMapScreen` + `flutter_map`/`geolocator` into the one initial bundle; `deferred as` used nowhere. **Fix:** `deferred as` + `loadLibrary()` for AR and map routes.
- **Community detail rebuilds whole screen (incl. embedded canvas) on any like/comment** — `community_topo_detail_screen.dart:195-219` watches like/comment/route/name providers together; comments built eagerly via `SliverChildListDelegate` (`:385-424`; same in `ascent_detail_screen.dart:184`). **Fix:** push like-row + comments into small child `Consumer`s; lazy `SliverList.builder`.
- **Feed query over-broad `readsFrom`** — `community_repository.dart:344-352` includes `likes`+`comments`, so any like/comment **anywhere** re-runs the whole shared-topo join and re-renders the feed. **Fix:** drop `likes`/`comments` from `readsFrom`; source counts from the existing per-wall `.family` providers. (Same shape, smaller blast radius: `library_crud_repository.dart:867-874`.)
- **Shimmer = one repeating ticker per loading tile, no RepaintBoundary** — `masi_shimmer.dart:47-49`, used per thumbnail in `topos_row.dart:619`/`community_feed_screen.dart:1013`. **Fix:** wrap in `RepaintBoundary`; consider one shared ticker.
- **Sequential photo upload/download in sync** — `sync_service.dart:329-365,584-602`, one `await` per photo. **Fix:** bounded-concurrency `Future.wait` (chunks of 4–8).
- **`_MapView.build()` recomputes filter/merge/dedupe lists every rebuild** — `community_map_screen.dart:596-695`. **Fix:** hoist into a `Provider` like `sortedByProximityToposProvider` already does.

---

## P2 — smaller / defense-in-depth

- **Missing `cacheWidth/cacheHeight` on photo-strip thumbs** — `photo_strip.dart:161-171` decodes 512px thumbs for 52px tiles (~11× overdraw). Match `topos_row.dart:616`.
- **Enable const lints** — `analysis_options.yaml` only has `prefer_const_constructors_in_immutables`; add `prefer_const_constructors` + `prefer_const_literals_to_create_immutables` so `analyze` catches call-site const misses (bigger element-reuse win on web).
- **Feed rows lack item-level `Key`** — `community_feed_screen.dart:295-300` (key is 2 levels down). Add `key: ValueKey(topo.wallId)` on the `itemBuilder` widget.
- **Boot: `runApp` shell-first / preload hints** — `web/index.html:127` no `preload`/`modulepreload` for `main.dart.wasm`.
- **Untuned image cache** — `main.dart` leaves default 100 MB; a 12MP canvas photo is ~30–50 MB decoded. Set explicitly as defense-in-depth.
- **AR overlay `saveLayer` alpha pass** (`ar_overlay_painter.dart:130-146`) + **per-symbol `saveLayer`** (`topo_painter.dart:511-536`) — offscreen composites; low real-world impact, gate on web if needed.
- **Dead local `canvaskit/` (7.2 MB)** in deploy — fallback fetches from gstatic CDN; drop the local copy or set `useLocalCanvasKit`.
- **Residual `Icons.`/`CupertinoIcons.`** (3 sites: `symbol_palette_bar.dart`, `topos_filter.dart`) — finish MasiIcon migration to drop `uses-material-design`.

---

## Clean (checked, no action)
No implicit-animation widgets anywhere (`AnimatedContainer`/`TweenAnimationBuilder` etc. = 0);
no `Hero`/custom route transitions; all 3 `CustomPainter.shouldRepaint` do proper field
comparisons (none return `true` unconditionally); no `Timer.periodic`/polling; feed/library
lists already lazy `ListView.builder`; thumbnail architecture (pre-resized `thumbs/<id>.jpg` at
`cacheWidth`) already solid (#56); web thumbnail gen uses native `createImageBitmap`/`OffscreenCanvas`;
`PhotoImageCache` (web) is a well-built LRU cache-through. `MemoryImage` identity churn: none.
