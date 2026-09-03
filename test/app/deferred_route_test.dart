import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:masi/app/deferred_route.dart';

/// Covers the three behaviours [DeferredRoute] exists for, each of which fails
/// SILENTLY in production: a spinner that never resolves, a spinner frame on
/// every revisit to an already-loaded route (jank introduced by an
/// optimisation), and a load failure that strands the user with no way back
/// because the failure was cached.
void main() {
  setUp(DeferredRoute.resetForTest);
  tearDown(DeferredRoute.resetForTest);

  Widget host(Widget child) => MaterialApp(home: child);

  testWidgets('shows the pending state until the library loads, then the '
      'screen', (tester) async {
    final gate = Completer<void>();
    await tester.pumpWidget(
      host(
        DeferredRoute(
          name: 'a',
          load: () => gate.future,
          builder: (_) => const Text('loaded'),
        ),
      ),
    );

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('loaded'), findsNothing);

    gate.complete();
    await tester.pumpAndSettle();

    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text('loaded'), findsOneWidget);
  });

  testWidgets('a second visit to a loaded library builds synchronously, with '
      'no spinner frame', (tester) async {
    var loads = 0;
    Widget build() => host(
      DeferredRoute(
        name: 'a',
        load: () async => loads++,
        builder: (_) => const Text('loaded'),
      ),
    );

    await tester.pumpWidget(build());
    await tester.pumpAndSettle();
    expect(loads, 1);

    // Rebuild from scratch, as a fresh navigation to the same route would.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(build());

    // The FIRST frame is already the screen — this is the assertion that
    // `_loaded` is doing its job. `pump()` (not `pumpAndSettle`) is what makes
    // that observable.
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text('loaded'), findsOneWidget);
    expect(loads, 1, reason: 'loadLibrary should not be called again');
  });

  testWidgets('a failed load offers a retry that can actually succeed', (
    tester,
  ) async {
    var attempts = 0;
    await tester.pumpWidget(
      host(
        DeferredRoute(
          name: 'a',
          load: () async {
            attempts++;
            if (attempts == 1) throw StateError('offline');
          },
          builder: (_) => const Text('loaded'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('deferred-route-retry')), findsOneWidget);
    expect(find.text('loaded'), findsNothing);

    await tester.tap(find.byKey(const Key('deferred-route-retry')));
    await tester.pumpAndSettle();

    expect(attempts, 2);
    expect(find.text('loaded'), findsOneWidget);
  });

  testWidgets('a failure is not cached as loaded', (tester) async {
    var attempts = 0;
    Widget build() => host(
      DeferredRoute(
        name: 'a',
        load: () async {
          attempts++;
          throw StateError('offline');
        },
        builder: (_) => const Text('loaded'),
      ),
    );

    await tester.pumpWidget(build());
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('deferred-route-retry')), findsOneWidget);

    // Navigating away and back must retry rather than either replaying the
    // error forever or — worse — treating the library as present and building
    // a screen whose code was never fetched.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(build());
    await tester.pumpAndSettle();

    expect(attempts, 2);
    expect(find.byKey(const Key('deferred-route-retry')), findsOneWidget);
  });
}
