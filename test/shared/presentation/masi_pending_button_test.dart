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
const _innerKey = Key('pending-button-inner');

Widget _wrap(Widget child, {ThemeData? theme}) => MaterialApp(
  theme: theme ?? MasiTheme.light,
  home: Scaffold(body: Center(child: child)),
);

/// The arc the pending cue actually paints, so its colour can be asserted.
CircularProgressIndicator _spinner(WidgetTester tester) =>
    tester.widget<CircularProgressIndicator>(
      find.descendant(
        of: find.byKey(MasiLoadingIndicator.spinnerKey),
        matching: find.byType(CircularProgressIndicator),
      ),
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

    testWidgets('an armed action that throws before it arms still clears its '
        'lock', (tester) async {
      Object? seen;
      var calls = 0;
      await tester.pumpWidget(
        _wrap(
          MasiPendingButton.filled(
            key: _buttonKey,
            onPressedArmed: (reportBusy) async {
              calls++;
              throw StateError('the read behind the sheet failed');
            },
            onError: (error, _) => seen = error,
            child: const Text('New area'),
          ),
        ),
      );

      await tester.tap(find.byKey(_buttonKey));
      await tester.pump();
      expect(seen, isA<StateError>());

      // The lock is invisible, so nothing on screen would reveal it stuck: the
      // proof is that a second tap still runs the action.
      await tester.tap(find.byKey(_buttonKey));
      await tester.pump();
      expect(calls, 2);
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

  // The seam that lets the `ask the user → then write` family (a name dialog,
  // a confirm sheet, an OS picker) use this widget at all. Without it the cue
  // spans the whole future, so it spins on the one control still visible under
  // the modal's barrier for as long as the user types — and hangs
  // `pumpAndSettle()` in every test that opens the modal.
  group('the armed seam (onPressedArmed)', () {
    testWidgets(
      'a modal-first action shows NO cue while its dialog is open, so '
      'pumpAndSettle survives the modal',
      (tester) async {
        final write = Completer<void>();
        await tester.pumpWidget(
          _wrap(
            Builder(
              builder: (context) => MasiPendingButton.filled(
                key: _buttonKey,
                buttonKey: _innerKey,
                onPressedArmed: (reportBusy) async {
                  final name = await showDialog<String>(
                    context: context,
                    builder: (dialogContext) => AlertDialog(
                      content: TextButton(
                        key: const Key('dialog-save'),
                        onPressed: () =>
                            Navigator.of(dialogContext).pop('Squamish'),
                        child: const Text('Save'),
                      ),
                    ),
                  );
                  if (name == null) return;
                  reportBusy(true);
                  await write.future;
                },
                child: const Text('New area'),
              ),
            ),
          ),
        );

        await tester.tap(find.byKey(_buttonKey));
        // This is the measured failure the seam exists for: with a whole-future
        // cue there is a revealed spinner behind the barrier and this hangs
        // forever.
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('dialog-save')), findsOneWidget);
        expect(
          find.byKey(MasiLoadingIndicator.spinnerKey),
          findsNothing,
          reason: 'the user is the one working while their own dialog is up',
        );
        // And the button under the barrier still reads as available, because it
        // is: nothing of ours is in flight yet.
        expect(
          tester.widget<ElevatedButton>(find.byKey(_innerKey)).onPressed,
          isNotNull,
        );

        await tester.tap(find.byKey(const Key('dialog-save')));
        // `showDialog`'s future resolves only after the route's exit
        // transition, so the write — and the cue — start a couple of hundred ms
        // after the tap. Pump past that and the reveal delay.
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 600));

        expect(
          find.descendant(
            of: find.byKey(_innerKey),
            matching: find.byKey(MasiLoadingIndicator.spinnerKey),
          ),
          findsOneWidget,
          reason: 'once the dialog is gone the wait is ours to explain',
        );
        expect(
          tester.widget<ElevatedButton>(find.byKey(_innerKey)).onPressed,
          isNull,
          reason: 'a second write from a second tap is the bug this closes',
        );
        // The label kept its box, so the button cannot change width mid-write.
        expect(find.text('New area'), findsOneWidget);

        write.complete();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 600));
        expect(find.byKey(MasiLoadingIndicator.spinnerKey), findsNothing);
      },
    );

    testWidgets(
      'the tap is single-shot from the instant it is pressed, BEFORE the '
      'action arms anything — the lock is not the cue',
      (tester) async {
        final gate = Completer<void>();
        var calls = 0;
        await tester.pumpWidget(
          _wrap(
            MasiPendingButton.filled(
              key: _buttonKey,
              buttonKey: _innerKey,
              onPressedArmed: (reportBusy) async {
                calls++;
                await gate.future; // standing in for a modal the user is in
              },
              child: const Text('New area'),
            ),
          ),
        );

        await tester.tap(find.byKey(_buttonKey));
        await tester.pump(const Duration(milliseconds: 300));
        expect(calls, 1);
        expect(find.byKey(MasiLoadingIndicator.spinnerKey), findsNothing);
        // Deliberately still enabled — a disabled button under a barrier the
        // user is about to dismiss would be a lie about a control they can use
        // again in a moment.
        expect(
          tester.widget<ElevatedButton>(find.byKey(_innerKey)).onPressed,
          isNotNull,
        );

        await tester.tap(find.byKey(_buttonKey));
        await tester.pump();
        expect(calls, 1, reason: 'the lock must hold while the cue is unarmed');

        gate.complete();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 600));
        await tester.tap(find.byKey(_buttonKey));
        await tester.pump();
        expect(calls, 2, reason: 'the lock must clear when the action returns');
      },
    );

    testWidgets('reporting false hands the flow back to the user and puts the '
        'cue away', (tester) async {
      final read = Completer<void>();
      final rest = Completer<void>();
      await tester.pumpWidget(
        _wrap(
          MasiPendingButton.filled(
            key: _buttonKey,
            // Mirrors a "move" action: read the candidate destinations first
            // (ours), then open the picker (theirs).
            onPressedArmed: (reportBusy) async {
              reportBusy(true);
              await read.future;
              reportBusy(false);
              await rest.future;
            },
            child: const Text('Move'),
          ),
        ),
      );

      await tester.tap(find.byKey(_buttonKey));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.byKey(MasiLoadingIndicator.spinnerKey), findsOneWidget);

      read.complete();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      expect(
        find.byKey(MasiLoadingIndicator.spinnerKey),
        findsNothing,
        reason: 'the picker is up now; the user is working again',
      );

      rest.complete();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
    });
  });

  // `buttonKey` exists because ~12 sites key this widget for tapping, but a few
  // also need to READ the Material button (its resolved onPressed/style) — and
  // the widget's own `key` lands on the outermost wrapper, so that cast throws.
  group('buttonKey', () {
    testWidgets('lands on the Material button, not on the wrapper', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(
          MasiPendingButton.filled(
            key: _buttonKey,
            buttonKey: _innerKey,
            expand: true,
            onPressed: () async {},
            child: const Text('Save'),
          ),
        ),
      );

      expect(
        tester.widget<ElevatedButton>(find.byKey(_innerKey)).onPressed,
        isNotNull,
      );
      // The outer key is still the tappable/whole-widget handle.
      expect(tester.getSize(find.byKey(_buttonKey)).width, 800);
    });

    testWidgets('the text variant keys its TextButton', (tester) async {
      await tester.pumpWidget(
        _wrap(
          MasiPendingButton.text(
            buttonKey: _innerKey,
            onPressed: () async {},
            child: const Text('Retry'),
          ),
        ),
      );

      expect(
        tester.widget<TextButton>(find.byKey(_innerKey)).onPressed,
        isNotNull,
      );
    });
  });

  // The cue was hardcoded per variant (`onAccent` filled / `accent` text),
  // which made the widget unusable for any surface-filled button: white on
  // #FBFAFE in light, #1A1226 on #251F34 in dark — an invisible spinner.
  group('spinner colour', () {
    Future<void> pumpToSpinner(WidgetTester tester, Widget button) async {
      await tester.pumpWidget(_wrap(button));
      await tester.tap(find.byKey(_buttonKey));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.byKey(MasiLoadingIndicator.spinnerKey), findsOneWidget);
    }

    testWidgets('follows a style: override of the foreground, so a '
        'surface-filled button paints a VISIBLE cue', (tester) async {
      final completer = Completer<void>();
      await pumpToSpinner(
        tester,
        MasiPendingButton.filled(
          key: _buttonKey,
          // The Google sign-in button: a filled button that is not accent.
          style: ElevatedButton.styleFrom(
            backgroundColor: MasiColors.light.surface2,
            foregroundColor: MasiColors.light.ink,
          ),
          onPressed: () => completer.future,
          child: const Text('Continue with Google'),
        ),
      );

      expect(
        _spinner(tester).color,
        MasiColors.light.ink,
        reason: 'onAccent (white) on surface2 (#FBFAFE) is invisible',
      );

      completer.complete();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
    });

    testWidgets('defaults per variant are unchanged: onAccent filled, accent '
        'text', (tester) async {
      final filled = Completer<void>();
      await pumpToSpinner(
        tester,
        MasiPendingButton.filled(
          key: _buttonKey,
          onPressed: () => filled.future,
          child: const Text('Save'),
        ),
      );
      expect(_spinner(tester).color, MasiColors.light.onAccent);
      filled.complete();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));

      final text = Completer<void>();
      await pumpToSpinner(
        tester,
        MasiPendingButton.text(
          key: _buttonKey,
          onPressed: () => text.future,
          child: const Text('Retry'),
        ),
      );
      expect(_spinner(tester).color, MasiColors.light.accent);
      text.complete();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
    });

    testWidgets('spinnerColor wins over the derivation', (tester) async {
      final completer = Completer<void>();
      await pumpToSpinner(
        tester,
        MasiPendingButton.filled(
          key: _buttonKey,
          spinnerColor: MasiColors.light.gradeHard,
          onPressed: () => completer.future,
          child: const Text('Delete'),
        ),
      );

      expect(_spinner(tester).color, MasiColors.light.gradeHard);

      completer.complete();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
    });

    testWidgets('a surface-filled button in DARK mode paints its cue in the '
        'dark ink, not in near-black onAccent', (tester) async {
      final completer = Completer<void>();
      await tester.pumpWidget(
        _wrap(
          MasiPendingButton.filled(
            key: _buttonKey,
            style: ElevatedButton.styleFrom(
              backgroundColor: MasiColors.dark.surface2,
              foregroundColor: MasiColors.dark.ink,
            ),
            onPressed: () => completer.future,
            child: const Text('Continue with Google'),
          ),
          theme: MasiTheme.dark,
        ),
      );
      await tester.tap(find.byKey(_buttonKey));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));

      expect(
        _spinner(tester).color,
        MasiColors.dark.ink,
        reason: 'onAccent (#1A1226) on surface2 (#251F34) is invisible',
      );

      completer.complete();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
    });
  });
}
