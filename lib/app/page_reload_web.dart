import 'package:web/web.dart' as web;

/// Discards the current page — and with it a database worker wedged on the
/// sqlite3 OPFS VFS's `Atomics.wait(int32View, _responseIndex, -1)` (no
/// timeout) — and re-fetches it fresh. See [page_reload.dart] for why this,
/// and only this, is the honest recovery for that mechanism.
///
/// Deliberately does nothing else. No `clear()`, no `deleteDatabase()`, no
/// cache eviction: a reload discards a stuck WORKER, never data. Anything
/// already committed to OPFS/IndexedDB survives a reload exactly as it
/// survives a normal tab close and reopen.
void reloadPage() {
  web.window.location.reload();
}
