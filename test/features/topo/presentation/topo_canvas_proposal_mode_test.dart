// The canvas' half of "editing someone else's committed route becomes a
// proposal, not a write" (`ROUTE_EDITING_PLAN.md` §3.2).
//
// `TopoCanvas` does not police the gestures — that was the earlier, worse
// shape of this feature, where a non-owner's drag was refused outright. It
// answers one question instead: is this wall provably somebody else's? — and
// pushes the answer into `DrawController.setProposalOnlyGeometryEdits`, which
// is where a geometry edit forks into a database write or an in-memory edit
// awaiting submission. So what is worth testing here is the pass-through and
// its timing, plus the negative: that the gestures themselves did NOT change.
//
// The harness is the bare-`TopoCanvas` one from
// `topo_canvas_route_geometry_gesture_test.dart` — no wall, no photo, no
// database — with `canEditWallRoutesProvider` overridden per test. The
// override is what keeps the real provider (and with it a real database open)
// out of these tests; its own behaviour is proven in
// `test/features/topo/application/wall_route_edit_permission_test.dart`.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:masi/app/theme.dart';
import 'package:masi/features/topo/application/draw_controller.dart';
import 'package:masi/features/topo/application/wall_route_edit_permission.dart';
import 'package:masi/features/topo/domain/topo_route.dart';
import 'package:masi/features/topo/presentation/symbol_palette_bar.dart';
import 'package:masi/features/topo/presentation/topo_canvas.dart';

const _testWallId = 'test-wall';
const _imageSize = Size(400, 300);

class _Harness {
  _Harness(this.tester, this.container, this.transformation);

  final WidgetTester tester;
  final ProviderContainer container;
  final TransformationController transformation;

  DrawController get notifier =>
      container.read(drawControllerProvider(_testWallId).notifier);

  DrawState get state => container.read(drawControllerProvider(_testWallId));

  TopoRoute get route => state.routes.single;

  /// Percent-space -> the global coordinate to touch, derived from the LIVE
  /// fit transform rather than assumed (see the gesture test's own note on
  /// why hardcoding this is a trap).
  Offset at(double xPercent, double yPercent) {
    final scene = Offset(
      _imageSize.width * xPercent,
      _imageSize.height * yPercent,
    );
    final local = MatrixUtils.transformPoint(transformation.value, scene);
    final box = tester.renderObject<RenderBox>(find.byType(TopoCanvas));
    return box.localToGlobal(local);
  }

  Future<TopoRoute> commitThreePointRoute() async {
    notifier.setMode(DrawMode.draw);
    for (final p in const [
      Offset(0.2, 0.2),
      Offset(0.5, 0.5),
      Offset(0.8, 0.8),
    ]) {
      notifier.addPoint(p);
    }
    await notifier.commitRoute();
    final committed = state.routes.single;
    notifier.selectRoute(committed.id);
    await tester.pump();
    return committed;
  }

  Future<void> dragFrom(Offset start, List<Offset> waypoints) async {
    final gesture = await tester.startGesture(start);
    await tester.pump();
    for (final point in waypoints) {
      await gesture.moveTo(point);
      await tester.pump();
    }
    await gesture.up();
    await tester.pumpAndSettle();
  }
}

/// Pumps the canvas with [ownership] standing in for the database-backed
/// answer to "may I edit this wall's routes?".
Future<_Harness> _pumpCanvas(
  WidgetTester tester, {
  required Future<bool> ownership,
}) async {
  tester.view.physicalSize = Size(
    _imageSize.width,
    _imageSize.height + kSymbolPaletteBarHeight,
  );
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final container = ProviderContainer(
    overrides: [
      canEditWallRoutesProvider(_testWallId).overrideWith((ref) => ownership),
    ],
  );
  addTearDown(container.dispose);
  final transformation = TransformationController();
  addTearDown(transformation.dispose);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: MasiTheme.light,
        home: Scaffold(
          body: Column(
            children: [
              const SymbolPaletteBar(wallId: _testWallId),
              Expanded(
                child: TopoCanvas(
                  wallId: _testWallId,
                  imagePath: '/nonexistent/test-topo.jpg',
                  imageSize: _imageSize,
                  transformationController: transformation,
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
  // Two pumps: one to deliver the stream's first value into the provider, one
  // to run the post-frame callback that pushes it into the controller.
  await tester.pump();
  await tester.pump();
  return _Harness(tester, container, transformation);
}

void main() {
  testWidgets(
    'a wall that is provably someone else\'s puts the controller in '
    'proposal-only mode',
    (tester) async {
      final h = await _pumpCanvas(tester, ownership: Future.value(false));
      expect(h.state.proposalOnlyGeometryEdits, isTrue);
    },
  );

  testWidgets('a wall that is mine leaves the controller writing', (
    tester,
  ) async {
    final h = await _pumpCanvas(tester, ownership: Future.value(true));
    expect(h.state.proposalOnlyGeometryEdits, isFalse);
  });

  testWidgets(
    'an UNRESOLVED ownership answer leaves the controller writing — the '
    'fail-open direction. Refusing to persist while the answer is merely '
    'in flight would reroute an owner\'s first edit on their own topo into a '
    'proposal to themselves, which is worse than one local write to a '
    'foreign row that RLS refuses and the next pull overwrites',
    (tester) async {
      final completer = Completer<bool>();
      final h = await _pumpCanvas(tester, ownership: completer.future);

      expect(h.state.proposalOnlyGeometryEdits, isFalse);
    },
  );

  testWidgets(
    'a late answer still lands — the whole point of not deciding at mount is '
    'that the database read is allowed to take its time',
    (tester) async {
      final completer = Completer<bool>();
      final h = await _pumpCanvas(tester, ownership: completer.future);
      expect(h.state.proposalOnlyGeometryEdits, isFalse);

      completer.complete(false);
      await tester.pump();
      await tester.pump();

      expect(h.state.proposalOnlyGeometryEdits, isTrue);
    },
  );

  group('the gestures are IDENTICAL for a non-owner', () {
    testWidgets(
      'dragging a committed point still moves it, and says nothing — the '
      'edit is meant to be made and then submitted, not refused',
      (tester) async {
        final h = await _pumpCanvas(tester, ownership: Future.value(false));
        await h.commitThreePointRoute();
        expect(h.state.proposalOnlyGeometryEdits, isTrue);

        await h.dragFrom(h.at(0.5, 0.5), [h.at(0.7, 0.5)]);

        expect(h.route.points[1].dx, closeTo(0.7, 0.005));
        expect(h.route.points[1].dy, closeTo(0.5, 0.005));
        expect(
          find.byType(SnackBar),
          findsNothing,
          reason: 'a refusal SnackBar here would be the old, rejected design',
        );
      },
    );

    testWidgets('dragging a committed marker still moves it', (tester) async {
      final h = await _pumpCanvas(tester, ownership: Future.value(false));
      await h.commitThreePointRoute();
      h.notifier.setActiveSymbol(SymbolType.anchor);
      await h.notifier.placeSymbol(const Offset(0.35, 0.35));
      h.notifier.setActiveSymbol(null);
      await tester.pump();

      await h.dragFrom(h.at(0.35, 0.35), [h.at(0.45, 0.6)]);

      final symbol = h.route.symbols.single;
      expect(symbol.position.dx, closeTo(0.45, 0.005));
      expect(symbol.position.dy, closeTo(0.6, 0.005));
    });

    testWidgets('the eraser still erases', (tester) async {
      final h = await _pumpCanvas(tester, ownership: Future.value(false));
      await h.commitThreePointRoute();

      h.notifier.setEraserActive(true);
      await tester.tapAt(h.at(0.5, 0.5));
      await tester.pumpAndSettle();

      expect(h.route.points, const [Offset(0.2, 0.2), Offset(0.8, 0.8)]);
      expect(find.byType(SnackBar), findsNothing);
    });

    testWidgets('drawing a NEW line is untouched', (tester) async {
      final h = await _pumpCanvas(tester, ownership: Future.value(false));
      await h.commitThreePointRoute();

      await tester.tapAt(h.at(0.05, 0.9));
      await tester.pumpAndSettle();

      expect(h.state.currentPoints, hasLength(1));
      expect(h.route.points, hasLength(3));
    });
  });
}
