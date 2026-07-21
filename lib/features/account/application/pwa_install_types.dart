/// Which mobile OS family the running browser reports itself as, used only
/// to pick the right install AFFORDANCE (a real programmatic prompt vs. a
/// "how to add to Home Screen" hint) — see `pwa_install_web.dart`'s
/// `pwaPlatform`. Native builds never need this (there is no browser), so
/// `pwa_install_stub.dart` always reports [other].
enum PwaPlatform { ios, android, other }

/// Snapshot of this browser session's PWA-install affordances, as read by
/// `pwa_install.dart`'s conditional backend (native/test: an inert stub;
/// web: real `window`/`navigator` reads — see `pwa_install_web.dart`).
///
/// Immutable and `const`-constructible so tests can build arbitrary
/// combinations directly (e.g. via
/// `pwaInstallStatusProvider.overrideWithValue(...)`) without going through
/// either backend.
class PwaInstallStatus {
  const PwaInstallStatus({
    required this.isStandalone,
    required this.canPrompt,
    required this.platform,
  });

  /// Whether the app is ALREADY running as an installed PWA (launched from
  /// the home screen / installed app list, not a browser tab) — e.g. Chrome
  /// on Android matching `display-mode: standalone`, or iOS Safari's
  /// `navigator.standalone`. When `true`, no install affordance should show
  /// at all: there is nothing left to install.
  final bool isStandalone;

  /// Whether the browser has a deferred native install prompt ready to fire
  /// programmatically (Chromium/Android's `beforeinstallprompt`). iOS Safari
  /// never sets this — it has no such API — so iOS always falls back to the
  /// "Add to Home Screen" hint instead.
  final bool canPrompt;

  /// Best-effort OS family sniff, used only to choose between the real
  /// prompt button ([canPrompt]) and the iOS manual-instructions hint.
  final PwaPlatform platform;
}
