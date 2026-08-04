import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:masi/app/theme.dart';
import 'package:masi/shared/presentation/masi_loading_indicator.dart';

/// Tests for `MasiLoadingIndicator` — the app's one spinner (the fallback for
/// when a skeleton genuinely cannot describe the content).
///
/// NOTE the pumping style throughout: a revealed indeterminate
/// `CircularProgressIndicator` animates forever, so `pumpAndSettle()` would
/// hang. Everything here uses explicit `tester.pump(duration)` — except the
/// reduced-motion test, which is precisely the case where the animation is
/// frozen and settling is therefore possible (and is asserted).
Widget _wrap(Widget child, {bool disableAnimations = false}) {
  return MediaQuery(
    data: MediaQueryData(disableAnimations: disableAnimations),
    child: MaterialApp(
      theme: MasiTheme.light,
      home: Scaffold(body: Center(child: child)),
    ),
  );
}

void main() {
  testWidgets('the spinner is withheld for the reveal delay, then appears', (
    tester,
  ) async {
    await tester.pumpWidget(_wrap(const MasiLoadingIndicator.standalone()));

    expect(find.byKey(MasiLoadingIndicator.spinnerKey), findsNothing);

    await tester.pump(const Duration(milliseconds: 170));
    expect(find.byKey(MasiLoadingIndicator.spinnerKey), findsNothing);

    await tester.pump(const Duration(milliseconds: 20));
    expect(find.byKey(MasiLoadingIndicator.spinnerKey), findsOneWidget);
  });

  testWidgets('isLoading: false renders the child and no spinner', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(
        const MasiLoadingIndicator.standalone(
          isLoading: false,
          child: Text('camera preview'),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('camera preview'), findsOneWidget);
    expect(find.byKey(MasiLoadingIndicator.spinnerKey), findsNothing);
  });

  testWidgets(
    'the child form keeps the spinner up for the minimum-visible hold after '
    'loading ends (anti-strobe), then swaps in the child',
    (tester) async {
      // Rebuilt with a different `isLoading` — the shape a real screen uses.
      await tester.pumpWidget(
        _wrap(
          const MasiLoadingIndicator.standalone(
            isLoading: true,
            child: Text('camera preview'),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.byKey(MasiLoadingIndicator.spinnerKey), findsOneWidget);

      await tester.pumpWidget(
        _wrap(
          const MasiLoadingIndicator.standalone(
            isLoading: false,
            child: Text('camera preview'),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));
      expect(
        find.byKey(MasiLoadingIndicator.spinnerKey),
        findsOneWidget,
        reason: 'ripped away the instant loading ended — that is the strobe',
      );

      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byKey(MasiLoadingIndicator.spinnerKey), findsNothing);
      expect(find.text('camera preview'), findsOneWidget);
    },
  );

  testWidgets('inline is exactly 20x20 so it fits a control without '
      'resizing it', (tester) async {
    await tester.pumpWidget(_wrap(const MasiLoadingIndicator.inline()));
    await tester.pump(const Duration(milliseconds: 200));

    expect(
      tester.getSize(find.byKey(MasiLoadingIndicator.spinnerKey)),
      const Size(
        MasiLoadingIndicator.inlineSize,
        MasiLoadingIndicator.inlineSize,
      ),
    );
  });

  testWidgets('standalone renders its label under the spinner', (tester) async {
    await tester.pumpWidget(
      _wrap(const MasiLoadingIndicator.standalone(label: 'Starting camera…')),
    );
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('Starting camera…'), findsOneWidget);
    expect(find.byKey(MasiLoadingIndicator.spinnerKey), findsOneWidget);
  });

  testWidgets(
    'reduced motion freezes the arc into a determinate sweep (still visible, '
    'no motion) — and the tree can therefore settle',
    (tester) async {
      await tester.pumpWidget(
        _wrap(
          const MasiLoadingIndicator.standalone(),
          disableAnimations: true,
        ),
      );
      await tester.pump(const Duration(milliseconds: 200));

      final indicator = tester.widget<CircularProgressIndicator>(
        find.byType(CircularProgressIndicator),
      );
      expect(
        indicator.value,
        isNotNull,
        reason: 'an indeterminate value would mean it is still spinning',
      );
      expect(find.byKey(MasiLoadingIndicator.spinnerKey), findsOneWidget);

      // Only possible because nothing is animating any more.
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('normal motion leaves the arc indeterminate (spinning)', (
    tester,
  ) async {
    await tester.pumpWidget(_wrap(const MasiLoadingIndicator.standalone()));
    await tester.pump(const Duration(milliseconds: 200));

    final indicator = tester.widget<CircularProgressIndicator>(
      find.byType(CircularProgressIndicator),
    );
    expect(indicator.value, isNull);
  });

  testWidgets('unmounted mid-reveal-delay without throwing', (tester) async {
    await tester.pumpWidget(_wrap(const MasiLoadingIndicator.standalone()));
    await tester.pump(const Duration(milliseconds: 100));

    await tester.pumpWidget(_wrap(const SizedBox.shrink()));
    await tester.pump(const Duration(milliseconds: 600));

    expect(tester.takeException(), isNull);
  });
}
