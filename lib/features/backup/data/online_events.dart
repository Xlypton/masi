// Facade for the browser's `online`/`offline` window events — the WEB half of
// [ConnectivityService.statusChanges] (`connectivity_service.dart`).
//
// Two-way split (native/web, no `_stub.dart`), exactly like
// `lib/app/web_lifecycle.dart` and for the same reason: this is a web-only
// affordance. Native platforms already have a real connectivity signal —
// `connectivity_plus`'s `onConnectivityChanged` — so there is nothing for a
// browser event hook to add there; the three-way split used by
// `lib/features/topo/data/photo_files.dart` exists for APIs that need a
// distinct plain-Dart stub, which this does not.
//  - native (iOS/Android/desktop) AND plain-Dart tests: an inert,
//    never-emitting stream — picked whenever `dart.library.js_interop` is
//    unavailable. Native behaviour is completely unchanged by this facade's
//    existence.
//  - web: real `online`/`offline` window listeners, implemented with
//    `package:web` + `dart:js_interop` ONLY — never `dart:html`, never
//    `dart:io` — so this stays wasm-clean and keeps the repo's
//    directive-anchored `dart:io` gate green.
export 'online_events_native.dart'
    if (dart.library.js_interop) 'online_events_web.dart';
