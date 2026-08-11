// The route panel's grab handle is a real drag target (user report,
// 2026-08-11: "the route list collapsing UX is confusing — the down pointing
// arrow is random and the horizontal line suggests pulling but pulling
// doesn't do anything").
//
// The panel now behaves like the bottom sheet it has always looked like:
//   * drag/flick DOWN on `topo-route-legend-handle` -> collapse to the chip;
//   * drag/flick UP on the collapsed chip -> expand again;
//   * drag/flick UP on the expanded handle -> the next level of detail, i.e.
//     this wall's community view (covered by
//     `topo_open_community_button_test.dart`, which owns that destination);
//   * `topo-route-legend-collapse` (the chevron) is a real button and the
//     ONLY thing in the header a tap acts on — the header itself is a drag
//     surface, so a tap that was meant to be a pull no longer collapses the
//     panel out from under the user.
//
// Pumped through `TopoCanvasBody` directly (the documented test seam — see
// its class doc) with an injected `imageSize`/`drawState`, so no photo is
// ever decoded.

import 'package:masi/app/theme.dart';
import 'package:masi/features/topo/application/draw_controller.dart';
import 'package:masi/features/topo/domain/topo_route.dart';
import 'package:masi/features/topo/presentation/route_legend.dart';
import 'package:masi/features/topo/presentation/topo_canvas_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _testWallId = 'test-wall';
const _overlayKey = Key('topo-route-legend-overlay');
const _chipKey = Key('topo-route-legend-chip');
const _handleKey = Key('topo-route-legend-handle');

const _route = TopoRoute(
  id: 1,
  number: 1,
  points: [Offset(0.1, 0.1), Offset(0.2, 0.2)],
);

Future<ProviderContainer> _pumpBody(WidgetTester tester) async {
  final container = ProviderContainer();
  addTearDown(container.dispose);
  // FIX #6 (autoDispose pending-timer gotcha) — see route_legend_gap_test.dart.
  container.listen(drawControllerProvider(_testWallId), (_, _) {});
  container.listen(legendExpandedProvider(_testWallId), (_, _) {});
  final controller = TransformationController();
  addTearDown(controller.dispose);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: MasiTheme.light,
        home: Scaffold(
          body: TopoCanvasBody(
            wallId: _testWallId,
            imagePath: '/nonexistent/legend-drag-test.jpg',
            imageSize: const Size(400, 300),
            drawState: const DrawState(mode: DrawMode.view, routes: [_route]),
            transformationController: controller,
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  return container;
}

void main() {
  testWidgets('flicking the handle DOWN collapses the panel to the chip', (
    tester,
  ) async {
    final container = await _pumpBody(tester);

    expect(find.byKey(_overlayKey), findsOneWidget);

    await tester.fling(find.byKey(_handleKey), const Offset(0, 120), 1000);
    await tester.pumpAndSettle();

    expect(container.read(legendExpandedProvider(_testWallId)), isFalse);
    expect(find.byKey(_overlayKey), findsNothing);
    expect(find.byKey(_chipKey), findsOneWidget);
  });

  testWidgets('flicking the collapsed chip UP expands it again', (
    tester,
  ) async {
    final container = await _pumpBody(tester);

    container.read(legendExpandedProvider(_testWallId).notifier).toggle();
    await tester.pumpAndSettle();
    expect(find.byKey(_chipKey), findsOneWidget);

    await tester.fling(find.byKey(_chipKey), const Offset(0, -120), 1000);
    await tester.pumpAndSettle();

    expect(container.read(legendExpandedProvider(_testWallId)), isTrue);
    expect(find.byKey(_overlayKey), findsOneWidget);
  });

  testWidgets(
    'the chevron button collapses the panel — the affordance the arrow now '
    'genuinely stands for',
    (tester) async {
      final container = await _pumpBody(tester);

      await tester.tap(find.byKey(const Key('topo-route-legend-collapse')));
      await tester.pumpAndSettle();

      expect(container.read(legendExpandedProvider(_testWallId)), isFalse);
      expect(find.byKey(_chipKey), findsOneWidget);
    },
  );

  testWidgets(
    'TAPPING the header (not the chevron) does NOT collapse — the handle is a '
    'drag surface, and a tap that was meant to be a pull must not close the '
    'panel',
    (tester) async {
      final container = await _pumpBody(tester);

      // The route-count label, well clear of the chevron on the far right.
      await tester.tap(find.text('1 route'));
      await tester.pumpAndSettle();

      expect(container.read(legendExpandedProvider(_testWallId)), isTrue);
      expect(find.byKey(_overlayKey), findsOneWidget);
    },
  );

  testWidgets(
    'a slow, low-velocity drag on the handle does nothing — only a deliberate '
    'flick past the threshold acts, so a stray finger movement while reading '
    'the list cannot close it',
    (tester) async {
      final container = await _pumpBody(tester);

      final gesture = await tester.startGesture(
        tester.getCenter(find.byKey(_handleKey)),
      );
      // Ten small steps spread over a second: real movement, negligible
      // velocity.
      for (var i = 0; i < 10; i++) {
        await gesture.moveBy(
          const Offset(0, 2),
          timeStamp: Duration(milliseconds: 100 * (i + 1)),
        );
      }
      await gesture.up();
      await tester.pumpAndSettle();

      expect(container.read(legendExpandedProvider(_testWallId)), isTrue);
    },
  );
}
