import 'pwa_install_types.dart';

/// Fallback used on native (iOS/Android/desktop) and in plain Dart VM tests,
/// where there is no browser/`window` to read at all — a PWA install
/// affordance never applies. Always inert: never standalone, never able to
/// prompt, platform always [PwaPlatform.other]. Mirrors
/// `lib/core/platform/ar_support_stub.dart`'s always-`false` shape.
bool pwaIsStandalone() => false;

/// See [pwaIsStandalone] — no browser, so never able to prompt an install.
bool pwaCanPromptInstall() => false;

/// See [pwaIsStandalone] — no browser to sniff a user agent from.
PwaPlatform pwaPlatform() => PwaPlatform.other;

/// See [pwaIsStandalone] — nothing to prompt; always resolves to "not
/// accepted".
Future<bool> pwaPromptInstall() async => false;
