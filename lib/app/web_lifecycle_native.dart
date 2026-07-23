/// No-op on native platforms (iOS/Android/desktop) and plain-Dart tests —
/// picked whenever `dart.library.js_interop` is unavailable (see
/// `web_lifecycle.dart`'s facade doc). Native apps already get a reliable
/// `AppLifecycleState.paused` callback from the OS (wired in `app.dart`'s
/// `WidgetsBindingObserver.didChangeAppLifecycleState`, which already calls
/// `SyncOrchestrator.onAppPaused()`), so there is nothing for a browser
/// tab-hide/close hook to add on this platform — [onHide] is accepted and
/// simply never called. This keeps native/iOS behavior bit-identical to
/// before this facade existed.
void installWebLifecycleFlush(void Function() onHide) {}
