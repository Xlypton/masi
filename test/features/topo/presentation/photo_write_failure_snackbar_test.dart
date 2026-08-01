// The user-facing half of the L3 fix: a failed photo byte write must surface
// as a distinguishable, plainly-worded SnackBar — not a debugPrint nobody but
// a developer attached to a debugger would ever see.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:masi/features/topo/data/photo_write_exception.dart';
import 'package:masi/features/topo/presentation/topo_canvas_photo_ops.dart';
import 'package:masi/shared/presentation/masi_icon.dart';

/// Pumps a trivial host, taps it to show [snackBar], and advances just far
/// enough INTO the entrance animation to assert on it. Deliberately NOT
/// `pumpAndSettle`: that runs the SnackBar's entrance, its full 4s default
/// duration AND its exit to completion, settling it off-screen before any
/// `find` could see it (same reasoning as `topos_screen_test.dart`'s
/// `_drainNoSettle`).
Future<void> _showSnackBar(WidgetTester tester, SnackBar snackBar) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => ElevatedButton(
            key: const Key('show'),
            onPressed: () =>
                ScaffoldMessenger.of(context).showSnackBar(snackBar),
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

void main() {
  testWidgets('a quota failure renders its own out-of-space wording behind a '
      'warning glyph', (tester) async {
    await _showSnackBar(
      tester,
      photoWriteFailureSnackBar(
        const PhotoWriteException(
          failure: PhotoWriteFailure.quotaExceeded,
          key: 'photos/abc.jpg',
        ),
      ),
    );

    expect(find.byType(SnackBar), findsOneWidget);
    expect(find.textContaining('Out of storage space'), findsOneWidget);
    expect(find.byType(MasiIcon), findsOneWidget);
  });

  testWidgets('an unknown failure renders the plain retry wording', (
    tester,
  ) async {
    await _showSnackBar(
      tester,
      photoWriteFailureSnackBar(
        const PhotoWriteException(
          failure: PhotoWriteFailure.unknown,
          key: 'photos/abc.jpg',
        ),
      ),
    );

    expect(find.byType(SnackBar), findsOneWidget);
    expect(find.textContaining('could not be saved'), findsOneWidget);
  });

  testWidgets('the two variants are visibly different, so a quota problem is '
      'actionable rather than generic', (tester) async {
    await _showSnackBar(
      tester,
      photoWriteFailureSnackBar(
        const PhotoWriteException(
          failure: PhotoWriteFailure.quotaExceeded,
          key: 'photos/abc.jpg',
        ),
      ),
    );

    expect(find.textContaining('could not be saved'), findsNothing);
  });
}
