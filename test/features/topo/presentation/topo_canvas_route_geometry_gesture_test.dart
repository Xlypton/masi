// Gesture-layer half of "editing a committed route" (`ROUTE_EDITING_PLAN.md`
// §4.3) — the part the plan itself flags as the risky one, because
// `_beginInteraction` is a single funnel that every canvas touch goes through
// and it now has three more candidates competing for the same tap.
//
// The order it resolves them in is the thing under test here, and it is not
// arbitrary:
//
//   eraser → place symbol → draft handle → route symbol → route point → add
//
// Two of those pairs are the ones that actually bite. A **marker beats a
// point**, because a marker is the smaller target and sits ON the line, so
// testing points first would make any marker near a point permanently
// ungrabbable. And the **draft beats the selected route**, because a line
// being drawn right now is the thing under the climber's finger; losing that
// would mean a half-drawn route silently stops responding the moment an old
// route happens to be selected.
//
// The harness is the bare-`TopoCanvas` one from `symbol_placement_hint_test
// .dart`: no wall, no photo, no database. Everything asserted here lives in
// `_beginInteraction`/`_updateInteraction`/`_endInteraction`, none of which
// changes with persistence wired up, and a nonexistent `imagePath` avoids the
// real image decode that cannot be driven under fake time.

import 'package:masi/app/theme.dart';
import 'package:masi/features/topo/application/draw_controller.dart';
import 'package:masi/features/topo/domain/topo_route.dart';
import 'package:masi/features/topo/presentation/symbol_palette_bar.dart';
import 'package:masi/features/topo/presentation/topo_canvas.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _testWallId = 'test-wall';
const _imageSize = Size(400, 300);

/// Everything a test needs to drive the canvas, plus the one thing that is
/// genuinely easy to get wrong: turning a percent-space coordinate into the
/// screen point to touch.
class _Harness {
  _Harness(this.tester, this.container, this.transformation);

  final WidgetTester tester;
  final ProviderContainer container;
  final TransformationController transformation;

  DrawController get notifier =>
      container.read(drawControllerProvider(_testWallId).notifier);

  DrawState get state => container.read(drawControllerProvider(_testWallId));

  TopoRoute get route => state.routes.single;

  /// Percent-space → the global coordinate to touch, derived from the LIVE
  /// fit transform rather than assumed.
  ///
  /// Hardcoding this is the trap. The obvious version — image pixels plus the
  /// palette's height — is wrong by about ten pixels, because the palette does
  /// not render at exactly `kSymbolPaletteBarHeight` and the canvas therefore
  /// auto-fits at a scale that is not quite 1. Ten pixels is invisible to the
  /// tap tests, since the handle hit radius is twenty and a near-miss still
  /// hits; it shows up only when a drag's final position is compared exactly.
  /// So it would have shipped as "the eraser works, dragging is subtly off",
  /// which is the worst available outcome. Asking the widget where the point
  /// actually is cannot drift.
  Offset at(double xPercent, double yPercent) {
    final scene = Offset(
      _imageSize.width * xPercent,
      _imageSize.height * yPercent,
    );
    final local = MatrixUtils.transformPoint(transformation.value, scene);
    final box = tester.renderObject<RenderBox>(find.byType(TopoCanvas));
    return box.localToGlobal(local);
  }

  /// Draws and commits one route through [points], then selects it.
  ///
  /// Selection is not incidental: a committed route's markers and its point
  /// handles both render only while it is selected (feature #43 / §4.2), so an
  /// unselected route has nothing on screen for any of these gestures to hit.
  ///
  /// The trailing `pump` is load-bearing, not tidiness. `TopoCanvas` picks its
  /// gesture layer at BUILD time — `topo-view-gesture-detector` in view mode,
  /// `topo-draw-gesture-detector` in draw mode — and `tester.tapAt` dispatches
  /// a pointer without pumping first. Seeding draw mode and touching straight
  /// away therefore sends the touch to the VIEW-mode listener, which quietly
  /// selects instead of drawing, and every assertion in this file reads as
  /// "the feature does nothing".
  Future<TopoRoute> commitSelectedRoute(List<Offset> points) async {
    notifier.setMode(DrawMode.draw);
    for (final p in points) {
      notifier.addPoint(p);
    }
    await notifier.commitRoute();
    final committed = state.routes.single;
    notifier.selectRoute(committed.id);
    await tester.pump();
    return committed;
  }

  /// A three-point route, the shape most of these tests need: long enough that
  /// erasing a point is allowed, and with its points far enough apart that the
  /// hit radius cannot confuse two of them.
  Future<TopoRoute> commitThreePointRoute() => commitSelectedRoute(const [
    Offset(0.2, 0.2),
    Offset(0.5, 0.5),
    Offset(0.8, 0.8),
  ]);

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

Future<_Harness> _pumpCanvas(WidgetTester tester) async {
  tester.view.physicalSize = Size(
    _imageSize.width,
    _imageSize.height + kSymbolPaletteBarHeight,
  );
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final container = ProviderContainer();
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
  await tester.pump();
  return _Harness(tester, container, transformation);
}

void main() {
  group('the eraser removes what it is tapped on', () {
    testWidgets('a marker', (tester) async {
      final h = await _pumpCanvas(tester);
      final route = await h.commitThreePointRoute();

      h.notifier.setActiveSymbol(SymbolType.bolt);
      await h.notifier.placeSymbol(const Offset(0.35, 0.35));
      expect(h.route.symbols, hasLength(1));

      h.notifier.setEraserActive(true);
      await tester.tapAt(h.at(0.35, 0.35));
      await tester.pumpAndSettle();

      expect(h.route.symbols, isEmpty);
      expect(
        h.route.points,
        hasLength(3),
        reason: 'erasing a marker must not disturb the line it sits on',
      );
      expect(h.route.id, route.id);
    });

    testWidgets('a point', (tester) async {
      final h = await _pumpCanvas(tester);
      await h.commitThreePointRoute();

      h.notifier.setEraserActive(true);
      await tester.tapAt(h.at(0.5, 0.5));
      await tester.pumpAndSettle();

      expect(h.route.points, const [Offset(0.2, 0.2), Offset(0.8, 0.8)]);
    });

    testWidgets(
      'a marker BEATS a point sitting at the same spot — a marker is the '
      'smaller target and sits on the line, so if the point won it could '
      'never be erased at all',
      (tester) async {
        final h = await _pumpCanvas(tester);
        await h.commitThreePointRoute();

        h.notifier.setActiveSymbol(SymbolType.crux);
        // Exactly on top of the middle point.
        await h.notifier.placeSymbol(const Offset(0.5, 0.5));

        h.notifier.setEraserActive(true);
        await tester.tapAt(h.at(0.5, 0.5));
        await tester.pumpAndSettle();

        expect(h.route.symbols, isEmpty);
        expect(h.route.points, hasLength(3));
      },
    );
  });

  testWidgets(
    'the two-point floor SAYS SO rather than doing nothing — a tool that '
    'silently ignores a tap is indistinguishable from a broken one',
    (tester) async {
      final h = await _pumpCanvas(tester);
      await h.commitSelectedRoute(const [Offset(0.2, 0.2), Offset(0.8, 0.8)]);

      h.notifier.setEraserActive(true);
      await tester.tapAt(h.at(0.2, 0.2));
      await tester.pumpAndSettle();

      expect(h.route.points, hasLength(2));
      expect(find.byType(SnackBar), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(SnackBar),
          matching: find.textContaining('at least two points'),
        ),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'the eraser does NOT fall through to adding a point — a tap that hits '
    'nothing must erase nothing and draw nothing',
    (tester) async {
      final h = await _pumpCanvas(tester);
      await h.commitThreePointRoute();

      h.notifier.setEraserActive(true);
      // Far from every point and every marker.
      await tester.tapAt(h.at(0.05, 0.9));
      await tester.pumpAndSettle();

      expect(h.route.points, hasLength(3));
      expect(h.state.currentPoints, isEmpty);
    },
  );

  testWidgets('the eraser with no route selected is inert, not a crash', (
    tester,
  ) async {
    final h = await _pumpCanvas(tester);
    await h.commitThreePointRoute();
    h.notifier.selectRoute(null);
    h.notifier.setEraserActive(true);

    await tester.tapAt(h.at(0.5, 0.5));
    await tester.pumpAndSettle();

    expect(h.route.points, hasLength(3));
    expect(h.state.currentPoints, isEmpty);
  });

  group('dragging a selected committed route', () {
    testWidgets(
      'moves the point under the finger, and the WHOLE drag is one undo — '
      'not one per frame (§3.1)',
      (tester) async {
        final h = await _pumpCanvas(tester);
        await h.commitThreePointRoute();
        // commitRoute consumes the draft's own ops, so the stack starts clean
        // and anything on it afterwards came from the drag.
        expect(h.state.undoStack, isEmpty);

        await h.dragFrom(h.at(0.5, 0.5), [
          h.at(0.55, 0.5),
          h.at(0.6, 0.5),
          h.at(0.65, 0.5),
          h.at(0.7, 0.5),
        ]);

        expect(h.route.points[1].dx, closeTo(0.7, 0.005));
        expect(h.route.points[1].dy, closeTo(0.5, 0.005));
        expect(
          h.route.points[0],
          const Offset(0.2, 0.2),
          reason: 'only the grabbed point moves',
        );
        expect(
          h.state.undoStack,
          hasLength(1),
          reason: 'four move frames, one gesture, one undo entry',
        );

        await h.notifier.undo();
        expect(
          h.route.points[1],
          const Offset(0.5, 0.5),
          reason: 'undo rewinds the whole drag, not its last frame',
        );
      },
    );

    testWidgets('moves a marker, leaving its type alone', (tester) async {
      final h = await _pumpCanvas(tester);
      await h.commitThreePointRoute();
      h.notifier.setActiveSymbol(SymbolType.anchor);
      await h.notifier.placeSymbol(const Offset(0.35, 0.35));
      h.notifier.setActiveSymbol(null);
      await tester.pump();

      await h.dragFrom(h.at(0.35, 0.35), [h.at(0.45, 0.6)]);

      final symbol = h.route.symbols.single;
      expect(symbol.position.dx, closeTo(0.45, 0.005));
      expect(symbol.position.dy, closeTo(0.6, 0.005));
      expect(symbol.type, SymbolType.anchor);
      expect(h.route.points, hasLength(3));
    });

    testWidgets(
      'the DRAFT line wins when both have a handle at the same spot — a '
      'route being drawn right now is what is under the finger',
      (tester) async {
        final h = await _pumpCanvas(tester);
        await h.commitThreePointRoute();
        // A new line in progress, whose second point lands exactly on the
        // committed route's middle point.
        h.notifier.addPoint(const Offset(0.9, 0.1));
        h.notifier.addPoint(const Offset(0.5, 0.5));
        await tester.pump();

        await h.dragFrom(h.at(0.5, 0.5), [h.at(0.3, 0.7)]);

        expect(h.state.currentPoints[1].dx, closeTo(0.3, 0.005));
        expect(
          h.route.points[1],
          const Offset(0.5, 0.5),
          reason: 'the committed route must not have moved',
        );
      },
    );

    testWidgets(
      'a touch that grabs a handle but never moves records nothing — an undo '
      'entry that does nothing when pressed is worse than no entry',
      (tester) async {
        final h = await _pumpCanvas(tester);
        await h.commitThreePointRoute();

        // Down and up on the handle, with no movement in between: the gesture
        // opens an edit and closes it having changed nothing.
        final gesture = await tester.startGesture(h.at(0.5, 0.5));
        await tester.pump();
        await gesture.up();
        await tester.pumpAndSettle();

        expect(h.route.points[1], const Offset(0.5, 0.5));
        expect(h.state.undoStack, isEmpty);
      },
    );
  });

  testWidgets(
    'tapping empty canvas still adds a point — the new candidates sit ABOVE '
    'the draw action, they do not replace it',
    (tester) async {
      final h = await _pumpCanvas(tester);
      await h.commitThreePointRoute();

      await tester.tapAt(h.at(0.05, 0.9));
      await tester.pumpAndSettle();

      expect(h.state.currentPoints, hasLength(1));
      expect(h.route.points, hasLength(3));
    },
  );
}
