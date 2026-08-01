import 'dart:async';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

/// Real web implementation (see `online_events.dart`'s facade doc): emits
/// `true` on every `online` window event and `false` on every `offline` one.
///
/// Listeners are wired LAZILY — added on the first subscription, removed again
/// when the last subscriber cancels — so an unlistened stream leaves no
/// `window` listener behind and a disposed `SyncOrchestrator` detaches cleanly.
/// Broadcast, because these are ambient page events with no backpressure and
/// no meaningful buffering: an event that fires while nobody is listening is
/// correctly dropped.
///
/// HONEST LIMITATION (same shape as `web_lifecycle_web.dart`'s): `online` is a
/// heuristic — the browser reports it for any network interface being up, so a
/// captive portal still says "online". That is fine for this use: the event
/// only ever TRIGGERS a sync attempt, and the attempt itself is what
/// establishes real reachability (§1d's probe). A false positive costs one
/// failed push that the backoff loop retries; a missed event costs nothing,
/// because the debounce/resume triggers still exist.
Stream<bool> onlineEvents() {
  final controller = StreamController<bool>.broadcast();
  final onOnline = ((web.Event _) => controller.add(true)).toJS;
  final onOffline = ((web.Event _) => controller.add(false)).toJS;
  controller
    ..onListen = () {
      web.window.addEventListener('online', onOnline);
      web.window.addEventListener('offline', onOffline);
    }
    ..onCancel = () {
      web.window.removeEventListener('online', onOnline);
      web.window.removeEventListener('offline', onOffline);
    };
  return controller.stream;
}
