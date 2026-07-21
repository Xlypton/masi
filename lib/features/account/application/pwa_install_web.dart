import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:web/web.dart' as web;

import 'pwa_install_types.dart';

/// Reads the boolean global `window.__masiStandalone` — set by the web
/// shell's bootstrap script (`web/index.html`), which checks
/// `matchMedia('(display-mode: standalone)')` / `navigator.standalone` once
/// at load. Missing/undefined reads as `false` (not installed) rather than
/// throwing — the bootstrap script is expected to exist once this ships,
/// but a missing global must never crash the Account screen in the
/// meantime.
bool pwaIsStandalone() => _readBoolGlobal('__masiStandalone');

/// Reads the boolean global `window.__masiCanInstall` — set `true` by the
/// bootstrap script once the browser's `beforeinstallprompt` event has
/// fired and a deferred install prompt is ready to show programmatically
/// (Chromium/Android only; Safari never fires this event, so this is always
/// `false` there). Missing/undefined reads as `false`.
bool pwaCanPromptInstall() => _readBoolGlobal('__masiCanInstall');

/// Best-effort platform sniff off `navigator.userAgent`, used only to pick
/// which install AFFORDANCE the Account screen shows: [PwaPlatform.ios] gets
/// a manual "Add to Home Screen" hint (there is no programmatic prompt API
/// on iOS Safari at all), everything else can rely on [pwaCanPromptInstall].
PwaPlatform pwaPlatform() {
  final userAgent = web.window.navigator.userAgent;
  if (RegExp(r'iPad|iPhone|iPod').hasMatch(userAgent)) return PwaPlatform.ios;
  if (userAgent.contains('Android')) return PwaPlatform.android;
  return PwaPlatform.other;
}

/// Calls the JS global `window.masiPromptInstall()` (installed by the
/// bootstrap script alongside its `beforeinstallprompt` listener), which
/// shows the browser's deferred native install prompt and resolves to
/// `'accepted'`, `'dismissed'`, or `'unavailable'` once the user has
/// responded (or immediately, if no prompt was ever deferred). Returns
/// `true` iff the resolved string is exactly `'accepted'` — any other
/// outcome, including the function/global being entirely absent (e.g. an
/// older cached `index.html`), resolves to `false` rather than throwing.
Future<bool> pwaPromptInstall() async {
  const name = 'masiPromptInstall';
  if (!globalContext.has(name)) return false;
  final fn = globalContext[name];
  if (fn == null || fn.isUndefinedOrNull) return false;

  final promise = globalContext.callMethod<JSPromise<JSString>>(name.toJS);
  final outcome = (await promise.toDart).toDart;
  return outcome == 'accepted';
}

/// Shared undefined-safe boolean-global reader backing [pwaIsStandalone]
/// and [pwaCanPromptInstall]: absent OR explicitly `undefined`/`null`
/// globals both read as `false`, never throw.
bool _readBoolGlobal(String name) {
  if (!globalContext.has(name)) return false;
  final value = globalContext[name];
  if (value == null || value.isUndefinedOrNull) return false;
  return (value as JSBoolean).toDart;
}
