// The app's one transient-message surface.
//
// Two things carry this file.
//
// The first is that a toast must be legible BEFORE it is read: the kind
// decides a glyph and a tint, so a failure and an acknowledgement do not
// arrive looking identical. That is the entire reason this component replaced
// ~95 unstyled `SnackBar`s.
//
// The second is that a toast may never itself become the failure. It is how
// this app reports that something went wrong, so it has to render under a
// theme it does not control, and its action has to take the message away
// before doing whatever it does.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:masi/app/theme.dart';
import 'package:masi/shared/presentation/masi_icon.dart';
import 'package:masi/shared/presentation/masi_toast.dart';

/// Pumps a host and shows [show]'s toast, advancing only INTO the entrance
/// animation.
///
/// Deliberately not `pumpAndSettle`: that would run the entrance, the whole
/// visible duration AND the exit, settling the bar off-screen before any
/// `find` could see it (the same reasoning `photo_write_failure_snackbar_test`
/// spells out).
Future<void> _show(
  WidgetTester tester,
  void Function(ScaffoldMessengerState messenger) show, {
  ThemeData? theme,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: theme ?? MasiTheme.light,
      home: Scaffold(
        body: Builder(
          builder: (context) => ElevatedButton(
            key: const Key('show'),
            onPressed: () => show(ScaffoldMessenger.of(context)),
            child: const Text('show'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.byKey(const Key('show')));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

MasiIcon _glyph(WidgetTester tester) => tester.widget<MasiIcon>(
  find.descendant(of: find.byType(MasiToastCard), matching: find.byType(MasiIcon)),
);

void main() {
  group('the message', () {
    testWidgets('is rendered inside a real SnackBar, so it queues, dismisses '
        'and clears the home indicator like every other toast', (tester) async {
      await _show(tester, (m) => m.showMasiToast('Location saved'));
      expect(find.byType(SnackBar), findsOne);
      expect(find.byType(MasiToastCard), findsOne);
      expect(find.text('Location saved'), findsOne);
    });

    testWidgets(
      'renders under a theme carrying no MasiColors. A toast is how this app '
      'reports failures, so it is the last widget allowed to become one',
      (tester) async {
        await _show(
          tester,
          (m) => m.showMasiError('Nope'),
          theme: ThemeData(useMaterial3: true),
        );
        expect(tester.takeException(), isNull);
        expect(find.text('Nope'), findsOne);
      },
    );
  });

  group('the kind', () {
    // One pump per kind, and not two shows in one test: a second
    // `showSnackBar` QUEUES behind the first rather than replacing it, so a
    // test that showed both would assert against whichever it showed first
    // and pass for the wrong reason.
    testWidgets('a success carries the check glyph', (tester) async {
      await _show(tester, (m) => m.showMasiSuccess('Saved'));
      expect(_glyph(tester).name, 'check');
      expect(_glyph(tester).color, MasiColors.light.gradeBeginner);
    });

    testWidgets('a failure carries the warning glyph', (tester) async {
      await _show(tester, (m) => m.showMasiError('Not saved'));
      expect(_glyph(tester).name, 'warning');
      expect(_glyph(tester).color, MasiColors.light.gradeHard);
    });

    test('every kind is told apart by glyph or tint — two kinds that render '
        'identically are two kinds the reader cannot use', () {
      final seen = <(String, Color)>{};
      for (final kind in MasiToastKind.values) {
        seen.add((masiToastGlyph(kind), masiToastTint(kind, MasiColors.light)));
      }
      expect(seen, hasLength(MasiToastKind.values.length));
    });

    test('an error stays up longer than an acknowledgement — a failure the '
        'user misses is work they believe was saved', () {
      expect(
        masiToastDuration(MasiToastKind.error),
        greaterThan(masiToastDuration(MasiToastKind.success)),
      );
    });

    testWidgets('an unspecified kind is neutral, never alarming', (
      tester,
    ) async {
      await _show(tester, (m) => m.showMasiToast('Installing…'));
      expect(_glyph(tester).name, 'info');
      expect(_glyph(tester).color, MasiColors.light.ink2);
    });
  });

  group('the action', () {
    testWidgets('runs, and takes the toast away first — every action here '
        'either navigates or retries, and both leave a stale message over the '
        'result', (tester) async {
      var tapped = 0;
      await _show(
        tester,
        (m) => m.showMasiToast(
          'Comment posted',
          actionLabel: 'View',
          onAction: () => tapped++,
        ),
      );
      await tester.tap(find.text('View'));
      await tester.pumpAndSettle();
      expect(tapped, 1);
      expect(find.byType(MasiToastCard), findsNothing);
    });

    testWidgets(
      'half an action is no action: a label with no callback renders no '
      'button rather than one that does nothing',
      (tester) async {
        await _show(
          tester,
          (m) => m.showMasiToast('Done', actionLabel: 'View'),
        );
        expect(find.text('View'), findsNothing);
        expect(find.byType(TextButton), findsNothing);
      },
    );
  });

  testWidgets('a key reaches the SnackBar, so existing call sites can still '
      'be found by one', (tester) async {
    await _show(
      tester,
      (m) => m.showMasiSuccess('Sent', key: const Key('topo-proposal-sent')),
    );
    expect(find.byKey(const Key('topo-proposal-sent')), findsOne);
  });
}
