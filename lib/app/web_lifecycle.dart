// Facade for a best-effort web-only lifecycle flush hook. Sync-resilience
// hardening pass: on a browser tab being hidden/backgrounded or the page
// starting to unload, this gives any pending debounced sync push
// (`SyncOrchestrator._scheduleDebouncedPush`,
// `lib/features/backup/application/sync_orchestrator.dart`) a chance to
// START before the tab disappears — the web analogue of the
// `AppLifecycleState.paused` branch `app.dart`'s `didChangeAppLifecycleState`
// already handles for native apps (which calls
// `SyncOrchestrator.onAppPaused()`), for which there is no reliably-firing
// web equivalent otherwise (browsers don't call `AppLifecycleState.paused`
// on a plain tab-close/backgrounding the way iOS/Android do).
//
// This is a WEB-ONLY feature — like
// `lib/features/account/application/pwa_install.dart`, a native app already
// gets a reliable OS-level pause callback, so this is a two-way split, not
// the native/web/stub three-way split used elsewhere (e.g.
// `lib/features/topo/data/photo_files.dart`):
//  - native (iOS/Android/desktop) AND plain-Dart tests: an inert no-op —
//    picked whenever `dart.library.js_interop` is unavailable. Native/iOS
//    behavior is therefore completely unchanged by this facade's existence.
//  - web: real `pagehide`/`visibilitychange` browser listeners, implemented
//    with `package:web` + `dart:js_interop` ONLY — never `dart:html`, never
//    `dart:io` — so this stays wasm-clean and keeps the repo's
//    `grep -r "dart:io" lib` gate green.
export 'web_lifecycle_native.dart'
    if (dart.library.js_interop) 'web_lifecycle_web.dart';
