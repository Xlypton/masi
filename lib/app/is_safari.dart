// Whether the app is running in Apple Safari on the web.
//
// Resolves to a no-op `false` off-web via the conditional export below
// (mirrors `web_lifecycle.dart` / `pwa_install.dart`, gated on
// `dart.library.js_interop`, never `dart:html`). Used to gate
// `GoRouter.routerNeglect`: on Safari ONLY, go_router never creates browser
// history entries, so iOS Safari's native interactive edge-swipe-back
// gesture has no previous entry to preview — suppressing a WebKit compositor
// "flash" (previous screen snapshot, then Flutter re-rasterizes) that cannot
// be removed while the gesture can fire (#74/#76). Chromium/other engines
// keep normal browser-back (they don't have the flash).
export 'is_safari_stub.dart' if (dart.library.js_interop) 'is_safari_web.dart';
