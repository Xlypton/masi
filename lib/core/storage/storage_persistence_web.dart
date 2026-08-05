import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:web/web.dart' as web;

import 'storage_persistence_types.dart';

// Real browser implementation of the storage-persistence seam, picked
// whenever `dart.library.js_interop` is available (see
// `storage_persistence.dart`'s facade doc). Wasm-clean: only `package:web`
// and `dart:js_interop`/`dart:js_interop_unsafe`, never `dart:html`.
//
// Every function here is TOTAL: it returns a value for every browser and
// every failure mode and never throws, because its only caller
// (`StoragePersistenceController.requestPersistenceOnce`) runs
// fire-and-forget at boot.

/// Requests persistent storage for this origin via
/// `navigator.storage.persist()`, which returns `Promise<boolean>`:
/// `true` when the origin's bucket is now persistent (including when it
/// already was — the call is idempotent and does not re-prompt), `false`
/// when the browser declines.
///
/// Engine notes worth knowing: Chromium grants silently based on engagement/
/// installed-ness and never prompts; Firefox may show a one-time
/// "persistent storage" permission prompt; iOS Safari grants for
/// home-screen-installed web apps and applies its ~7-day unused-origin purge
/// to the rest — which is precisely the loss this seam mitigates.
Future<StoragePersistOutcome> requestPersistentStorage() async {
  final manager = _storageManager();
  if (manager == null || !manager.has('persist')) {
    return StoragePersistOutcome.unsupported;
  }
  try {
    final granted = (await manager.persist().toDart).toDart;
    return granted
        ? StoragePersistOutcome.granted
        : StoragePersistOutcome.denied;
  } catch (_) {
    return StoragePersistOutcome.failed;
  }
}

/// Whether this origin's storage is persistent RIGHT NOW
/// (`navigator.storage.persisted()`, also a `Promise<boolean>`), independent
/// of whether this app's own request is what made it so. Reports `false`
/// rather than throwing when the API is missing or rejects.
Future<bool> isStoragePersisted() async {
  final manager = _storageManager();
  if (manager == null || !manager.has('persisted')) return false;
  try {
    return (await manager.persisted().toDart).toDart;
  } catch (_) {
    return false;
  }
}

/// Reads `navigator.storage.estimate()`, which resolves to a DICTIONARY
/// (`{usage, quota}`) — not a class instance — whose members are both
/// optional per spec.
///
/// `package:web` models it as `StorageEstimate` with `external int get usage`
/// / `external int get quota`, i.e. NON-nullable, so a browser that omits
/// either member would make a typed read fail. Each member is therefore read
/// individually and defensively: a missing `usage` still yields the `quota`
/// we did get, instead of collapsing the whole estimate to `null`.
Future<StorageEstimateSnapshot?> estimateStorage() async {
  final manager = _storageManager();
  if (manager == null || !manager.has('estimate')) return null;
  try {
    final estimate = await manager.estimate().toDart;
    return StorageEstimateSnapshot(
      usageBytes: _readIntProperty(estimate, 'usage'),
      quotaBytes: _readIntProperty(estimate, 'quota'),
    );
  } catch (_) {
    return null;
  }
}

/// `navigator.storage`, or `null` when this browser/context does not expose
/// it at all — `StorageManager` is `[SecureContext]`, so the property is
/// absent over plain HTTP (localhost counts as secure). Read through
/// `getProperty` + an explicit object check rather than `navigator.storage`
/// so an absent API becomes a clean
/// [StoragePersistOutcome.unsupported] instead of relying on a typed
/// getter's behaviour for `undefined`. Mirrors the undefined-safe global
/// reads in `lib/features/account/application/pwa_install_web.dart`.
web.StorageManager? _storageManager() {
  final JSObject navigator = web.window.navigator;
  if (!navigator.has('storage')) return null;
  final storage = navigator.getProperty<JSAny?>('storage'.toJS);
  if (storage == null || storage.isUndefinedOrNull) return null;
  if (!storage.isA<JSObject>()) return null;
  return storage as web.StorageManager;
}

/// Listens for the browser's native `appinstalled` window event and calls
/// [onInstalled] every time it fires — the moment the strongest known
/// persistence-grant signal ("is this an installed PWA") flips from false to
/// true mid-session. Before this existed the event was only ever observed by
/// `web/index.html`'s own inline listener (which resets its deferred
/// install-prompt bookkeeping) and never reached Dart at all, so a real
/// install during a session could not trigger a re-ask even though it is
/// exactly the moment worth re-asking.
///
/// A direct `web.window.addEventListener` call, not a poll of a JS global —
/// same shape as `online_events_web.dart`'s `online`/`offline` listeners and
/// `web_lifecycle_web.dart`'s `pagehide`/`visibilitychange` ones. Multiple
/// listeners on the same event target coexist fine, so this does not replace
/// or interfere with index.html's own handler.
void listenForAppInstalled(void Function() onInstalled) {
  web.window.addEventListener(
    'appinstalled',
    ((web.Event _) => onInstalled()).toJS,
  );
}

/// Reads [name] off [object] as a Dart `int`, or `null` when the property is
/// absent, `undefined`/`null`, or not a JS number.
int? _readIntProperty(JSObject object, String name) {
  if (!object.has(name)) return null;
  final value = object.getProperty<JSAny?>(name.toJS);
  if (value == null || value.isUndefinedOrNull) return null;
  if (!value.isA<JSNumber>()) return null;
  return (value as JSNumber).toDartInt;
}
