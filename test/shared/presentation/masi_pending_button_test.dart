import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:masi/app/theme.dart';
import 'package:masi/shared/presentation/masi_loading_indicator.dart';
import 'package:masi/shared/presentation/masi_pending_button.dart';

/// Tests for `MasiPendingButton` — the fix for the app's nine double-tappable
/// async buttons.
///
/// While pending the button holds a live spinner, so `pumpAndSettle()` is
/// banned here; every wait is an explicit `tester.pump(duration)`.
const _buttonKey = Key('pending-button');

Widget _wrap(Widget child) => MaterialApp(
  theme: MasiTheme.light,
  home: Scaffold(body: Center(child: child)),
);

void main() {
  group('single-shot behaviour', () {
    testWidgets(
      'taps arriving while the action is in flight are swallowed — this is '
      'the double-publish/double-log bug',
      (tester) async {
        final completer = Completer<void>();
        var calls = 0;
        await tester.pumpWidget(
          _wrap(
            MasiPendingButton.filled(
              key: _buttonKey,
              onPressed: () {
                calls++;
                return completer.future;
              },
              child: const Text('Publish topo'),
            ),
          ),
        );

        await tester.tap(find.byKey(_buttonKey));
        await tester.pump();
        expect(calls, 1);

        // The impatient user, twice more, well before anything resolves.
        await tester.tap(find.byKey(_buttonKey), warnIfMissed: false);
        await tester.pump();
        await tester.tap(find.byKey(_buttonKey), warnIfMissed: false);
        await tester.pump(const Duration(milliseconds: 300));
        expect(calls, 1, reason: 'a second run of the action got through');

        completer.complete();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 600));

        // Once settled it is a normal button again.
        await tester.tap(find.byKey(_buttonKey));
        await tester.pump();
        expect(calls, 2);
      },
    );

    testWidgets(
      'TWO taps in the SAME frame run the action once — the in-flight flag, '
      'not the disable, is what catches this',
      (tester) async {
        final completer = Completer<void>();
        var calls = 0;
        await tester.pumpWidget(
          _wrap(
            MasiPendingButton.filled(
              key: _buttonKey,
              onPressed: () {
                calls++;
                return completer.future;
              },
              child: const Text('Publish topo'),
            ),
          ),
        );

        // No pump in between: the button has NOT rebuilt yet, so it is still
        // the enabled widget and both taps reach the handler. This is the real
        // double-tap — a fast double-press inside one frame — and the only
        // thing that can stop the second one is the synchronous guard.
        await tester.tap(find.byKey(_buttonKey));
        await tester.tap(find.byKey(_buttonKey));
        await tester.pump();

        expect(
          calls,
          1,
          reason: 'the action ran twice from one double-press',
        );

        completer.complete();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 600));
      },
    );

    testWidgets('the tap is swallowed even inside the reveal delay, while the '
        'button still LOOKS idle', (tester) async {
      final completer = Completer<void>();
      var calls = 0;
      await tester.pumpWidget(
        _wrap(
          MasiPendingButton.filled(
            key: _buttonKey,
            onPressed: () {
              calls++;
              return completer.future;
            },
            child: const Text('Save'),
          ),
        ),
      );

      await tester.tap(find.byKey(_buttonKey));
      await tester.pump(const Duration(milliseconds: 50));
      // No spinner yet by design — the guard must not depend on the visuals.
      expect(find.byKey(MasiLoadingIndicator.spinnerKey), findsNothing);

      await tester.tap(find.byKey(_buttonKey), warnIfMissed: false);
      await tester.pump();
      expect(calls, 1);

      completer.complete();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
    });

    testWidgets('disables itself immediately, before any spinner appears', (
      tester,
    ) async {
      final completer = Completer<void>();
      await tester.pumpWidget(
        _wrap(
          MasiPendingButton.filled(
            key: _buttonKey,
            onPressed: () => completer.future,
            child: const Text('Save'),
          ),
        ),
      );

      expect(
        tester.widget<ElevatedButton>(find.byType(ElevatedButton)).onPressed,
        isNotNull,
      );

      await tester.tap(find.byKey(_buttonKey));
      await tester.pump();

      expect(
        tester.widget<ElevatedButton>(find.byType(ElevatedButton)).onPressed,
        isNull,
        reason: 'the control must read as unavailable the instant work starts',
      );

      completer.complete();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      expect(
        tester.widget<ElevatedButton>(find.byType(ElevatedButton)).onPressed,
        isNotNull,
      );
    });

    testWidgets('onPressed: null is simply a disabled button', (tester) async {
      await tester.pumpWidget(
        _wrap(
          const MasiPendingButton.filled(
            key: _buttonKey,
            onPressed: null,
            child: Text('Save'),
          ),
        ),
      );

      expect(
        tester.widget<ElevatedButton>(find.byType(ElevatedButton)).onPressed,
        isNull,
      );
      await tester.tap(find.byKey(_buttonKey), warnIfMissed: false);
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(MasiLoadingIndicator.spinnerKey), findsNothing);
    });
  });

  group('layout stability', () {
    testWidgets(
      'the button does not change size when the pending cue appears — the '
      'reflow that makes this pattern look broken',
      (tester) async {
        final completer = Completer<void>();
        await tester.pumpWidget(
          _wrap(
            MasiPendingButton.filled(
              key: _buttonKey,
              onPressed: () => completer.future,
              // A wide label: swapping the child for a 20px spinner (the usual
              // way this is done) would collapse the button to a stub.
              child: const Text('Publish this topo to the community'),
            ),
          ),
        );
        final idleSize = tester.getSize(find.byKey(_buttonKey));

        await tester.tap(find.byKey(_buttonKey));
        // Bare pump first: the tap's setState only reaches the tree on the
        // next frame, so advancing the clock before it would start the reveal
        // delay late — see the note in the group below.
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 250));
        expect(find.byKey(MasiLoadingIndicator.spinnerKey), findsOneWidget);

        expect(tester.getSize(find.byKey(_buttonKey)), idleSize);

        completer.complete();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 600));
        await tester.pump();
        expect(tester.getSize(find.byKey(_buttonKey)), idleSize);
      },
    );

    testWidgets('expand: true fills the available width', (tester) async {
      await tester.pumpWidget(
        _wrap(
          MasiPendingButton.filled(
            key: _buttonKey,
            expand: true,
            onPressed: () async {},
            child: const Text('Save'),
          ),
        ),
      );

      expect(tester.getSize(find.byKey(_buttonKey)).width, 800);
    });
  });

  // Pumping note: a tap's `setState` reaches the tree on the FOLLOWING frame,
  // so every test that measures the reveal delay pumps once bare (t+0) before
  // advancing the clock. Skipping that bare pump arms the gate's timer late and
  // makes the spinner look ~1 pump slower than it is.
  group('pending cue timing', () {
    testWidgets('a fast action shows no spinner at all', (tester) async {
      await tester.pumpWidget(
        _wrap(
          MasiPendingButton.filled(
            key: _buttonKey,
            onPressed: () async {},
            child: const Text('Save'),
          ),
        ),
      );

      await tester.tap(find.byKey(_buttonKey));
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 200));
        expect(find.byKey(MasiLoadingIndicator.spinnerKey), findsNothing);
      }
    });

    testWidgets('a slow action reveals the spinner, then holds it briefly', (
      tester,
    ) async {
      final completer = Completer<void>();
      await tester.pumpWidget(
        _wrap(
          MasiPendingButton.filled(
            key: _buttonKey,
            onPressed: () => completer.future,
            child: const Text('Save'),
          ),
        ),
      );

      await tester.tap(find.byKey(_buttonKey));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 170));
      expect(find.byKey(MasiLoadingIndicator.spinnerKey), findsNothing);

      await tester.pump(const Duration(milliseconds: 30));
      expect(find.byKey(MasiLoadingIndicator.spinnerKey), findsOneWidget);

      completer.complete();
      await tester.pump();
      // Held rather than ripped away.
      expect(find.byKey(MasiLoadingIndicator.spinnerKey), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump();
      expect(find.byKey(MasiLoadingIndicator.spinnerKey), findsNothing);
      expect(find.text('Save'), findsOneWidget);
    });

    testWidgets('the text variant renders a TextButton and the same cue', (
      tester,
    ) async {
      final completer = Completer<void>();
      await tester.pumpWidget(
        _wrap(
          MasiPendingButton.text(
            key: _buttonKey,
            onPressed: () => completer.future,
            child: const Text('Retry'),
          ),
        ),
      );

      expect(find.byType(TextButton), findsOneWidget);
      await tester.tap(find.byKey(_buttonKey));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.byKey(MasiLoadingIndicator.spinnerKey), findsOneWidget);

      completer.complete();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
    });
  });

  group('failure and lifecycle', () {
    testWidgets('a throwing action clears the pending state and reports to '
        'onError', (tester) async {
      Object? seen;
      await tester.pumpWidget(
        _wrap(
          MasiPendingButton.filled(
            key: _buttonKey,
            onPressed: () async => throw StateError('write failed'),
            onError: (error, _) => seen = error,
            child: const Text('Save'),
          ),
        ),
      );

      await tester.tap(find.byKey(_buttonKey));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));

      expect(seen, isA<StateError>());
      expect(
        tester.widget<ElevatedButton>(find.byType(ElevatedButton)).onPressed,
        isNotNull,
        reason: 'a failed action must not leave the button stuck disabled',
      );
      expect(find.byKey(MasiLoadingIndicator.spinnerKey), findsNothing);
    });

    testWidgets('without onError the failure is reported, never swallowed', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(
          MasiPendingButton.filled(
            key: _buttonKey,
            onPressed: () async => throw StateError('write failed'),
            child: const Text('Save'),
          ),
        ),
      );

      await tester.tap(find.byKey(_buttonKey));
      await tester.pump();

      expect(tester.takeException(), isA<StateError>());
      expect(
        tester.widget<ElevatedButton>(find.byType(ElevatedButton)).onPressed,
        isNotNull,
      );
    });

    testWidgets(
      'unmounted mid-flight (the sheet its action pops) must not setState on a '
      'dead State',
      (tester) async {
        final completer = Completer<void>();
        await tester.pumpWidget(
          _wrap(
            MasiPendingButton.filled(
              key: _buttonKey,
              onPressed: () => completer.future,
              child: const Text('Save'),
            ),
          ),
        );

        await tester.tap(find.byKey(_buttonKey));
        await tester.pump(const Duration(milliseconds: 100));

        await tester.pumpWidget(_wrap(const SizedBox.shrink()));
        completer.complete();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 600));

        expect(tester.takeException(), isNull);
      },
    );
  });
}
