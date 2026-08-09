import 'package:masi/app/install_banner.dart';
import 'package:masi/app/theme.dart';
import 'package:masi/features/account/application/pwa_install_providers.dart';
import 'package:masi/features/account/application/pwa_install_types.dart';
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
      'the dismiss control clears the 44x44 tap-target floor — MEASURED, not '
      'derived from VisualDensity arithmetic',
      (tester) async {
        // Regression pin. This control shipped under the floor while every
        // other button in the banner was raised to it, because its size was
        // reasoned about rather than measured: `IconButton`'s footprint is
        // its TAP TARGET, and `VisualDensity.compact` shrinks that target as
        // well as the visible box. The arithmetic was done wrong, and no test
        // would have caught it — so this asserts the RENDERED size.
        //
        // `tester.getSize` on the button returns its outermost box, which for
        // a Material button is the tap-target padding — i.e. exactly the
        // region a finger can hit, not the 18px glyph inside it.
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

        final size = tester.getSize(
          find.byKey(const Key('install-banner-dismiss')),
        );
        expect(
          size.width,
          greaterThanOrEqualTo(44.0),
          reason: 'the dismiss control is a real tap target, not a glyph',
        );
        expect(size.height, greaterThanOrEqualTo(44.0));
      },
    );

    testWidgets(
      "the action button keeps its 44pt floor too — the dismiss fix must not "
      'come at its expense',
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

        final size = tester.getSize(
          find.byKey(const Key('install-banner-action')),
        );
        expect(size.width, greaterThanOrEqualTo(44.0));
        expect(size.height, greaterThanOrEqualTo(44.0));
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
