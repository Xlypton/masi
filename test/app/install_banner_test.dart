import 'package:climbtopo/app/install_banner.dart';
import 'package:climbtopo/app/theme.dart';
import 'package:climbtopo/features/account/application/pwa_install_providers.dart';
import 'package:climbtopo/features/account/application/pwa_install_types.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Wraps [InstallBanner] in a [ProviderScope] carrying the given
/// [pwaInstallStatusProvider] override plus a [MaterialApp] with the real
/// [MasiTheme] — required because the banner reads `MasiColors.of(context)`,
/// which throws if no `MasiColors` extension is registered on the ambient
/// theme (mirrors `account_screen_test.dart`'s `_wrap`). A [Scaffold] hosts
/// it so the (untested) action button's `ScaffoldMessenger` lookup, and the
/// banner's own `SafeArea`, resolve exactly as they do under `NavShell`.
Widget _wrap(PwaInstallStatus status) {
  return ProviderScope(
    overrides: [pwaInstallStatusProvider.overrideWithValue(status)],
    child: MaterialApp(
      theme: MasiTheme.light,
      home: const Scaffold(body: InstallBanner()),
    ),
  );
}

void main() {
  group('InstallBanner (#59)', () {
    testWidgets(
      'shows the banner when a deferred install prompt is ready '
      '(canPrompt=true, not standalone)',
      (tester) async {
        await tester.pumpWidget(
          _wrap(
            const PwaInstallStatus(
              isStandalone: false,
              canPrompt: true,
              platform: PwaPlatform.other,
            ),
          ),
        );
        await tester.pump();

        expect(find.byKey(const Key('install-banner')), findsOneWidget);
        expect(find.byKey(const Key('install-banner-action')), findsOneWidget);
        expect(find.byKey(const Key('install-banner-dismiss')), findsOneWidget);
      },
    );

    testWidgets(
      'hides the banner when already installed (isStandalone=true) — nothing '
      'left to offer, even with canPrompt also true',
      (tester) async {
        await tester.pumpWidget(
          _wrap(
            const PwaInstallStatus(
              isStandalone: true,
              canPrompt: true,
              platform: PwaPlatform.android,
            ),
          ),
        );
        await tester.pump();

        expect(find.byKey(const Key('install-banner')), findsNothing);
      },
    );

    testWidgets(
      'hides the banner on the inert native/desktop status (canPrompt=false, '
      'platform other) — the stub must never render it off-web',
      (tester) async {
        await tester.pumpWidget(
          _wrap(
            const PwaInstallStatus(
              isStandalone: false,
              canPrompt: false,
              platform: PwaPlatform.other,
            ),
          ),
        );
        await tester.pump();

        expect(find.byKey(const Key('install-banner')), findsNothing);
      },
    );

    testWidgets(
      'shows the banner on iOS even when canPrompt=false (Safari has no '
      'programmatic install API, so the "how to" affordance still applies)',
      (tester) async {
        await tester.pumpWidget(
          _wrap(
            const PwaInstallStatus(
              isStandalone: false,
              canPrompt: false,
              platform: PwaPlatform.ios,
            ),
          ),
        );
        await tester.pump();

        expect(find.byKey(const Key('install-banner')), findsOneWidget);
        expect(find.byKey(const Key('install-banner-action')), findsOneWidget);
      },
    );

    testWidgets(
      'tapping dismiss collapses the banner for the rest of the session',
      (tester) async {
        await tester.pumpWidget(
          _wrap(
            const PwaInstallStatus(
              isStandalone: false,
              canPrompt: true,
              platform: PwaPlatform.other,
            ),
          ),
        );
        await tester.pump();

        expect(find.byKey(const Key('install-banner')), findsOneWidget);

        await tester.tap(find.byKey(const Key('install-banner-dismiss')));
        await tester.pump();

        expect(find.byKey(const Key('install-banner')), findsNothing);
      },
    );
  });
}
