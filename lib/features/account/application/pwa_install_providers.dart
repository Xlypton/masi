import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'pwa_install.dart';
import 'pwa_install_types.dart';

/// Snapshot [PwaInstallStatus] of this session's PWA-install affordances,
/// read once at provider construction via the conditional
/// `pwa_install.dart` backend (native/test: always inert; web: real
/// `window`/`navigator` reads — see `pwa_install_web.dart`).
///
/// A plain (non-family, non-refreshing) [Provider] — matching this seam's
/// scope: these globals are set once at page load (`beforeinstallprompt`
/// fires before the Flutter app is interactive) and never change mid-session
/// in a way the Account screen needs to react to live. Tests override it
/// directly via `pwaInstallStatusProvider.overrideWithValue(...)` rather
/// than going through either backend.
final pwaInstallStatusProvider = Provider<PwaInstallStatus>((ref) {
  return PwaInstallStatus(
    isStandalone: pwaIsStandalone(),
    canPrompt: pwaCanPromptInstall(),
    platform: pwaPlatform(),
  );
});
