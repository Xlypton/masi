// The user-facing half of UF-1: a route write that never reached the database
// must surface as a plainly-worded SnackBar, not a debugPrint only a developer
// attached to a debugger would ever see. Mirrors
// `photo_write_failure_snackbar_test.dart`, since the two failures share their
// wording conventions on purpose.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:masi/features/topo/application/draw_controller.dart';
import 'package:masi/features/topo/data/photo_write_exception.dart';
import 'package:masi/features/topo/presentation/topo_canvas_photo_ops.dart';
import 'package:masi/shared/presentation/masi_icon.dart';

/// Pumps a trivial host, taps it to show [snackBar], and advances just far
/// enough INTO the entrance animation to assert on it. Deliberately NOT
/// `pumpAndSettle` — see the photo version's doc for why that settles the bar
/// off-screen before any `find` could see it.
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

SnackBar _barFor(
  RouteWriteOperation operation,
  PhotoWriteFailure failure,
) => routeWriteFailureSnackBar(
  RouteWriteException(
    operation: operation,
    failure: failure,
    rolledBack: true,
  ),
);

void main() {
  testWidgets(
    'a lost route names the route and how to fix it, behind a warning glyph',
    (tester) async {
      await _showSnackBar(
        tester,
        _barFor(
          RouteWriteOperation.commitRoute,
          PhotoWriteFailure.quotaExceeded,
        ),
      );

      expect(find.byType(SnackBar), findsOneWidget);
      expect(find.byType(MasiIcon), findsOneWidget);
      expect(
        find.text(
          'Out of storage space — this route was not saved. Free up space on '
          'this device and try again.',
        ),
        findsOneWidget,
      );
    },
  );

  testWidgets('an unclassifiable failure renders the plain retry wording', (
    tester,
  ) async {
    await _showSnackBar(
      tester,
      _barFor(RouteWriteOperation.commitRoute, PhotoWriteFailure.unknown),
    );

    expect(
      find.text(
        'This route could not be saved on this device. Please try again.',
      ),
      findsOneWidget,
    );
    expect(
      find.textContaining('Out of storage space'),
      findsNothing,
      reason: 'the two variants stay visibly different, as on the photo path',
    );
  });

  testWidgets('a smaller edit is not overstated as a lost route', (
    tester,
  ) async {
    await _showSnackBar(
      tester,
      _barFor(
        RouteWriteOperation.setRouteMetadata,
        PhotoWriteFailure.quotaExceeded,
      ),
    );

    expect(find.textContaining('this change was not saved'), findsOneWidget);
    expect(find.textContaining('this route'), findsNothing);
  });
}
