// Widget tests for `masi_dialogs.dart`'s bottom-inset fix: in an installed
// iOS PWA, `MediaQuery.padding.bottom` is always zero (the platform never
// reports a home-indicator inset), so `showMasiActionSheet`'s own
// `CupertinoActionSheet` — whose only built-in protection is
// `SafeArea(minimum: bottom 8)` — used to land just 8px above the home
// indicator. `showMasiActionSheet` now overrides the ambient bottom padding
// to `masiBottomInset`'s floor before building the sheet, so the built-in
// `SafeArea` maxes against 32px instead of the real (zero) device inset.
//
// Verified via pixel geometry (the cancel button's distance from the bottom
// of the screen) rather than reading a descendant's `MediaQuery.padding`:
// `SafeArea` CONSUMES the padding it applies for everything below it in the
// tree (so a nested widget doesn't re-apply the same inset), so a
// descendant of `CupertinoActionSheet`'s own internal `SafeArea` always
// reads zero regardless of the floor — that would only prove SafeArea
// exists, not that our override reached it. Measuring the actual rendered
// position is what proves the override changed real layout.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:masi/app/theme.dart';
import 'package:masi/features/account/application/pwa_install_providers.dart';
import 'package:masi/features/account/application/pwa_install_types.dart';
import 'package:masi/shared/presentation/bottom_safe_inset.dart';
import 'package:masi/shared/presentation/masi_dialogs.dart';

const Size _screenSize = Size(400, 800);

ProviderContainer _makeContainer({required bool isStandalone}) {
  final container = ProviderContainer(
    overrides: [
      pwaInstallStatusProvider.overrideWithValue(
        PwaInstallStatus(
          isStandalone: isStandalone,
          canPrompt: false,
          platform: PwaPlatform.other,
        ),
      ),
    ],
  );
  return container;
}

Future<void> _pumpAndOpen(WidgetTester tester, ProviderContainer container) async {
  tester.view.physicalSize = _screenSize;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: MasiTheme.light,
        home: Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              key: const Key('open'),
              onPressed: () => showMasiActionSheet<String>(
                context,
                sheetKey: const Key('sheet'),
                cancelKey: const Key('cancel'),
                actions: const [
                  MasiSheetAction(
                    key: Key('delete-action'),
                    label: 'Delete',
                    value: 'delete',
                    isDestructive: true,
                  ),
                ],
              ),
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    ),
  );

  await tester.tap(find.byKey(const Key('open')));
  await tester.pumpAndSettle();
}

/// The gap between the Cancel button's bottom edge and the bottom of the
/// screen — i.e. the safe-area clearance the sheet actually rendered with.
double _cancelBottomClearance(WidgetTester tester) =>
    _screenSize.height - tester.getBottomLeft(find.byKey(const Key('cancel'))).dy;

void main() {
  group('showMasiActionSheet — standalone-PWA bottom-inset floor (row 17)', () {
    testWidgets(
      'in a standalone PWA (zero device inset), the sheet clears the '
      "bottom of the screen by the app's 32px floor — not Cupertino's own "
      '8px minimum',
      (tester) async {
        final container = _makeContainer(isStandalone: true);
        addTearDown(container.dispose);

        await _pumpAndOpen(tester, container);

        expect(find.byKey(const Key('sheet')), findsOneWidget);
        expect(
          _cancelBottomClearance(tester),
          closeTo(kStandaloneBottomFloor, 0.5),
          reason:
              "the sheet's own SafeArea(minimum: 8) must max against the "
              'overridden 32px floor, not fall back to its own minimum',
        );
      },
    );

    testWidgets(
      'NOT running standalone (a normal browser tab, or native with a real '
      'device inset of zero): no floor is injected, so the sheet falls back '
      "to Cupertino's own 8px minimum — the fix must not force 32px "
      'unconditionally on every platform',
      (tester) async {
        final container = _makeContainer(isStandalone: false);
        addTearDown(container.dispose);

        await _pumpAndOpen(tester, container);

        expect(_cancelBottomClearance(tester), closeTo(8.0, 0.5));
      },
    );

    testWidgets(
      'the action sheet still resolves to the tapped value with the floor '
      'applied — the MediaQuery override does not interfere with normal use',
      (tester) async {
        final container = _makeContainer(isStandalone: true);
        addTearDown(container.dispose);

        String? result;
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              theme: MasiTheme.light,
              home: Scaffold(
                body: Builder(
                  builder: (context) => ElevatedButton(
                    key: const Key('open'),
                    onPressed: () async {
                      result = await showMasiActionSheet<String>(
                        context,
                        actions: const [
                          MasiSheetAction(
                            key: Key('delete-action'),
                            label: 'Delete',
                            value: 'delete',
                            isDestructive: true,
                          ),
                        ],
                      );
                    },
                    child: const Text('Open'),
                  ),
                ),
              ),
            ),
          ),
        );

        await tester.tap(find.byKey(const Key('open')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('delete-action')));
        await tester.pumpAndSettle();

        expect(result, 'delete');
      },
    );
  });
}
