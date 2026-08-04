import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:masi/app/theme.dart';
import 'package:masi/shared/presentation/masi_loading_gate.dart';

/// Tests for `MasiLoadingGate` — the anti-flash / anti-strobe timing engine
/// behind every loading affordance in the app.
///
/// These are the revert-proof tests for the two behaviours the whole loading
/// system rests on: nothing may appear inside the reveal delay, and nothing
/// may vanish inside the minimum-visible hold. Both were verified to FAIL
/// against a deliberately-broken gate (reveal made immediate / hold removed)
/// before being committed.
const _loadingKey = Key('gate-loading');
const _contentKey = Key('gate-content');

Widget _wrap(
  ValueNotifier<bool> loading, {
  Duration? revealDelay,
  Duration? minVisible,
}) {
  return MaterialApp(
    theme: MasiTheme.light,
    home: Scaffold(
      body: ValueListenableBuilder<bool>(
        valueListenable: loading,
        builder: (context, isLoading, _) => MasiLoadingGate(
          isLoading: isLoading,
          revealDelay: revealDelay ?? MasiMotion.loadingRevealDelay,
          minVisible: minVisible ?? MasiMotion.loadingMinVisible,
          // Deliberately NOT a shimmer/spinner: this file tests the timing,
          // and a plain Text keeps the tree free of endless animations so a
          // failure here is unambiguously a timing failure.
          builder: (context, showLoading) => showLoading
              ? const Text('loading', key: _loadingKey)
              : const Text('content', key: _contentKey),
        ),
      ),
    ),
  );
}

void main() {
  group('MasiMotion loading tokens', () {
    test('the reveal delay stays inside the anti-flash window', () {
      // Below ~150ms a fast local read still visibly flickers; above ~200ms a
      // genuinely slow load sits on unexplained blank space.
      expect(
        MasiMotion.loadingRevealDelay.inMilliseconds,
        inInclusiveRange(150, 200),
      );
    });

    test('the minimum-visible hold stays inside the anti-strobe window', () {
      expect(
        MasiMotion.loadingMinVisible.inMilliseconds,
        inInclusiveRange(400, 500),
      );
    });

    test('the hold outlasts the delay, or the hold would be pointless', () {
      expect(
        MasiMotion.loadingMinVisible,
        greaterThan(MasiMotion.loadingRevealDelay),
      );
    });
  });

  group('reveal delay (anti-flash)', () {
    testWidgets('nothing is shown for the whole reveal delay', (tester) async {
      final loading = ValueNotifier(true);
      addTearDown(loading.dispose);

      await tester.pumpWidget(_wrap(loading));

      // First frame: loading is already true, and still nothing.
      expect(find.byKey(_loadingKey), findsNothing);
      expect(find.byKey(_contentKey), findsOneWidget);

      // 170ms in — one frame short of the 180ms token.
      await tester.pump(const Duration(milliseconds: 170));
      expect(find.byKey(_loadingKey), findsNothing);

      // Past it.
      await tester.pump(const Duration(milliseconds: 20));
      expect(find.byKey(_loadingKey), findsOneWidget);
      expect(find.byKey(_contentKey), findsNothing);
    });

    testWidgets(
      'a load that finishes inside the reveal window paints NO loading state '
      'at all, ever',
      (tester) async {
        final loading = ValueNotifier(true);
        addTearDown(loading.dispose);

        await tester.pumpWidget(_wrap(loading));
        await tester.pump(const Duration(milliseconds: 120));
        expect(find.byKey(_loadingKey), findsNothing);

        // Done at 120ms — inside the delay.
        loading.value = false;
        await tester.pump();
        expect(find.byKey(_loadingKey), findsNothing);

        // And it must never turn up late, either.
        for (var i = 0; i < 6; i++) {
          await tester.pump(const Duration(milliseconds: 200));
          expect(find.byKey(_loadingKey), findsNothing);
        }
      },
    );

    testWidgets('Duration.zero reveals on the first frame, no timer', (
      tester,
    ) async {
      final loading = ValueNotifier(true);
      addTearDown(loading.dispose);

      await tester.pumpWidget(
        _wrap(loading, revealDelay: Duration.zero, minVisible: Duration.zero),
      );

      expect(find.byKey(_loadingKey), findsOneWidget);
    });
  });

  group('minimum visible (anti-strobe)', () {
    testWidgets(
      'once revealed the affordance is held even though loading has ended',
      (tester) async {
        final loading = ValueNotifier(true);
        addTearDown(loading.dispose);

        await tester.pumpWidget(_wrap(loading));
        await tester.pump(const Duration(milliseconds: 200));
        expect(find.byKey(_loadingKey), findsOneWidget);

        // Data lands 10ms after the reveal — the exact strobe case.
        await tester.pump(const Duration(milliseconds: 10));
        loading.value = false;
        await tester.pump();
        expect(
          find.byKey(_loadingKey),
          findsOneWidget,
          reason: 'hidden immediately on data arrival — this is the strobe',
        );

        // Still held two thirds of the way through.
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.byKey(_loadingKey), findsOneWidget);

        // Hold elapsed (450ms from the reveal): now it may go.
        await tester.pump(const Duration(milliseconds: 200));
        expect(find.byKey(_loadingKey), findsNothing);
        expect(find.byKey(_contentKey), findsOneWidget);
      },
    );

    testWidgets('a load still running when the hold expires keeps the '
        'affordance up', (tester) async {
      final loading = ValueNotifier(true);
      addTearDown(loading.dispose);

      await tester.pumpWidget(_wrap(loading));
      await tester.pump(const Duration(milliseconds: 200));

      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 200));
        expect(find.byKey(_loadingKey), findsOneWidget);
      }

      loading.value = false;
      await tester.pump();
      // The hold expired long ago, so this hide is immediate.
      expect(find.byKey(_loadingKey), findsNothing);
    });

    testWidgets('a second load after the first reveals again, delayed again', (
      tester,
    ) async {
      final loading = ValueNotifier(true);
      addTearDown(loading.dispose);

      await tester.pumpWidget(_wrap(loading));
      await tester.pump(const Duration(milliseconds: 200));
      loading.value = false;
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byKey(_loadingKey), findsNothing);

      loading.value = true;
      await tester.pump();
      expect(find.byKey(_loadingKey), findsNothing);
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.byKey(_loadingKey), findsOneWidget);
    });
  });

  group('lifecycle', () {
    testWidgets(
      'disposed mid-reveal-delay: the pending timer must not setState on a '
      'dead State',
      (tester) async {
        final loading = ValueNotifier(true);
        addTearDown(loading.dispose);

        await tester.pumpWidget(_wrap(loading));
        await tester.pump(const Duration(milliseconds: 100));

        // Pop the screen while the reveal timer is still counting.
        await tester.pumpWidget(
          const MaterialApp(home: Scaffold(body: SizedBox.shrink())),
        );
        await tester.pump(const Duration(milliseconds: 500));

        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'disposed mid-hold: the pending hold timer must not setState either',
      (tester) async {
        final loading = ValueNotifier(true);
        addTearDown(loading.dispose);

        await tester.pumpWidget(_wrap(loading));
        await tester.pump(const Duration(milliseconds: 200));
        expect(find.byKey(_loadingKey), findsOneWidget);
        loading.value = false;

        await tester.pumpWidget(
          const MaterialApp(home: Scaffold(body: SizedBox.shrink())),
        );
        await tester.pump(const Duration(milliseconds: 800));

        expect(tester.takeException(), isNull);
      },
    );
  });
}
