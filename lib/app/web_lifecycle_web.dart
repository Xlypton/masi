import 'dart:js_interop';

import 'package:web/web.dart' as web;

/// Real web implementation — picked whenever `dart.library.js_interop` is
/// available (see `web_lifecycle.dart`'s facade doc). Wasm-clean: only
/// `package:web` + `dart:js_interop` are used here, never `dart:html` and
/// never `dart:io`.
///
/// Registers TWO browser listeners and calls [onHide] from either, because
/// no single event reliably covers every "the tab is going away" path across
/// browsers:
///  - `visibilitychange` (on `document`): fires whenever the page's
///    visibility flips — tab-switch, backgrounding a mobile browser, OR the
///    tab closing — and is the event MDN recommends for this exact use case
///    (unlike `unload`/`beforeunload`, which are unreliable and, on mobile
///    Safari in particular, often don't fire at all). [onHide] only runs
///    once `document.visibilityState` has actually become `'hidden'`, not on
///    the (also-fired) transition back to `'visible'`.
///  - `pagehide` (on `window`): some navigations (e.g. those eligible for the
///    back/forward cache) fire `pagehide` without necessarily going through
///    a `visibilitychange` first, so it's kept as a second, overlapping
///    trigger. It is intentionally NOT deduped against `visibilitychange` —
///    [onHide] firing twice in a row for the same close is harmless here: it
///    is wired (by the caller in `app.dart`) to the exact same
///    `SyncOrchestrator.onAppPaused()` an ordinary repeated
///    background/foreground/background cycle can already invoke more than
///    once on native, with no special reentrancy guard needed at this layer.
///
/// HONEST LIMITATION (do not oversell this): browsers do not await ANY async
/// work once a page is genuinely being torn down — there is no portable,
/// wasm-safe way used here (no `dart:html`, no synchronous
/// `navigator.sendBeacon`-style call) to GUARANTEE the pending push
/// *completes* before the tab disappears on an abrupt hard-close mid-request.
/// This only maximizes the chance the push *starts* in time. It fires
/// reliably (and the push reliably starts) for the common cases this
/// hardening pass targets — backgrounding, tab-switch, and most navigations —
/// which is strictly better than the prior behavior of relying solely on the
/// 2s debounce timer happening to have already fired.
void installWebLifecycleFlush(void Function() onHide) {
  web.document.addEventListener(
    'visibilitychange',
    ((web.Event _) {
      if (web.document.visibilityState == 'hidden') {
        onHide();
      }
    }).toJS,
  );

  web.window.addEventListener(
    'pagehide',
    ((web.Event _) {
      onHide();
    }).toJS,
  );
}
