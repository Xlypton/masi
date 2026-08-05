// Seam for reloading the page — the only mechanism that can discard a web
// storage worker wedged on the sqlite3 OPFS VFS's
// `Atomics.wait(int32View, _responseIndex, -1)` (no timeout; see
// `storage_retry_provider.dart`'s doc for why "Try again" cannot fix this
// mechanism). `StorageRetryBanner` offers this as a second, escalated action
// once a retry has already failed once (`StorageRetryStatus.failed`).
//
// Shaped exactly like `is_safari.dart`: a 2-way conditional export, gated on
// `dart.library.js_interop` (never `dart:html`, never `kIsWeb`). A 2-way
// seam is correct here and there is deliberately NO `_native.dart`
// variant — nothing on this path touches `dart:io`; native has no such
// concept and the stub is a plain no-op.
//
// Deliberately does nothing else. No `clear()`, no `deleteDatabase()`, no
// cache eviction of any kind: a reload discards a stuck WORKER, never data.
export 'page_reload_stub.dart' if (dart.library.js_interop) 'page_reload_web.dart';
