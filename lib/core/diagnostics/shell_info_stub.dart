import 'shell_info_types.dart';

/// Inert fallback used on native (iOS/Android/desktop) and in plain-Dart
/// `flutter test`, i.e. whenever `dart.library.js_interop` is unavailable (see
/// `shell_info.dart`'s facade doc).
///
/// There is no service worker outside a browser, so this always answers
/// [ShellInfo.notApplicable] — whose [ShellInfo.supported] is `false`, which
/// the UI renders as "not applicable" rather than as an absent or failed
/// shell. Never throws, touches nothing, and completes synchronously in a
/// `Future.value`, so a caller can await it on every platform without a
/// platform check of its own.
Future<ShellInfo> readShellInfo() async => ShellInfo.notApplicable;
