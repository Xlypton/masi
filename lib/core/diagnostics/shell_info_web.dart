import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:web/web.dart' as web;

import 'shell_info_types.dart';

// Real browser implementation of the offline-shell diagnostic seam, picked
// whenever `dart.library.js_interop` is available (see `shell_info.dart`'s
// facade doc). Wasm-clean: only `package:web` and `dart:js_interop`/
// `dart:js_interop_unsafe`, never `dart:html`.
//
// TOTAL and READ-ONLY, like every function in `storage_persistence_web.dart`:
// it returns a value for every browser and every failure mode, never throws,
// and never registers, unregisters, updates or skip-waits a worker or deletes
// a cache.

/// How long any single browser call here is allowed to take.
///
/// A diagnostic must never be the thing that hangs the screen it is diagnosing
/// — and these calls run on a page that may well be mid-failure, which is the
/// case where they are least likely to answer promptly. Every timeout degrades
/// to the honest "unknown" for that one fact and leaves the rest intact.
const Duration _probeTimeout = Duration(seconds: 3);

/// The cache-name prefix `web/sw.js` opens its shell under
/// (``const CACHE_NAME = `masi-shell-${SHELL_VERSION}` ``). The version is
/// everything after it.
const String _shellCachePrefix = 'masi-shell-';

/// The window global `web/index.html` sets from the service worker's own
/// `masi-warm-done` / `masi-observed-done` ack, which carries `SHELL_VERSION`
/// straight from the running worker.
///
/// This is the AUTHORITATIVE source when present — the worker said it about
/// itself. The cache-name scan below is the fallback, because the ack only
/// lands once the worker has answered a report, which has not necessarily
/// happened yet when the user opens this screen.
const String _versionGlobal = '__masiShellVersion';

/// Reads the offline shell's current state for this page. See [ShellInfo].
Future<ShellInfo> readShellInfo() async {
  final JSObject navigator = web.window.navigator;
  if (!navigator.has('serviceWorker')) return ShellInfo.notApplicable;

  final container = web.window.navigator.serviceWorker;

  // Read BEFORE the awaits below. `controller` is a live property, and the
  // question this answers — "is a worker serving THIS page's fetches right
  // now?" — is about the moment the user pressed the button, not about
  // whatever happened while a registration lookup was in flight.
  final controlling = _controllerPresent(container);

  final registration = await _registration(container);
  final versions = await _shellCacheVersions();

  // `installing` counts as pending, not just `waiting`: a worker that is still
  // downloading the new build is every bit as much "the deploy landed, this
  // tab has not taken it yet" as one that has finished and is waiting to
  // activate, and the user's action for both is the same single reload.
  final updatePending =
      registration != null &&
      (registration.waiting != null || registration.installing != null);

  final reported = _reportedVersion();
  // With no ack yet, a single shell cache identifies the build unambiguously.
  // TWO of them do not: `activate` sweeps every cache but the current one, so
  // a surviving pair means an activation did not complete and there is no way
  // from the page to tell which of the two is being served. Reporting either
  // one as "the" version would be a guess presented as a fact, so this reports
  // none and lists both as stale instead — which is also the more useful
  // answer, since the pair IS the finding.
  final version =
      reported ?? (versions.length == 1 ? versions.single : null);
  final extras = versions.where((v) => v != version).toList();

  return ShellInfo(
    supported: true,
    registered: registration != null,
    controlling: controlling,
    updatePending: updatePending,
    version: version,
    extraVersions: extras,
  );
}

/// Whether `navigator.serviceWorker.controller` is a real worker.
///
/// Read through `getProperty` + an explicit object check rather than the typed
/// getter, mirroring `storage_persistence_web.dart`'s `_storageManager`: an
/// engine that leaves the property `undefined` rather than `null` must produce
/// a clean `false` here, not a type error inside a diagnostic.
bool _controllerPresent(web.ServiceWorkerContainer container) {
  if (!container.has('controller')) return false;
  final controller = container.getProperty<JSAny?>('controller'.toJS);
  if (controller == null || controller.isUndefinedOrNull) return false;
  return controller.isA<JSObject>();
}

/// This scope's registration, or `null` when there is none, the lookup
/// rejected (registration blocked by policy or private browsing), or it did
/// not answer inside [_probeTimeout].
Future<web.ServiceWorkerRegistration?> _registration(
  web.ServiceWorkerContainer container,
) async {
  try {
    return await container.getRegistration().toDart.timeout(_probeTimeout);
  } catch (_) {
    return null;
  }
}

/// [_versionGlobal]'s value, or `null` when the ack has not landed yet (or the
/// page set something that is not a string).
String? _reportedVersion() {
  final JSObject window = web.window;
  if (!window.has(_versionGlobal)) return null;
  final value = window.getProperty<JSAny?>(_versionGlobal.toJS);
  if (value == null || value.isUndefinedOrNull) return null;
  if (!value.isA<JSString>()) return null;
  final version = (value as JSString).toDart;
  return version.isEmpty ? null : version;
}

/// Every `masi-shell-*` cache present on this origin, as bare version strings,
/// sorted so two reports of the same state read identically.
///
/// Returns an empty list — never throws — when `caches` is absent (it is
/// `[SecureContext]`, so plain HTTP has no such property), when the enumeration
/// rejects, or when it does not answer inside [_probeTimeout].
Future<List<String>> _shellCacheVersions() async {
  final JSObject window = web.window;
  if (!window.has('caches')) return const <String>[];
  try {
    final keys = await web.window.caches.keys().toDart.timeout(_probeTimeout);
    final versions = <String>[];
    for (final key in keys.toDart) {
      final name = key.toDart;
      if (!name.startsWith(_shellCachePrefix)) continue;
      final version = name.substring(_shellCachePrefix.length);
      if (version.isNotEmpty) versions.add(version);
    }
    versions.sort();
    return versions;
  } catch (_) {
    return const <String>[];
  }
}
