/// No-op on native platforms (iOS/Android/desktop) and plain-Dart tests —
/// picked whenever `dart.library.js_interop` is unavailable (see
/// `online_events.dart`'s facade doc).
///
/// Native connectivity transitions come from `connectivity_plus`'s
/// `Connectivity.onConnectivityChanged` instead (see
/// `SystemConnectivityService.statusChanges`), so there is nothing for a
/// browser event hook to contribute here: this stream never emits and closes
/// immediately.
Stream<bool> onlineEvents() => const Stream<bool>.empty();
