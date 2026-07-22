# Masi → Web Port — Planning Brief

> **Purpose.** Self-contained extraction of the current codebase for planning a Flutter **web** release
> (PWA, "closest-to-native feel") alongside the existing iOS/Android app. AR is explicitly **out of scope**
> on web (grayed-out entry point). This document is the raw material for a formal implementation plan;
> it states current state, what breaks, and the shape of the work — it does **not** itself prescribe the
> final plan. Written 2026-07-20. All file:line refs verified against `main` at time of writing.

---

## 0. TL;DR — feasibility & shape

Feasible, and Flutter's web target + web-capable plugin variants exist upstream for nearly everything used
here. It is **not** a "flip a flag" job. There are exactly **two substantial pieces of work**, one moderate
piece, and a pile of small gates:

1. **Persistence: Drift `NativeDatabase` → `WasmDatabase`** (native SQLite FFI has no browser target). Bounded, well-trodden.
2. **Photo/media pipeline: filesystem → byte storage** (the whole app stores photos as files on disk and renders them via `Image.file(File(path))`). This is the largest rewrite surface — photos are core to the app, and ~11 files assume a real filesystem.
3. **Native-feel / responsive UI** (moderate): the app is mobile-first with a bottom tab bar and touch-only canvas gestures; a desktop-width browser needs adaptive layout + a pointer/mouse interaction model for the canvas.
4. **Small gates**: AR grayed-out, `image_picker` camera UX, `connectivity_plus` wifi/cellular, web auth redirect. Mostly mechanical.

**Prerequisite (zero-risk, must be first):** there is **no `web/` directory at all** — `flutter create --platforms=web .` has never been run. No web scaffolding, no PWA manifest, no service worker.

**One hard rule the codebase already respects:** `kIsWeb` appears in exactly one file today (`ar_screen.dart`). Everything else assumes native. The idiomatic fix for the two big pieces is **conditional imports** (`dart.library.io` vs `dart.library.js_interop`), not runtime `kIsWeb` branches, so `dart:io` never enters the web bundle.

---

## 1. Project facts (current state)

- Package `masi`; entrypoint `main()` in `lib/main.dart` (`runApp` wraps `MasiApp` in `UncontrolledProviderScope`).
- Flutter 3.44.2 · Dart 3.12.2. Riverpod **v3** (`Notifier`/`NotifierProvider`, never `StateProvider`). Routing: **go_router 17.3.0**.
- Root widget: `MaterialApp.router` (Material 3), `themeMode: ThemeMode.system`, custom design tokens.
- Platforms enabled: **iOS + Android only** (`.metadata` lists `root/android/ios`; no `web`, `macos`, `linux`, `windows`).
- Local-first: Drift/SQLite on device; Supabase sync **is live and wired end-to-end** (despite stale "deferred" comments in `MASI.md` and `sync_remote.dart` — a real backend exists at `supabase/schema.sql`, 8 tables + Storage RLS, two-account live smoke verified 2026-07-17).
- ~377 unit/widget tests; 51 test files override `appDatabaseProvider` with `AppDatabase(NativeDatabase.memory())`.

---

## 2. Dependency web-compatibility audit

Resolved versions from `pubspec.lock`. Status: **OK** = supports web · **PARTIAL** = works with caveats · **BROKEN** = native-only as used.

| Package | Ver | Web | Notes |
|---|---|---|---|
| flutter_riverpod | 3.3.2 | OK | Pure Dart. |
| flutter_svg | 2.3.0 | OK | Renders on web; backs the MasiIcon system. |
| go_router | 17.3.0 | OK | Web-aware; supports URL/path strategy. |
| image | 4.9.1 | OK | Pure-Dart image processing. |
| path / uuid / latlong2 / characters | — | OK | Pure Dart. |
| http | 1.6.0 | OK | Uses browser fetch on web (CORS applies). |
| url_launcher | 6.3.2 | OK | Opens tab on web. |
| supabase_flutter | 2.16.0 | OK | Auth/postgrest/realtime/storage all work on web; redirect config differs. |
| flutter_map | 8.3.1 | OK | Works on web; tile fetch is plain http (CORS on tile host). On-disk tile cache (`BuiltInMapCachingProvider`) needs `DisabledMapCachingProvider` on web (already used in this repo's tests). |
| connectivity_plus | 7.2.0 | PARTIAL | Online/offline only — **can't distinguish wifi/cellular** in a browser. Breaks the `wifiOnly` upload gate. |
| geolocator | 14.0.3 | PARTIAL | `geolocator_web` uses browser Geolocation API; HTTPS-only, foreground-only, different permission UX. `LocationService` already "never throws, returns null on failure" → degrades gracefully. |
| image_picker | 1.2.2 | PARTIAL | `image_picker_for_web` auto-handles web, but `ImageSource.camera` → browser file dialog (no true capture on most browsers), and returns an `XFile` backed by a **blob URL, not a file path** → breaks every downstream `File(xfile.path)`. |
| path_provider | 2.1.6 | PARTIAL/BROKEN as used | `getApplicationDocumentsDirectory()` **throws `UnimplementedError` on web**. Underpins both DB path and all photo storage. |
| **drift** | 2.34.1 | **BROKEN as used** | Uses `NativeDatabase(File(...))` + `dart:io`. drift *does* support web via `WasmDatabase` (`package:drift/wasm.dart`) — needs conditional-import connection swap + `sqlite3.wasm`/`drift_worker.js` assets. |
| **sqlite3_flutter_libs** | 0.6.0+eol | **BROKEN** | Native sqlite binaries, no web. Web uses a `sqlite3.wasm` asset instead. Should tree-shake out of the web bundle (verify). |
| **AR (custom, not a package)** | — | **BROKEN** | ARKit via platform channels + `UiKitView`. No web equivalent (WebXR would be a rewrite). Gray out. |

**Not dependencies** (confirmed absent): `share_plus`, `permission_handler`, raw `camera`, `flutter_secure_storage`. Permissions are delegated entirely to `image_picker`/`geolocator` internals.

**Verify during port:** connectivity_plus branch on wifi-vs-cellular; flutter_map tile-host CORS headers; supabase web auth redirect config.

---

## 3. BLOCKER #1 — Persistence (Drift/SQLite)

**Files:** `lib/core/db/app_database.dart` (DB class, `schemaVersion = 6`, `MigrationStrategy`), `app_database.g.dart` (generated), `tables.dart` (tables + `SyncColumns` mixin), `database_provider.dart` (connection).

**Current connection (the only production path), `database_provider.dart`:**
```dart
LazyDatabase _openConnection() => LazyDatabase(() async {
  final dir = await getApplicationDocumentsDirectory();      // path_provider — throws on web
  final file = File(p.join(dir.path, 'climbtopo.sqlite'));    // dart:io — absent on web
  return NativeDatabase(file);                                 // native FFI — no web target
});
```

**Tables** (all mix in `SyncColumns`: `id` TEXT PK uuid, `createdAt`/`updatedAt` ms, `deletedAt` nullable soft-delete, `remoteId`, `dirty` bool, `ownerId`): Areas, Sectors, Walls (`visibility` private/shared, lat/lng), **Photos** (`localPath` TEXT, `kind` original/slice, w/h, `parentPhotoId` self-ref, crop pcts, `sortOrder`, `isPrimary`), Routes (pointsJson/symbolsJson, grade fields, betaVideoUrl, styleTagsJson, stars; raw-SQL partial unique index `idx_routes_photo_number_live` on `(photo_id, number) WHERE deleted_at IS NULL`), Comments, Likes, Ascents.

**Migrations:** straight-line additive v1→v6, incl. a v5→v6 **data migration** via `customStatement`/`customSelect` (backfills photo `sortOrder`/`isPrimary`). `beforeOpen` runs `PRAGMA foreign_keys = ON`. All plain drift/SQL → **ports unchanged** under WASM sqlite (same engine).

**Web migration checklist:**
- [ ] Conditional-import split: `connection/connection.dart` (stub) + `connection_native.dart` (existing code verbatim) + `connection_web.dart`, selected via `import 'connection_stub.dart' if (dart.library.io) 'connection_native.dart' if (dart.library.js_interop) 'connection_web.dart';`. Replaces the single `_openConnection()` in `database_provider.dart`.
- [ ] Web branch: `WasmDatabase.open(databaseName: ..., sqlite3Uri: Uri.parse('sqlite3.wasm'), driftWorkerUri: Uri.parse('drift_worker.js'))` (picks OPFS via worker when available, falls back to IndexedDB).
- [ ] Copy `sqlite3.wasm` + `drift_worker.js` into `web/` as static assets — a **required manual step for every web build** (candidate for a build script).
- [ ] `AppDatabase` class, tables, migration strategy need **no changes** — only the connection is platform-specific.
- [ ] Tests: existing in-memory overrides keep working on the VM. A true web-target test needs a WASM-backed fake (lower priority).

---

## 4. BLOCKER #2 — Photo / media pipeline (largest rewrite)

**The crux:** photos are **not** blobs in SQLite. `Photos.localPath` is a TEXT column holding a **relative** path (`photos/<id>.<ext>`); the pixel bytes live as real files under `<appDocuments>/photos/`. Browsers have no filesystem.

**Capture → store → display, today:**
- **Capture:** `photo_source_sheet.dart` → `ImagePicker().pickImage(...)` → `XFile` whose `.path` is an OS-cache path (native) / blob URL (web).
- **Store:** `lib/features/topo/data/photo_files.dart` — `PhotoFiles`:
  - `importPhoto(sourcePath, photoId)` → `File(sourcePath).copy(<docs>/photos/<id><ext>)`, returns **relative** path (survives iOS container-UUID rotation).
  - `writePhotoBytes(photoId, ext, bytes)` → `File(dest).writeAsBytes(...)` (cloud-restore path).
  - `resolvePhotoPath` / `resolvePhotoPathSync` → relative→absolute via `path_provider`; **sync** variant is used on hot UI paths (canvas mount, `watchTopos` stream) because `path_provider` can't resolve synchronously — hence the `warmDocsPath()` prewarm in `main.dart:41`.
  - All via `dart:io` `File`/`Directory` — none works on web.
- **Display / read — every `File(...)` / `FileImage` / `Image.file` site (must all get a web-safe path):**

| File:line | Usage |
|---|---|
| `topo_canvas.dart:1089` | `Image.file(File(imagePath))` — **canvas background** |
| `topo_canvas_screen.dart:1173` | `FileImage(File(path)).resolve(...)` — pre-resolve image dimensions (canvas coord math) |
| `topo_canvas_screen.dart:239` | `File(path).readAsBytes()` — EXIF/GPS extraction on picked photo |
| `photo_strip.dart:165` | `Image.file(File(localPath))` — photo-strip thumbnails |
| `topos_screen.dart:1570-1572` | `File(thumbnailPath).existsSync()` + `Image.file` — library topo cards |
| `community_screen.dart:779-781` | same — community feed thumbnails |
| `outline_extractor.dart:97` | `File(path).readAsBytes()` — AR ghost-outline decode (AR-only, moot on web) |
| `ar_screen.dart:168` | `File(localPath).existsSync()` — AR gate (AR-only, but see §6 crash risk) |
| `cloud_backup_service.dart:185` | `File(resolved.path)` — read bytes to upload to Supabase Storage |
| `sync_service.dart:266` | `File(resolved.path)` — same, row-level sync push |

**Note:** there is **no `Image.network`/`NetworkImage`/`CachedNetworkImage` anywhere** — even the community shared-topo detail screen reads the same local files. Photo binaries are synced through Supabase Storage (`topo-photos` bucket) but the UI layer always renders from local disk.

**Web migration checklist:**
- [ ] Give `PhotoFiles` a parallel web implementation behind a shared interface (`importPhoto`, `writePhotoBytes`, `resolvePhotoPath[Sync]`, `warmDocsPath`), via conditional imports (`photo_files_native.dart` / `photo_files_web.dart`), so `dart:io` never enters the web bundle.
- [ ] **Recommended web backend:** store bytes as a BLOB in a new Drift table (e.g. `PhotoBlobs(id, bytes)`) — since drift-wasm's IndexedDB-backed SQLite holds BLOBs fine, this avoids separate IndexedDB plumbing and keeps `Photos.localPath` as an opaque logical key. (Alternative: raw IndexedDB/OPFS + object URLs.)
- [ ] Swap all display sites from `Image.file(File(path))` to a platform-agnostic loader — `Image.memory(bytes)` fed by a byte-lookup provider (async, with a sync fast-path for the hot canvas/stream paths that today rely on `resolvePhotoPathSync`).
- [ ] `image_picker` web returns bytes/blob URL, not a path → `importPhoto` must branch to `XFile.readAsBytes()` + byte storage instead of `File.copy`.
- [ ] `cloud_backup_service.dart` / `sync_service.dart` must fetch bytes through the `PhotoFiles` abstraction, not construct `File` directly.
- [ ] `outline_extractor.dart` uses `compute` (isolate) — on web `compute` runs on the main event loop; functionally fine, perf note for large decodes (AR-only anyway).

---

## 5. Native integration inventory (what to gate)

**`kIsWeb` today:** only `ar_screen.dart` (lines 6, 56, 58). **`dart:io` importers:** 11 files (all listed in §3/§4). No conditional imports exist anywhere yet.

**Platform channels / views — AR only:**
- `masi/ar` `MethodChannel` + `masi/ar/alignment` `EventChannel` (`ar_channel.dart:141-143`); same string as the `UiKitView` viewType (`ar_screen.dart:288`).
- Native (iOS only): `ios/Runner/AR/` — `ArChannelHandler.swift`, `ArPlatformView.swift`, `ArViewFactory.swift`, `ArVisionPipeline.swift`; registered in `AppDelegate.swift:23`. **No Android AR** (`MainActivity.kt` is stock) — Android already falls through to the same unsupported placeholder web will.
- `Info.plist` declares Photo/Camera/Location usage strings (iOS-only concepts).

**Plugin web behavior (gates needed):**
- `url_launcher`, `supabase_flutter`, `flutter_map` → work, no gate.
- `geolocator` → degrades gracefully by existing design (no code change).
- `connectivity_plus` → needs a `kIsWeb` fallback in `SystemConnectivityService.currentStatus()` (treat web as "wifi" or drop the `wifiOnly` gate).
- `image_picker` → no code gate required (degrades), but UX-gate the "Take photo" action-sheet option on web.

---

## 6. AR — grayed-out plan (user's stated preference)

**Entry point (exactly one):** `topo_canvas_screen.dart:1692-1705` — `IconButton` key `topo-ar-button`, icon `ar_peak`, shown only when `mode==view && activePhotoId!=null && any visible route`; `onPressed → context.push('/walls/<id>/ar')`. Route registered at `router.dart:127-131` (also reachable by typed URL on web). No AR item in the bottom nav.

**Already web-aware:** `ArScreen.build` checks `_isArPlatformSupported() => !kIsWeb && Platform.isIOS` and renders `_buildUnsupportedPlaceholder` (key `ar-unsupported-placeholder`) otherwise. Pure Dart helpers (`Homography`, `ArOverlayPainter`) are web-safe and never mount without a native session.

**Gating plan:**
1. Promote `_isArPlatformSupported()` into a shared helper (e.g. `lib/core/platform/ar_support.dart` → `bool isArSupported()`), imported by both the button and `ArScreen`, so the gate can't drift.
2. **Gray out, don't hide** (per user): keep the button visible on web but `onPressed: isArSupported() ? ... : null` (IconButton auto-dims on null) with tooltip `'View in AR (not available on web)'`.
3. Keep `ArScreen`'s build-time placeholder as a direct-URL backstop.
4. **Fix a pre-existing crash gap:** `_load()` runs on `initState` **before** `build()`'s gate and calls `File(photo.localPath).existsSync()` (`ar_screen.dart:168`) — `dart:io` on web throws before the placeholder is ever reached. Guard that branch with `isArSupported() &&`.
5. Nothing else in the AR stack needs gating.

**Shared code not to break:** `PhotoRepository`/`RouteRepository`, `TopoRoute` model, `DrawState` — all platform-agnostic, read by both AR and the plain canvas.

---

## 7. Native-feel & responsive UI (the "closest to native" goal)

**Bootstrap risk:** `main.dart:27-41` builds a `ProviderContainer` and `await warmDocsPath()` before `runApp` — filesystem-oriented, no web equivalent (the web `PhotoFiles` variant must provide a no-op/analogous warm-up). `app.dart:33-42` pushes sync on `AppLifecycleState.paused` — web's analog is `visibilitychange` (behaves differently; acceptable).

**Navigation:** `StatefulShellRoute.indexedStack`, 3 branches (Topos `/`, Map `/map`, Feed `/feed`), wrapped by `NavShell` — a floating translucent-glass **bottom tab bar** (`GlassChrome`), `extendBody:true`, phone-bottom-bar pattern. **No rail/sidebar variant for wide viewports.** All other routes (`/walls/:id`, `/community/topo/:id`, `/areas…`, `/account`, `/logbook`, `/walls/:id/ar`) are full-screen siblings.

**Full route table:** `/` Topos (`topos_screen.dart`) · `/map` (`community_screen.dart` `CommunityMapScreen`) · `/feed` (`CommunityFeedScreen`) · `/community` (redirect) · `/account` · `/community/topo/:wallId` (read-only, embeds `TopoCanvasScreen(readOnly:true)`) · `/logbook` · `/areas`, `/areas/:areaId/sectors`, `/sectors/:sectorId/walls` · `/walls/:wallId` (**canvas**) · `/walls/:wallId/ar`.

**Topo canvas (the hardest UI surface), `topo_canvas.dart` + `topo_canvas_screen.dart`:**
- Test seam: `TopoCanvas` takes an already-decoded `imageSize`; `TopoCanvasBody` is the pumpable wrapper; `debugInitialImageSize` skips the real decode. **Keep this seam** — it's how everything is tested without driving a codec.
- Preloads 4 SVG symbol glyphs into `ui.Picture`s once (`topo_canvas.dart:23-59`); `CustomPaint`/`TopoPainter` draws routes scaled by live `InteractiveViewer` zoom so stroke widths stay constant.
- **Gesture model is touch/multi-pointer-first and the single biggest "won't just work" desktop risk:** `InteractiveViewer(constrained:false)` for pinch/pan, wrapped in a raw `Listener` (not `GestureDetector`, to win the gesture arena) tracking individual pointers. Draw mode = "first finger draws, second finger pinch-zooms" (`panEnabled:false, scaleEnabled:true`). Hit radius 20px, tap slop 8px — fingertip-tuned. **No mouse/trackpad equivalent** (no hover, no scroll-wheel zoom, no click-drag-vs-scroll disambiguation, no keyboard shortcuts). Needs a **parallel desktop interaction model**.
- Chrome (`canvas_chrome.dart` `GlassChrome` = `BackdropFilter` blur) positioned via `Positioned`/`SafeArea` assuming one full-screen phone viewport with notch/home-indicator.

**Form-factor assumptions (all need responsive work for a native feel on wide browsers):**
- **No breakpoint system anywhere** — no `Breakpoint`/width-threshold logic; every `LayoutBuilder`/`MediaQuery` use is local sizing (canvas fit math, safe-area, %-of-screen), not responsive column/grid switching.
- All list screens are single-column `ListView`/`CustomScrollView` filling phone width → a desktop browser shows edge-to-edge stretched lists. No `GridView` column count, no max-content-width constraint.
- Bottom tab bar is the only nav paradigm → reads as a phone squeezed into a huge window.
- Cupertino bottom sheets/action sheets in several places (`photo_source_sheet.dart`, `symbol_palette_bar.dart`, `route_metadata_sheet.dart`, `crud_list_scaffold.dart`, `grade_range_picker.dart`, `topos_screen.dart`) → distinctly "mobile" chrome on desktop; likely want dialog/popover equivalents at wide widths.
- 44×44 HIG tap targets — fine but oversized for mouse.

**Theming & assets (all portable as-is):**
- `MaterialApp.router`, Material 3. Design tokens in `lib/app/theme.dart`: `MasiColors` (ThemeExtension, light/dark), `MasiRadii`, `MasiSpacing` (4/8/12/16/24/32), hand-built HIG type scale. Platform-agnostic.
- **MasiIcon** (`lib/shared/presentation/masi_icon.dart`): `MasiIcon(name, {size,color,tinted})` → `assets/icons/masi/masi_<name>.svg` via flutter_svg, srcIn tint. **83 SVGs.** User mandate: use everywhere, never `Icons.*`/`CupertinoIcons.*`. Fully portable to web — keep as the single icon source.
- **Fonts:** none declared (`fonts:` commented out) → web falls back to Roboto-ish, not SF. HIG type scale (tuned for SF tracking/weights) may read differently — decide whether to bundle a web font for parity.
- Assets declared: only `assets/icons/masi/` + `assets/icon/masi_icon.png` (launcher, iOS-only in `flutter_launcher_icons` config → needs web icon set generated).

---

## 8. Sync / Supabase / auth (web notes)

- **Live, not a stub** (stale comments say otherwise). Init in `main.dart:17-23`: `Supabase.initialize(url, publishableKey, authFlowType: pkce)`, try/catch so offline never blocks boot. Config in `supabase_config.dart` (URL + **publishable/anon key only** — safe to embed, RLS-scoped; overridable via `--dart-define`; service-role key never client-side — confirmed absent).
- Backend real: `supabase/schema.sql` (8 tables, Storage RLS on `topo-photos` incl. a `shared/`-prefix path for cross-user reads). Row-level sync (`sync_remote.dart`) pushes/pulls 8 tables in FK order; `fetchSharedTopos()` vs `fetchOwnRows()` (ascents excluded from shared). Auto-sync (`sync_orchestrator.dart`): debounced push-on-write (2s), pull-on-sign-in, push-on-background.
- **supabase_flutter works on web** (it's an HTTP/realtime client). Session persistence: default storage → `window.localStorage` on web (no `flutter_secure_storage` used) → **not a blocker**.
- **Web auth gap:** magic-link redirect is a native custom scheme `io.supabase.climbtopo://login-callback/` (`auth_repository.dart:89`), registered in `Info.plist`/`AndroidManifest.xml`. **No web equivalent** — web needs an `https://` redirect + `detectSessionInUrl` handling. Config task, not architectural.
- **Maps:** `flutter_map` + OSM raster tiles via a `RetryClient`-wrapped http client (`community_screen.dart`). Works on web; watch tile-host CORS; swap on-disk tile cache → `DisabledMapCachingProvider` on web. Map marker thumbnails hit the §4 photo pipeline.

---

## 9. Web build-readiness / PWA (all greenfield)

- **No `web/` dir.** Step one: `flutter create --platforms=web .`.
- `dart:ffi`/`dart:isolate` → **zero hits** (good). Breaking imports = the 11 `dart:io` files only.
- PWA/native-feel infra all **missing** (scaffold from scratch): `manifest.json` (icons, `display:standalone`), `index.html` meta (`apple-touch-icon`, `apple-mobile-web-app-capable`, `theme-color`), service worker (Flutter generates on build), splash, web icon set (`web/icons/Icon-*.png` — derive from `assets/icon/masi_icon.png`).
- No CI, no Makefile, README is default template, zero "web" mentions in any project doc — greenfield from a docs standpoint too. Web build guidance should be added to `CLAUDE.md`.

---

## 10. Suggested work breakdown (for the planner to shape)

Not a committed plan — a starting decomposition, roughly dependency-ordered:

1. **Scaffold** `web/` (`flutter create --platforms=web .`); confirm empty app boots in Chrome. (S)
2. **DB web connection** — conditional-import split + `WasmDatabase` + wasm/worker asset copy + build script. Gate: app boots on web with an empty DB, migrations run. (M)
3. **Photo pipeline web backend** — `PhotoFiles` interface + web (BLOB-in-drift) impl + swap all `Image.file` sites to byte-based loader + `image_picker` XFile-bytes path + backup/sync byte fetch. Gate: pick → store → render photo on canvas in browser. (L — the big one)
4. **AR gray-out** — shared `isArSupported()`, disabled button + tooltip, fix `_load()` crash guard, verify placeholder on direct URL. (S)
5. **Small plugin gates** — connectivity wifi fallback, camera-source UX, web auth redirect config. (S–M)
6. **Responsive / native-feel** — breakpoint system, max-content-width for lists, nav rail/sidebar at wide widths, desktop canvas interaction model (scroll-zoom, click-drag pan, click-to-place), dialog/popover vs Cupertino sheets, optional web font. Gate: usable + native-feeling at both phone and desktop widths. (L, iterative)
7. **PWA polish** — manifest/meta/icons/theme-color/splash for installable "app-like" feel. (S–M)
8. **Docs** — web build/run steps into `CLAUDE.md`; correct the stale "deferred" comments. (S)

**Verification note (per project discipline):** web is fully verifiable in a desktop browser + Chrome DevTools device emulation (no simulator needed); keep `flutter analyze` at 0 and `flutter test` green throughout; the existing VM tests keep working unchanged.

---

## 11. Key files index (open these first)

- Bootstrap/shell: `lib/main.dart`, `lib/app/app.dart`, `lib/app/router.dart`, `lib/app/nav_shell.dart`, `lib/app/theme.dart`
- Persistence: `lib/core/db/database_provider.dart`, `app_database.dart`, `tables.dart`
- Photos: `lib/features/topo/data/photo_files.dart`, `photo_source_sheet.dart`, `photo_repository.dart`
- Canvas: `topo_canvas.dart`, `topo_canvas_screen.dart`, `canvas_chrome.dart`, `topo_painter.dart`, `photo_strip.dart`
- AR gating pattern: `lib/features/ar/presentation/ar_screen.dart`
- Icons/design: `lib/shared/presentation/masi_icon.dart`, `assets/icons/masi/` (83 SVGs), `lib/app/theme.dart`
- Representative responsive-rework screens: `topos_screen.dart`, `community_screen.dart`
- Sync/backend: `lib/core/config/supabase_config.dart`, `lib/features/backup/data/*`, `supabase/schema.sql`
