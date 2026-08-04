import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:masi/app/theme.dart';
import 'package:masi/shared/presentation/masi_async_view.dart';
import 'package:masi/shared/presentation/masi_loading_indicator.dart';
import 'package:masi/shared/presentation/masi_skeleton.dart';

/// Tests for `MasiAsyncView` — the replacement for
/// `asyncThing.when(loading: () => const Center(child:
/// CircularProgressIndicator()), ...)`.
///
/// These deliberately drive a REAL `FutureProvider` in a real
/// `ProviderContainer` rather than hand-building `AsyncValue`s: the whole point
/// of the widget is Riverpod v3's overlapping states (loading WITH a previous
/// value, error WITH a previous value), and `AsyncValue.copyWithPrevious` — the
/// only way to synthesise those — is `@internal`. Refreshing a real provider is
/// both legal and a far better test of the thing that will actually happen.
///
/// The skeleton shimmers forever, so `pumpAndSettle()` is banned here; every
/// wait is an explicit `tester.pump(duration)`.
///
/// **Delivery note (hard-won).** A Riverpod state change — a completed future,
/// an `invalidate` — does NOT reach the widget within the same
/// `tester.pump()`; the rebuild lands at the start of the FOLLOWING pump. So
/// always deliver with one or two bare `pump()`s before advancing the clock: a
/// `pump(const Duration(milliseconds: 200))` issued immediately after
/// `complete()` gives the gate 200 ms of "still loading" that the app never
/// actually spent, and the assertions come out backwards.

/// Retry is disabled on the container: Riverpod v3 retries failed providers on
/// a backoff by default, which would leave pending timers and re-run the
/// throwing body mid-assertion.
ProviderContainer _container() {
  final container = ProviderContainer(retry: (_, _) => null);
  addTearDown(container.dispose);
  return container;
}

Widget _wrap(
  ProviderContainer container,
  FutureProvider<List<String>> provider, {
  void Function()? onRetryHook,
  // Matches the widget's own default (off), so a test that wants the raw
  // exception text on screen has to say so — same as a real call site.
  bool showErrorDetail = false,
}) {
  return UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      theme: MasiTheme.light,
      home: Scaffold(
        body: Consumer(
          builder: (context, ref, _) => MasiAsyncView<List<String>>(
            value: ref.watch(provider),
            errorMessage: "Couldn't load your areas",
            showErrorDetail: showErrorDetail,
            onRetry: () {
              onRetryHook?.call();
              ref.invalidate(provider);
            },
            skeleton: (context) => const MasiSkeletonList.listRows(count: 3),
            data: (context, items) => ListView(
              children: [
                for (final item in items) Text(item, key: Key('row-$item')),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

void main() {
  group('first load', () {
    testWidgets(
      'no skeleton inside the reveal delay, and NOT an empty list either — '
      'the blank window is deliberate',
      (tester) async {
        final completer = Completer<List<String>>();
        final provider = FutureProvider<List<String>>((ref) => completer.future);
        await tester.pumpWidget(_wrap(_container(), provider));

        expect(find.byType(MasiSkeletonListRow), findsNothing);
        await tester.pump(const Duration(milliseconds: 150));
        expect(find.byType(MasiSkeletonListRow), findsNothing);

        completer.complete(const ['Alpha']);
        await tester.pump();
        await tester.pump();
        expect(find.byKey(const Key('row-Alpha')), findsOneWidget);
        expect(
          find.byType(MasiSkeletonListRow),
          findsNothing,
          reason: 'a load that beat the reveal delay must never flash',
        );
      },
    );

    testWidgets(
      'a skeleton that has only just been revealed is HELD past the arrival '
      'of data (anti-strobe), then swaps',
      (tester) async {
        final completer = Completer<List<String>>();
        final provider = FutureProvider<List<String>>(
          (ref) => completer.future,
        );
        await tester.pumpWidget(_wrap(_container(), provider));

        await tester.pump(const Duration(milliseconds: 190));
        expect(find.byType(MasiSkeletonListRow), findsNWidgets(3));

        // Data lands ~10ms after the reveal: the worst case.
        completer.complete(const ['Alpha']);
        await tester.pump();
        await tester.pump();
        expect(
          find.byType(MasiSkeletonListRow),
          findsNWidgets(3),
          reason: 'skeleton ripped away one frame after appearing — a strobe',
        );

        await tester.pump(const Duration(milliseconds: 200));
        expect(find.byType(MasiSkeletonListRow), findsNWidgets(3));

        // Hold elapsed.
        await tester.pump(const Duration(milliseconds: 400));
        expect(find.byType(MasiSkeletonListRow), findsNothing);
        expect(find.byKey(const Key('row-Alpha')), findsOneWidget);
      },
    );

    testWidgets('a slow first load reveals the skeleton, then swaps in data', (
      tester,
    ) async {
      final completer = Completer<List<String>>();
      final provider = FutureProvider<List<String>>((ref) => completer.future);
      await tester.pumpWidget(_wrap(_container(), provider));

      await tester.pump(const Duration(milliseconds: 200));
      expect(find.byType(MasiSkeletonListRow), findsNWidgets(3));

      completer.complete(const ['Alpha', 'Bravo']);
      // Past the minimum-visible hold, so the skeleton is allowed to go.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));

      expect(find.byType(MasiSkeletonListRow), findsNothing);
      expect(find.byKey(const Key('row-Alpha')), findsOneWidget);
      expect(find.byKey(const Key('row-Bravo')), findsOneWidget);
    });
  });

  group('refresh over existing data', () {
    testWidgets(
      'a refresh NEVER blanks the data — the rows stay and a hairline cue '
      'appears instead of a skeleton',
      (tester) async {
        final completers = [
          Completer<List<String>>(),
          Completer<List<String>>(),
        ];
        var build = 0;
        final provider = FutureProvider<List<String>>(
          (ref) => completers[build++].future,
        );
        final container = _container();
        await tester.pumpWidget(_wrap(container, provider));

        completers[0].complete(const ['Alpha']);
        await tester.pump();
        await tester.pump();
        expect(find.byKey(const Key('row-Alpha')), findsOneWidget);

        // The case a plain `.when()` gets wrong: isLoading true AND hasValue
        // true.
        container.invalidate(provider);
        await tester.pump();
        expect(
          find.byKey(const Key('row-Alpha')),
          findsOneWidget,
          reason: 'the refresh wiped a list the user was reading',
        );
        expect(
          find.byType(MasiSkeletonListRow),
          findsNothing,
          reason: 'a skeleton during a refresh IS the blanking bug',
        );

        // The cue is gated like everything else: nothing at 150ms, up by 200.
        expect(find.byKey(MasiAsyncView.refreshCueKey), findsNothing);
        await tester.pump(const Duration(milliseconds: 200));
        expect(find.byKey(MasiAsyncView.refreshCueKey), findsOneWidget);
        expect(find.byKey(const Key('row-Alpha')), findsOneWidget);

        completers[1].complete(const ['Alpha', 'Bravo']);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 600));
        expect(find.byKey(MasiAsyncView.refreshCueKey), findsNothing);
        expect(find.byKey(const Key('row-Bravo')), findsOneWidget);
      },
    );

    testWidgets('a fast refresh shows no cue at all', (tester) async {
      final completers = [Completer<List<String>>(), Completer<List<String>>()];
      var build = 0;
      final provider = FutureProvider<List<String>>(
        (ref) => completers[build++].future,
      );
      final container = _container();
      await tester.pumpWidget(_wrap(container, provider));

      completers[0].complete(const ['Alpha']);
      await tester.pump();
      await tester.pump();

      container.invalidate(provider);
      // Bare pump first: see the "delivery" note at the top of this file —
      // advancing the clock before the new state has been delivered would
      // credit the gate with time the widget did not actually spend loading.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      completers[1].complete(const ['Alpha']);
      await tester.pump();
      await tester.pump();
      // Loading ended at 100ms — inside the reveal delay — so no cue may ever
      // appear, however long we wait.
      await tester.pump(const Duration(milliseconds: 800));

      expect(find.byKey(MasiAsyncView.refreshCueKey), findsNothing);
    });
  });

  group('failure', () {
    testWidgets('a first-load failure says what failed and offers a retry that '
        'actually re-runs the load', (tester) async {
      var build = 0;
      var retries = 0;
      final provider = FutureProvider<List<String>>((ref) async {
        if (build++ == 0) throw StateError('boom');
        return const ['Alpha'];
      });
      await tester.pumpWidget(
        _wrap(
          _container(),
          provider,
          onRetryHook: () => retries++,
          showErrorDetail: true,
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(find.byKey(MasiAsyncView.errorKey), findsOneWidget);
      expect(find.text("Couldn't load your areas"), findsOneWidget);
      expect(find.textContaining('boom'), findsOneWidget);
      expect(find.byKey(MasiAsyncView.retryKey), findsOneWidget);

      await tester.tap(find.byKey(MasiAsyncView.retryKey));
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));

      expect(retries, 1);
      expect(find.byKey(const Key('row-Alpha')), findsOneWidget);
      expect(find.byKey(MasiAsyncView.errorKey), findsNothing);
    });

    testWidgets(
      'a failed REFRESH keeps the data on screen and reports the failure '
      'non-destructively',
      (tester) async {
        var build = 0;
        final provider = FutureProvider<List<String>>((ref) async {
          if (build++ == 0) return const ['Alpha'];
          throw StateError('offline');
        });
        final container = _container();
        await tester.pumpWidget(_wrap(container, provider));
        await tester.pump();
        await tester.pump();
        expect(find.byKey(const Key('row-Alpha')), findsOneWidget);

        container.invalidate(provider);
        await tester.pump();
        await tester.pump();

        expect(
          find.byKey(const Key('row-Alpha')),
          findsOneWidget,
          reason: 'a failed refresh threw away data that was still good',
        );
        expect(find.byKey(MasiAsyncView.staleErrorKey), findsOneWidget);
        expect(find.byKey(MasiAsyncView.errorKey), findsNothing);
        expect(find.byKey(MasiAsyncView.retryKey), findsOneWidget);
      },
    );

    testWidgets('the raw exception text is hidden BY DEFAULT — a caller has to '
        'opt in to putting developer text in front of a user', (tester) async {
      final provider = FutureProvider<List<String>>(
        (ref) async => throw StateError('SqliteException(1): no such column'),
      );
      // Built by hand rather than via `_wrap`, because the point is the
      // parameter being ABSENT: `_wrap` passes it through explicitly and would
      // therefore prove nothing about the widget's own default.
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: _container(),
          child: MaterialApp(
            theme: MasiTheme.light,
            home: Scaffold(
              body: Consumer(
                builder: (context, ref, _) => MasiAsyncView<List<String>>(
                  value: ref.watch(provider),
                  errorMessage: "Couldn't load your areas",
                  onRetry: () => ref.invalidate(provider),
                  skeleton: (context) => const MasiSkeletonList.listRows(),
                  data: (context, items) => const SizedBox.shrink(),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(find.byKey(MasiAsyncView.errorKey), findsOneWidget);
      expect(find.text("Couldn't load your areas"), findsOneWidget);
      expect(find.textContaining('SqliteException'), findsNothing);
    });

    testWidgets('the Try-again button shows a pending cue while an async retry '
        'runs, and swallows a second tap', (tester) async {
      final second = Completer<List<String>>();
      var builds = 0;
      final provider = FutureProvider<List<String>>((ref) {
        if (builds++ == 0) throw StateError('boom');
        return second.future;
      });
      var retries = 0;
      final container = _container();
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: MasiTheme.light,
            home: Scaffold(
              body: Consumer(
                builder: (context, ref, _) => MasiAsyncView<List<String>>(
                  value: ref.watch(provider),
                  errorMessage: "Couldn't load your areas",
                  // The async shape: the button can only cue what it can await.
                  onRetry: () {
                    retries++;
                    return ref.refresh(provider.future);
                  },
                  skeleton: (context) => const MasiSkeletonList.listRows(),
                  data: (context, items) => const SizedBox.shrink(),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(find.byKey(MasiAsyncView.errorKey), findsOneWidget);

      await tester.tap(find.byKey(MasiAsyncView.retryKey));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      expect(
        find.byKey(MasiLoadingIndicator.spinnerKey),
        findsOneWidget,
        reason: 'a retry is a network pull; a dead-looking button gets tapped '
            'again',
      );

      await tester.tap(find.byKey(MasiAsyncView.retryKey), warnIfMissed: false);
      await tester.pump();
      expect(retries, 1, reason: 'the second tap must be swallowed');

      second.complete(const ['Alpha']);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
    });

    testWidgets('showErrorDetail: true prints the raw exception text', (
      tester,
    ) async {
      final provider = FutureProvider<List<String>>(
        (ref) async => throw StateError('boom'),
      );
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: _container(),
          child: MaterialApp(
            theme: MasiTheme.light,
            home: Scaffold(
              body: Consumer(
                builder: (context, ref, _) => MasiAsyncView<List<String>>(
                  value: ref.watch(provider),
                  errorMessage: 'Nope',
                  showErrorDetail: true,
                  onRetry: () => ref.invalidate(provider),
                  skeleton: (context) => const MasiSkeletonList.listRows(),
                  data: (context, items) => const SizedBox.shrink(),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(find.text('Nope'), findsOneWidget);
      expect(find.textContaining('boom'), findsOneWidget);
    });
  });

  group('reduced motion', () {
    testWidgets('the refresh cue freezes instead of travelling', (tester) async {
      final completers = [Completer<List<String>>(), Completer<List<String>>()];
      var build = 0;
      final provider = FutureProvider<List<String>>(
        (ref) => completers[build++].future,
      );
      final container = _container();
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: _wrap(container, provider),
        ),
      );

      completers[0].complete(const ['Alpha']);
      await tester.pump();
      await tester.pump();

      container.invalidate(provider);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      final bar = tester.widget<LinearProgressIndicator>(
        find.byType(LinearProgressIndicator),
      );
      expect(bar.value, isNotNull);
      completers[1].complete(const ['Alpha']);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
    });
  });
}
