import 'package:climbtopo/app/theme.dart';
import 'package:climbtopo/shared/presentation/masi_shimmer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Tests for `MasiShimmer` — the animated "still loading" skeleton wired
/// into `PhotoImage`'s new `loadingPlaceholder` slot (#56). Pure-Flutter
/// widget (no dart:io/photo decode involved), so these are plain, fast
/// widget-tree assertions -- no `runAsync`/`_drain` needed.
Widget _wrap(Widget child, {bool disableAnimations = false}) {
  return MediaQuery(
    data: MediaQueryData(disableAnimations: disableAnimations),
    child: MaterialApp(
      theme: MasiTheme.light,
      home: Scaffold(
        body: SizedBox(width: 52, height: 52, child: child),
      ),
    ),
  );
}

void main() {
  testWidgets('renders inside its parent box with no exception', (
    tester,
  ) async {
    await tester.pumpWidget(_wrap(const MasiShimmer()));
    await tester.pump();

    expect(find.byType(MasiShimmer), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('keeps animating (repeats) across repeated frames with no '
      'exception', (tester) async {
    await tester.pumpWidget(_wrap(const MasiShimmer()));

    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 300));
    }

    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'disposes its AnimationController cleanly when removed from the tree '
    '(no leaked-ticker exception)',
    (tester) async {
      await tester.pumpWidget(_wrap(const MasiShimmer()));
      await tester.pump();

      await tester.pumpWidget(_wrap(const SizedBox.shrink()));
      await tester.pump();

      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'reduced motion (MediaQuery.disableAnimations) still renders a static '
    'frame with no exception -- never blank, never crashes',
    (tester) async {
      await tester.pumpWidget(
        _wrap(const MasiShimmer(), disableAnimations: true),
      );

      for (var i = 0; i < 3; i++) {
        await tester.pump(const Duration(milliseconds: 300));
      }

      expect(find.byType(MasiShimmer), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
