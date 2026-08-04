import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:masi/app/theme.dart';
import 'package:masi/shared/presentation/masi_icon.dart';
import 'package:masi/shared/presentation/masi_loading_indicator.dart';
import 'package:masi/shared/presentation/masi_pending_icon_button.dart';

/// Tests for the shared `PendingIconButton` — specifically the parts the
/// community feature's own tests do NOT cover, because they only ever used the
/// whole-future shape: `buttonKey` placement and the armed seam that let a
/// list row's rename/delete glyphs adopt this widget.
///
/// The plain `onPressed` path (post-a-comment, the map controls) is exercised
/// end-to-end in `test/features/community/presentation/community_loading_test.dart`.
const _key = Key('pending-icon-button');

Widget _wrap(Widget child) => MaterialApp(
  theme: MasiTheme.light,
  home: Scaffold(body: Center(child: child)),
);

void main() {
  testWidgets('buttonKey lands on the IconButton, so a test can read its '
      'resolved onPressed', (tester) async {
    final completer = Completer<void>();
    await tester.pumpWidget(
      _wrap(
        PendingIconButton(
          buttonKey: _key,
          tooltip: 'Delete',
          onPressed: () => completer.future,
          icon: MasiIcon('delete'),
        ),
      ),
    );

    expect(tester.widget<IconButton>(find.byKey(_key)).onPressed, isNotNull);

    await tester.tap(find.byKey(_key));
    await tester.pump();
    expect(
      tester.widget<IconButton>(find.byKey(_key)).onPressed,
      isNull,
      reason: 'the glyph must read as unavailable the instant work starts',
    );

    completer.complete();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(tester.widget<IconButton>(find.byKey(_key)).onPressed, isNotNull);
  });

  testWidgets(
    'an armed action shows NO cue while its confirm sheet is open, and the cue '
    'lands INSIDE the 48px button once it does arm',
    (tester) async {
      final write = Completer<void>();
      await tester.pumpWidget(
        _wrap(
          Builder(
            builder: (context) => PendingIconButton(
              buttonKey: _key,
              tooltip: 'Delete',
              onPressedArmed: (reportBusy) async {
                final confirmed = await showDialog<bool>(
                  context: context,
                  builder: (dialogContext) => AlertDialog(
                    content: TextButton(
                      key: const Key('confirm-delete'),
                      onPressed: () => Navigator.of(dialogContext).pop(true),
                      child: const Text('Delete'),
                    ),
                  ),
                );
                if (confirmed != true) return;
                reportBusy(true);
                await write.future;
              },
              icon: MasiIcon('delete'),
            ),
          ),
        ),
      );

      await tester.tap(find.byKey(_key));
      // Would hang forever if the cue spanned the whole future.
      await tester.pumpAndSettle();
      expect(find.byKey(MasiLoadingIndicator.spinnerKey), findsNothing);

      await tester.tap(find.byKey(const Key('confirm-delete')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));

      expect(
        find.descendant(
          of: find.byKey(_key),
          matching: find.byKey(MasiLoadingIndicator.spinnerKey),
        ),
        findsOneWidget,
        reason: 'the cue belongs on the control the user actually pressed',
      );
      expect(tester.widget<IconButton>(find.byKey(_key)).onPressed, isNull);

      write.complete();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.byKey(MasiLoadingIndicator.spinnerKey), findsNothing);
    },
  );

  testWidgets('an armed tap is single-shot before it arms — the lock is not '
      'the cue', (tester) async {
    final gate = Completer<void>();
    var calls = 0;
    await tester.pumpWidget(
      _wrap(
        PendingIconButton(
          buttonKey: _key,
          tooltip: 'Rename',
          onPressedArmed: (reportBusy) async {
            calls++;
            await gate.future;
          },
          icon: MasiIcon('edit'),
        ),
      ),
    );

    await tester.tap(find.byKey(_key));
    await tester.pump(const Duration(milliseconds: 300));
    expect(calls, 1);
    expect(find.byKey(MasiLoadingIndicator.spinnerKey), findsNothing);
    expect(tester.widget<IconButton>(find.byKey(_key)).onPressed, isNotNull);

    await tester.tap(find.byKey(_key));
    await tester.pump();
    expect(calls, 1, reason: 'the lock must hold while the cue is unarmed');

    gate.complete();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    await tester.tap(find.byKey(_key));
    await tester.pump();
    expect(calls, 2);
  });
}
