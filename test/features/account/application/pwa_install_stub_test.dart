import 'package:climbtopo/features/account/application/pwa_install.dart';
import 'package:climbtopo/features/account/application/pwa_install_types.dart';
import 'package:flutter_test/flutter_test.dart';

/// Verifies the native/test PWA-install backend
/// (`pwa_install_stub.dart`, reached here via the `pwa_install.dart` barrel
/// since plain-VM `flutter_test` has no `dart.library.js_interop`) is
/// completely inert — a PWA install affordance is a web-only concern and
/// must never do anything on native/in tests.
void main() {
  group('pwa_install stub backend', () {
    test('pwaIsStandalone is always false', () {
      expect(pwaIsStandalone(), isFalse);
    });

    test('pwaCanPromptInstall is always false', () {
      expect(pwaCanPromptInstall(), isFalse);
    });

    test('pwaPlatform is always PwaPlatform.other', () {
      expect(pwaPlatform(), PwaPlatform.other);
    });

    test('pwaPromptInstall always resolves to false', () async {
      expect(await pwaPromptInstall(), isFalse);
    });
  });

  group('PwaInstallStatus', () {
    test('const constructor stores all three fields', () {
      const status = PwaInstallStatus(
        isStandalone: true,
        canPrompt: false,
        platform: PwaPlatform.ios,
      );

      expect(status.isStandalone, isTrue);
      expect(status.canPrompt, isFalse);
      expect(status.platform, PwaPlatform.ios);
    });

    test('two instances with identical fields are usable independently '
        '(const canonicalization)', () {
      const a = PwaInstallStatus(
        isStandalone: false,
        canPrompt: true,
        platform: PwaPlatform.android,
      );
      const b = PwaInstallStatus(
        isStandalone: false,
        canPrompt: true,
        platform: PwaPlatform.android,
      );

      expect(a.isStandalone, b.isStandalone);
      expect(a.canPrompt, b.canPrompt);
      expect(a.platform, b.platform);
    });
  });
}
