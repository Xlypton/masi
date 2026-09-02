// "In edit mode, when I move around the image or zoom in and out, I always add
// an anchor or a route where I touched. Only deliberate touches should add
// something." (user report, 2026-09-02)
//
// Two separate holes, both of which this file pins:
//
//  * SYMBOLS FIRED ON POINTER-DOWN. Tapping to add a POINT was already
//    deferred to pointer-up and guarded by a movement slop, but placing a
//    symbol was not: it ran the moment a finger landed. With an anchor tool
//    selected, the opening finger of every pinch stamped an anchor on the rock
//    before the second finger had even arrived — so the guard that cancels the
//    first finger's gesture when a second one lands had nothing left to
//    cancel.
//  * A TAP THAT MOVED THE VIEW IS NOT A TAP. Counting fingers misses the
//    sloppy pinch whose first finger lifts a moment before the second lands,
//    and a fling still settling when the next touch arrives. Both look exactly
//    like a tap. What tells them apart is the view itself: a real tap in draw
//    mode cannot move the canvas (`panEnabled` is false and one finger cannot
//    scale), so a transform that changed between down and up proves the
//    gesture was a zoom or a pan.
//
// Pumps a bare TopoCanvas under a Scaffold — the same seam
// `symbol_placement_hint_test.dart` documents — so nothing here decodes a real
// image under fake time.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:masi/app/theme.dart';
import 'package:masi/features/topo/application/draw_controller.dart';
import 'package:masi/features/topo/domain/topo_route.dart';
import 'package:masi/features/topo/presentation/topo_canvas.dart';

const _wallId = 'test-wall';
const _imageSize = Size(400, 300);

Future<TransformationController> _pumpCanvas(
  WidgetTester tester,
  ProviderContainer container,
) async {
  tester.view.physicalSize = _imageSize;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final controller = TransformationController();
  addTearDown(controller.dispose);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: MasiTheme.light,
        home: Scaffold(
          body: TopoCanvas(
            wallId: _wallId,
            imagePath: '/nonexistent/deliberate-touch.jpg',
            imageSize: _imageSize,
            transformationController: controller,
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  return controller;
}

void main() {
  late ProviderContainer container;

  setUp(() {
    container = ProviderContainer();
    addTearDown(container.dispose);
    // FIX #6 (autoDispose pending-timer gotcha): hold the family provider open
    // for the life of the test.
    container.listen(drawControllerProvider(_wallId), (_, _) {});
  });

  DrawController notifier() =>
      container.read(drawControllerProvider(_wallId).notifier);
  DrawState state() => container.read(drawControllerProvider(_wallId));

  testWidgets('a deliberate tap still adds a point', (tester) async {
    notifier().setMode(DrawMode.draw);
    await _pumpCanvas(tester, container);

    await tester.tapAt(const Offset(200, 150));
    await tester.pump();

    expect(state().currentPoints, hasLength(1));
  });

  testWidgets('a deliberate tap still places a symbol', (tester) async {
    notifier().setMode(DrawMode.draw);
    // A committed route to place onto, so the "draw a route first" path is not
    // what this test is measuring.
    notifier().addPoint(const Offset(0.2, 0.2));
    notifier().addPoint(const Offset(0.3, 0.8));
    await notifier().commitRoute();
    notifier().setActiveSymbol(SymbolType.anchor);
    await _pumpCanvas(tester, container);

    await tester.tapAt(const Offset(200, 150));
    await tester.pumpAndSettle();

    expect(state().routes.single.symbols, hasLength(1));
    expect(state().routes.single.symbols.single.type, SymbolType.anchor);
  });

  testWidgets(
    'the opening finger of a PINCH places no symbol — the bug as reported: '
    'the anchor was written on pointer-down, before the second finger could '
    'cancel anything',
    (tester) async {
      notifier().setMode(DrawMode.draw);
      notifier().addPoint(const Offset(0.2, 0.2));
      notifier().addPoint(const Offset(0.3, 0.8));
      await notifier().commitRoute();
      notifier().setActiveSymbol(SymbolType.anchor);
      await _pumpCanvas(tester, container);

      // Finger one lands and barely moves — it is the pivot of the pinch.
      final one = await tester.startGesture(const Offset(200, 150));
      await tester.pump();
      expect(
        state().routes.single.symbols,
        isEmpty,
        reason: 'nothing may be written while a finger is merely down',
      );

      // Finger two arrives and spreads: this is a zoom, not a tap.
      final two = await tester.startGesture(const Offset(210, 160));
      await two.moveBy(const Offset(60, 60));
      await tester.pump();
      await one.up();
      await two.up();
      await tester.pumpAndSettle();

      expect(state().routes.single.symbols, isEmpty);
    },
  );

  testWidgets('the opening finger of a pinch adds no POINT either', (
    tester,
  ) async {
    notifier().setMode(DrawMode.draw);
    await _pumpCanvas(tester, container);

    final one = await tester.startGesture(const Offset(200, 150));
    await tester.pump();
    final two = await tester.startGesture(const Offset(210, 160));
    await two.moveBy(const Offset(60, 60));
    await tester.pump();
    await one.up();
    await two.up();
    await tester.pumpAndSettle();

    expect(state().currentPoints, isEmpty);
  });

  testWidgets(
    'a touch that moved the view adds nothing, even when the finger itself '
    'never moved and no second finger was ever seen',
    (tester) async {
      notifier().setMode(DrawMode.draw);
      final controller = await _pumpCanvas(tester, container);

      final finger = await tester.startGesture(const Offset(200, 150));
      await tester.pump();
      // Whatever moved the canvas — a pinch whose other finger has already
      // lifted, a fling still settling — the transform changed under a
      // stationary finger. That is not a tap.
      controller.value = Matrix4.identity()..translateByDouble(12, 8, 0, 1);
      await tester.pump();
      await finger.up();
      await tester.pumpAndSettle();

      expect(state().currentPoints, isEmpty);
    },
  );

  testWidgets('dragging across the photo still adds nothing', (tester) async {
    notifier().setMode(DrawMode.draw);
    await _pumpCanvas(tester, container);

    await tester.dragFrom(const Offset(120, 100), const Offset(90, 60));
    await tester.pumpAndSettle();

    expect(state().currentPoints, isEmpty);
  });

  testWidgets('dragging with a symbol tool active places nothing', (
    tester,
  ) async {
    notifier().setMode(DrawMode.draw);
    notifier().addPoint(const Offset(0.2, 0.2));
    notifier().addPoint(const Offset(0.3, 0.8));
    await notifier().commitRoute();
    notifier().setActiveSymbol(SymbolType.bolt);
    await _pumpCanvas(tester, container);

    await tester.dragFrom(const Offset(120, 100), const Offset(90, 60));
    await tester.pumpAndSettle();

    expect(state().routes.single.symbols, isEmpty);
  });
}
