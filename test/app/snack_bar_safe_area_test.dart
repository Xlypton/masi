// Regression coverage for the global SnackBar safe-area fix: in an installed
// iOS PWA, `safe-area-inset-bottom` reports zero, so the default
// `SnackBarBehavior.fixed` (which wraps itself in `SafeArea(top: false)`,
// reading that same zero value) put every toast flush on the home
// indicator — the user specifically reported this about the delete
// confirmations ("Photo deleted", "Comment deleted", "Ascent deleted").
//
// The fix, `MasiTheme.withSnackBarSafeArea` (see its doc in theme.dart),
// switches every SnackBar to `SnackBarBehavior.floating` with an
// `insetPadding` computed from `masiBottomInset` — the same
// `max(deviceInset, standaloneFloor)` helper the nav bar and the topo
// canvas's route panel already use. This file proves the seam end to end
// with a REAL SnackBar shown through a REAL ScaffoldMessenger, not just the
// theme value in isolation, on a screen with no `bottomNavigationBar` (i.e.
// the "everywhere but the three nav-shell routes" case the bug report
// singles out — those three already looked right because `NavShell`'s own
// `Scaffold` sits above the floored nav bar).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:masi/app/theme.dart';
import 'package:masi/features/account/application/pwa_install_providers.dart';
import 'package:masi/features/account/application/pwa_install_types.dart';

/// Mirrors the exact seam `MasiApp.build` uses (`theme.dart`'s
/// `withSnackBarSafeArea` doc): a widget that has both a `BuildContext` and a
/// `WidgetRef` builds `MaterialApp`'s `theme` from them. Deliberately does
/// NOT go through `MasiApp`/`appRouter`/the database — this is a test of the
/// theming seam, not of routing or persistence, so it stays a plain
/// `Scaffold` with a button that shows a keyed `SnackBar`, exactly like any
/// of the ~70 real call sites this fix is not touching individually.
class _Harness extends ConsumerWidget {
  const _Harness();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return MaterialApp(
      theme: MasiTheme.withSnackBarSafeArea(MasiTheme.light, context, ref),
      home: Scaffold(
        // No `bottomNavigationBar` here on purpose — this is the "screen's
        // own Scaffold" world the bug report describes, not `NavShell`'s.
        body: Builder(
          builder: (innerContext) => Center(
            child: ElevatedButton(
              key: const Key('show-snackbar'),
              onPressed: () {
                ScaffoldMessenger.of(innerContext).showSnackBar(
                  const SnackBar(
                    key: Key('test-snackbar'),
                    content: Text('Photo deleted'),
                  ),
                );
              },
              child: const Text('show'),
            ),
          ),
        ),
      ),
    );
  }
}

Future<void> _showSnackBar(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('show-snackbar')));
  await tester.pumpAndSettle();
}

/// The screen height minus the visible SnackBar pill's own bottom edge —
/// i.e. how much clearance it actually has above the physical bottom of the
/// viewport.
///
/// Measures the innermost `Material` descendant of the keyed `SnackBar`,
/// NOT `find.byKey(Key('test-snackbar'))` directly: that Element's own
/// `renderObject` resolves to the `Dismissible`'s box, which is sized for
/// drag hit-testing and spans the full width/height of its slot regardless
/// of `insetPadding` — it is not the visually rendered pill, and measuring
/// it silently reports zero clearance even when the fix is working
/// (verified by hand: `Dismissible`'s rect bottom sat flush on the screen
/// edge while the `Material` 42px above it was exactly where the floored
/// inset put it).
double _bottomClearance(WidgetTester tester) {
  final screenHeight = tester.view.physicalSize.height / tester.view.devicePixelRatio;
  final materialFinder = find.descendant(
    of: find.byKey(const Key('test-snackbar')),
    matching: find.byType(Material),
  );
  final snackBarBottom = tester.getRect(materialFinder.last).bottom;
  return screenHeight - snackBarBottom;
}

void main() {
  group('MasiTheme.withSnackBarSafeArea', () {
    testWidgets(
      'standalone PWA + zero device inset: the SnackBar clears the home '
      'indicator via the standalone floor (32px), not the raw zero inset',
      (tester) async {
        tester.view.physicalSize = const Size(400, 800);
        tester.view.devicePixelRatio = 1.0;
        // The exact bug: an installed iOS PWA reports a zero bottom inset.
        tester.view.padding = const FakeViewPadding();
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPadding);

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              pwaInstallStatusProvider.overrideWithValue(
                const PwaInstallStatus(
                  isStandalone: true,
                  canPrompt: false,
                  platform: PwaPlatform.ios,
                ),
              ),
            ],
            child: const _Harness(),
          ),
        );

        await _showSnackBar(tester);

        // 10 = the M3 floating default's own bottom margin; 32 =
        // kStandaloneBottomFloor. See `withSnackBarSafeArea`'s doc.
        expect(
          _bottomClearance(tester),
          closeTo(42, 1.0),
          reason:
              'standalone + zero device inset must fall back to the '
              '32px standalone floor (plus the 10px default margin), '
              'clearing the home indicator instead of sitting flush on it',
        );
      },
    );

    testWidgets(
      'NOT standalone + zero device inset (e.g. a desktop browser tab): no '
      'dead space is added — the floor must be gated on standalone',
      (tester) async {
        tester.view.physicalSize = const Size(400, 800);
        tester.view.devicePixelRatio = 1.0;
        tester.view.padding = const FakeViewPadding();
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPadding);

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              pwaInstallStatusProvider.overrideWithValue(
                const PwaInstallStatus(
                  isStandalone: false,
                  canPrompt: false,
                  platform: PwaPlatform.other,
                ),
              ),
            ],
            child: const _Harness(),
          ),
        );

        await _showSnackBar(tester);

        expect(
          _bottomClearance(tester),
          closeTo(10, 1.0),
          reason:
              'a non-standalone context with a genuinely zero device inset '
              '(a desktop browser tab) must get only the 10px default '
              'margin, never the 32px standalone floor — that floor '
              'existing unconditionally would put dead space under every '
              "toast on a platform that has no home indicator to clear",
        );
      },
    );

    testWidgets(
      'NOT standalone + a real (non-zero) device inset: the real inset wins '
      'unchanged — the floor never double-counts on top of it',
      (tester) async {
        tester.view.physicalSize = const Size(400, 800);
        tester.view.devicePixelRatio = 1.0;
        // A real device inset (e.g. native iOS, or in-browser Safari before
        // install) that already correctly reports the home-indicator gap.
        tester.view.padding = const FakeViewPadding(bottom: 34);
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPadding);

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              pwaInstallStatusProvider.overrideWithValue(
                const PwaInstallStatus(
                  isStandalone: false,
                  canPrompt: false,
                  platform: PwaPlatform.ios,
                ),
              ),
            ],
            child: const _Harness(),
          ),
        );

        await _showSnackBar(tester);

        // 10 (default margin) + 34 (the real device inset) — `masiBottomInset`
        // takes `max(deviceInset, floor)`, and 34 already exceeds the 32px
        // floor, so the real value wins unchanged and nothing is lost.
        expect(
          _bottomClearance(tester),
          closeTo(44, 1.0),
          reason:
              'a real, already-correct device inset must pass through '
              'unchanged (plus the 10px default margin) — the floor is '
              'only a fallback for when the device reports zero',
        );
      },
    );
  });
}
