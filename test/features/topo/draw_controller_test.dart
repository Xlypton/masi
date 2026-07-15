import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:climbtopo/core/grades/grade_system.dart';
import 'package:climbtopo/features/topo/application/draw_controller.dart';
import 'package:climbtopo/features/topo/domain/topo_route.dart';

void main() {
  late ProviderContainer container;

  setUp(() {
    container = ProviderContainer();
    addTearDown(container.dispose);
  });

  test('initial state is view mode with empty points/routes', () {
    final state = container.read(drawControllerProvider);

    expect(state.mode, DrawMode.view);
    expect(state.currentPoints, isEmpty);
    expect(state.routes, isEmpty);
    expect(state.selectedRouteId, isNull);
    expect(state.activeSymbol, isNull);
    expect(state.nextId, 1);
    expect(state.nextNumber, 1);
  });

  test('toggleMode flips view <-> draw', () {
    final notifier = container.read(drawControllerProvider.notifier);

    expect(container.read(drawControllerProvider).mode, DrawMode.view);

    notifier.toggleMode();
    expect(container.read(drawControllerProvider).mode, DrawMode.draw);

    notifier.toggleMode();
    expect(container.read(drawControllerProvider).mode, DrawMode.view);
  });

  test('setMode sets mode explicitly', () {
    final notifier = container.read(drawControllerProvider.notifier);

    notifier.setMode(DrawMode.draw);
    expect(container.read(drawControllerProvider).mode, DrawMode.draw);

    notifier.setMode(DrawMode.draw);
    expect(container.read(drawControllerProvider).mode, DrawMode.draw);

    notifier.setMode(DrawMode.view);
    expect(container.read(drawControllerProvider).mode, DrawMode.view);
  });

  test('addPoint appends and increments length', () {
    final notifier = container.read(drawControllerProvider.notifier);

    notifier.addPoint(const Offset(0.1, 0.1));
    expect(container.read(drawControllerProvider).currentPoints, [
      const Offset(0.1, 0.1),
    ]);

    notifier.addPoint(const Offset(0.2, 0.2));
    expect(container.read(drawControllerProvider).currentPoints, [
      const Offset(0.1, 0.1),
      const Offset(0.2, 0.2),
    ]);
  });

  test(
    'undo/redo round trip; new addPoint after undo clears redo stack',
    () {
      final notifier = container.read(drawControllerProvider.notifier);

      notifier.addPoint(const Offset(0.1, 0.1));
      notifier.addPoint(const Offset(0.2, 0.2));
      expect(container.read(drawControllerProvider).currentPoints.length, 2);

      notifier.undo();
      expect(container.read(drawControllerProvider).currentPoints, [
        const Offset(0.1, 0.1),
      ]);

      notifier.redo();
      expect(container.read(drawControllerProvider).currentPoints, [
        const Offset(0.1, 0.1),
        const Offset(0.2, 0.2),
      ]);

      // Undo again, then add a new point: redo stack must be cleared.
      notifier.undo();
      expect(container.read(drawControllerProvider).currentPoints, [
        const Offset(0.1, 0.1),
      ]);

      notifier.addPoint(const Offset(0.3, 0.3));
      expect(container.read(drawControllerProvider).currentPoints, [
        const Offset(0.1, 0.1),
        const Offset(0.3, 0.3),
      ]);

      // Redo should now be a no-op since the redo stack was cleared.
      notifier.redo();
      expect(container.read(drawControllerProvider).currentPoints, [
        const Offset(0.1, 0.1),
        const Offset(0.3, 0.3),
      ]);
    },
  );

  test('undo is a no-op when currentPoints is empty', () {
    final notifier = container.read(drawControllerProvider.notifier);

    notifier.undo();
    expect(container.read(drawControllerProvider).currentPoints, isEmpty);
  });

  test('redo is a no-op when redo stack is empty', () {
    final notifier = container.read(drawControllerProvider.notifier);

    notifier.addPoint(const Offset(0.1, 0.1));
    notifier.redo();
    expect(container.read(drawControllerProvider).currentPoints, [
      const Offset(0.1, 0.1),
    ]);
  });

  test('commitRoute moves >=2 points into routes and empties '
      'currentPoints', () {
    final notifier = container.read(drawControllerProvider.notifier);

    notifier.addPoint(const Offset(0.1, 0.1));
    notifier.addPoint(const Offset(0.2, 0.2));
    notifier.addPoint(const Offset(0.3, 0.3));

    notifier.commitRoute();

    final state = container.read(drawControllerProvider);
    expect(state.currentPoints, isEmpty);
    expect(state.routes.length, 1);
    expect(state.routes.first.points, [
      const Offset(0.1, 0.1),
      const Offset(0.2, 0.2),
      const Offset(0.3, 0.3),
    ]);
  });

  test('commitRoute with <2 points is a no-op', () {
    final notifier = container.read(drawControllerProvider.notifier);

    notifier.addPoint(const Offset(0.1, 0.1));
    final before = container.read(drawControllerProvider);

    notifier.commitRoute();

    final after = container.read(drawControllerProvider);
    expect(after.currentPoints, before.currentPoints);
    expect(after.routes, before.routes);
    expect(after.routes, isEmpty);
  });

  test('commitRoute clears the redo stack', () {
    final notifier = container.read(drawControllerProvider.notifier);

    notifier.addPoint(const Offset(0.1, 0.1));
    notifier.addPoint(const Offset(0.2, 0.2));
    notifier.undo();
    notifier.addPoint(const Offset(0.2, 0.2));
    notifier.commitRoute();

    // Redo stack should be empty post-commit, so redo is a no-op.
    notifier.redo();
    expect(container.read(drawControllerProvider).currentPoints, isEmpty);
  });

  test('movePoint replaces the point at index, others unchanged', () {
    final notifier = container.read(drawControllerProvider.notifier);

    notifier.addPoint(const Offset(0.1, 0.1));
    notifier.addPoint(const Offset(0.2, 0.2));
    notifier.addPoint(const Offset(0.3, 0.3));

    notifier.movePoint(0, const Offset(0.9, 0.9));

    expect(container.read(drawControllerProvider).currentPoints, [
      const Offset(0.9, 0.9),
      const Offset(0.2, 0.2),
      const Offset(0.3, 0.3),
    ]);
  });

  test(
    'movePoint with an out-of-range index is a safe no-op (does not throw)',
    () {
      final notifier = container.read(drawControllerProvider.notifier);

      notifier.addPoint(const Offset(0.1, 0.1));
      notifier.addPoint(const Offset(0.2, 0.2));
      final before = container.read(drawControllerProvider);

      expect(
        () => notifier.movePoint(5, const Offset(0.9, 0.9)),
        returnsNormally,
      );
      expect(
        container.read(drawControllerProvider).currentPoints,
        before.currentPoints,
      );

      expect(
        () => notifier.movePoint(-1, const Offset(0.9, 0.9)),
        returnsNormally,
      );
      expect(
        container.read(drawControllerProvider).currentPoints,
        before.currentPoints,
      );
    },
  );

  test('commitRoute pushes a copy, not a reference, of currentPoints', () {
    final notifier = container.read(drawControllerProvider.notifier);

    notifier.addPoint(const Offset(0.1, 0.1));
    notifier.addPoint(const Offset(0.2, 0.2));
    notifier.commitRoute();

    final firstCommitted = container
        .read(drawControllerProvider)
        .routes
        .first
        .points;

    // Start a new current route and commit again.
    notifier.addPoint(const Offset(0.3, 0.3));
    notifier.addPoint(const Offset(0.4, 0.4));

    // The already-committed route must be unaffected by the new
    // currentPoints list (i.e. it's not the same list instance).
    expect(
      identical(
        firstCommitted,
        container.read(drawControllerProvider).currentPoints,
      ),
      isFalse,
    );
    expect(firstCommitted, [const Offset(0.1, 0.1), const Offset(0.2, 0.2)]);

    notifier.commitRoute();

    final state = container.read(drawControllerProvider);
    expect(state.routes.length, 2);
    expect(
      identical(state.routes[0].points, state.routes[1].points),
      isFalse,
    );
    expect(state.routes[0].points, [
      const Offset(0.1, 0.1),
      const Offset(0.2, 0.2),
    ]);
    expect(state.routes[1].points, [
      const Offset(0.3, 0.3),
      const Offset(0.4, 0.4),
    ]);
  });

  test('commitRoute at exactly 2 points commits successfully (boundary)', () {
    final notifier = container.read(drawControllerProvider.notifier);

    notifier.addPoint(const Offset(0.1, 0.1));
    notifier.addPoint(const Offset(0.2, 0.2));
    notifier.commitRoute();

    final state = container.read(drawControllerProvider);
    expect(state.currentPoints, isEmpty);
    expect(state.routes.length, 1);
    expect(state.routes.first.points, [
      const Offset(0.1, 0.1),
      const Offset(0.2, 0.2),
    ]);
  });

  test('undo/redo preserves original order: addPoint(A,B); undo x2; redo x2 '
      '=> [A, B]', () {
    final notifier = container.read(drawControllerProvider.notifier);
    const a = Offset(0.1, 0.1);
    const b = Offset(0.2, 0.2);

    notifier.addPoint(a);
    notifier.addPoint(b);
    notifier.undo();
    notifier.undo();
    notifier.redo();
    notifier.redo();

    expect(container.read(drawControllerProvider).currentPoints, [a, b]);
  });

  test('clearCurrent empties currentPoints and the redo stack', () {
    final notifier = container.read(drawControllerProvider.notifier);

    notifier.addPoint(const Offset(0.1, 0.1));
    notifier.addPoint(const Offset(0.2, 0.2));
    notifier.undo();

    notifier.clearCurrent();
    expect(container.read(drawControllerProvider).currentPoints, isEmpty);

    // Redo stack cleared too.
    notifier.redo();
    expect(container.read(drawControllerProvider).currentPoints, isEmpty);
  });

  // --- M2: multi-route, selection, visibility, symbols ---------------------

  test(
    'A1: committing two routes assigns sequential ids/numbers and '
    'palette-derived colorIndex, and advances nextId/nextNumber',
    () {
      final notifier = container.read(drawControllerProvider.notifier);

      notifier.addPoint(const Offset(0.1, 0.1));
      notifier.addPoint(const Offset(0.2, 0.2));
      notifier.commitRoute();
      expect(container.read(drawControllerProvider).currentPoints, isEmpty);

      notifier.addPoint(const Offset(0.3, 0.3));
      notifier.addPoint(const Offset(0.4, 0.4));
      notifier.commitRoute();
      expect(container.read(drawControllerProvider).currentPoints, isEmpty);

      final state = container.read(drawControllerProvider);
      expect(state.routes.length, 2);

      expect(state.routes[0].number, 1);
      expect(state.routes[0].colorIndex, routeColorIndexFor(1));
      expect(state.routes[1].number, 2);
      expect(state.routes[1].colorIndex, routeColorIndexFor(2));

      expect(state.routes[0].id, isNot(state.routes[1].id));
      expect(state.nextId, 3);
      expect(state.nextNumber, 3);
    },
  );

  test('A3: selectRoute sets an existing id, null clears it, and an absent '
      'id is a no-op', () {
    final notifier = container.read(drawControllerProvider.notifier);

    notifier.addPoint(const Offset(0.1, 0.1));
    notifier.addPoint(const Offset(0.2, 0.2));
    notifier.commitRoute();
    final routeId = container.read(drawControllerProvider).routes.first.id;

    notifier.selectRoute(routeId);
    expect(container.read(drawControllerProvider).selectedRouteId, routeId);

    // Absent id: no-op, selection unchanged.
    notifier.selectRoute(routeId + 999);
    expect(container.read(drawControllerProvider).selectedRouteId, routeId);

    notifier.selectRoute(null);
    expect(container.read(drawControllerProvider).selectedRouteId, isNull);

    // Absent id while nothing is selected: still a no-op (stays null).
    notifier.selectRoute(routeId + 999);
    expect(container.read(drawControllerProvider).selectedRouteId, isNull);
  });

  test(
    'A4: toggleRouteVisibility flips only the targeted route\'s visible flag',
    () {
      final notifier = container.read(drawControllerProvider.notifier);

      notifier.addPoint(const Offset(0.1, 0.1));
      notifier.addPoint(const Offset(0.2, 0.2));
      notifier.commitRoute();

      notifier.addPoint(const Offset(0.3, 0.3));
      notifier.addPoint(const Offset(0.4, 0.4));
      notifier.commitRoute();

      final before = container.read(drawControllerProvider).routes;
      final firstId = before[0].id;
      expect(before[0].visible, isTrue);
      expect(before[1].visible, isTrue);

      notifier.toggleRouteVisibility(firstId);

      final after = container.read(drawControllerProvider).routes;
      expect(after[0].visible, isFalse);
      expect(after[1].visible, isTrue);
      // Toggling back.
      notifier.toggleRouteVisibility(firstId);
      expect(
        container.read(drawControllerProvider).routes[0].visible,
        isTrue,
      );
    },
  );

  test('toggleRouteVisibility with an absent id is a no-op', () {
    final notifier = container.read(drawControllerProvider.notifier);

    notifier.addPoint(const Offset(0.1, 0.1));
    notifier.addPoint(const Offset(0.2, 0.2));
    notifier.commitRoute();
    final before = container.read(drawControllerProvider).routes;

    notifier.toggleRouteVisibility(9999);

    expect(container.read(drawControllerProvider).routes, before);
  });

  test(
    'A5: placeSymbol with a selection and active symbol appends to the '
    'selected route only',
    () {
      final notifier = container.read(drawControllerProvider.notifier);

      notifier.addPoint(const Offset(0.1, 0.1));
      notifier.addPoint(const Offset(0.2, 0.2));
      notifier.commitRoute();

      notifier.addPoint(const Offset(0.3, 0.3));
      notifier.addPoint(const Offset(0.4, 0.4));
      notifier.commitRoute();

      final routes = container.read(drawControllerProvider).routes;
      final targetId = routes[0].id;

      notifier.selectRoute(targetId);
      notifier.setActiveSymbol(SymbolType.bolt);

      const placedAt = Offset(0.15, 0.15);
      notifier.placeSymbol(placedAt);

      final state = container.read(drawControllerProvider);
      final target = state.routes.firstWhere((r) => r.id == targetId);
      final other = state.routes.firstWhere((r) => r.id != targetId);

      expect(target.symbols, [
        const TopoSymbol(type: SymbolType.bolt, position: placedAt),
      ]);
      expect(other.symbols, isEmpty);
    },
  );

  // --- Symbol-placement fix: auto-select + hint (see draw_controller.dart's
  // placeSymbol doc and lib/features/topo/presentation/topo_canvas.dart's
  // _beginInteraction) -------------------------------------------------
  //
  // BEFORE this fix, `placeSymbol` with no selected route silently no-oped
  // regardless of whether any routes existed at all -- the two tests this
  // section replaces ('placeSymbol is a no-op when there is no selected
  // route' and 'placeSymbol is a no-op when there is no active symbol')
  // asserted exactly that pure no-op for BOTH cases. That silent no-op when
  // routes DID exist (just none selected) was the bug: a user who activated
  // a symbol without first tapping a route to select it got a canvas that
  // appeared totally unresponsive. S1 below is the corrected replacement for
  // the "no selected route" case (routes non-empty now auto-selects
  // routes.last instead of no-op'ing). S2 covers the genuinely-empty-routes
  // case, which still cannot place anything but must now be distinguishable
  // (via the returned outcome) so the caller can show a hint instead of
  // doing nothing. S4/S4b preserve the "no active symbol" no-op verbatim
  // (that half of the old behavior was correct and is NOT changed) while
  // additionally asserting the new outcome value and the no-routes-at-all
  // sub-case.

  test(
    'S1: placeSymbol with no route selected but routes non-empty '
    'auto-selects routes.last and places the symbol there',
    () async {
      final notifier = container.read(drawControllerProvider.notifier);

      notifier.addPoint(const Offset(0.1, 0.1));
      notifier.addPoint(const Offset(0.2, 0.2));
      notifier.commitRoute();

      notifier.addPoint(const Offset(0.3, 0.3));
      notifier.addPoint(const Offset(0.4, 0.4));
      notifier.commitRoute();

      final routes = container.read(drawControllerProvider).routes;
      final r1 = routes[0];
      final r2 = routes[1];
      expect(container.read(drawControllerProvider).selectedRouteId, isNull);

      notifier.setActiveSymbol(SymbolType.bolt);
      const placedAt = Offset(0.5, 0.5);
      final outcome = await notifier.placeSymbol(placedAt);

      expect(outcome, SymbolPlacementOutcome.autoSelectedAndPlaced);

      final state = container.read(drawControllerProvider);
      expect(state.selectedRouteId, r2.id);
      final updatedR2 = state.routes.firstWhere((r) => r.id == r2.id);
      final updatedR1 = state.routes.firstWhere((r) => r.id == r1.id);
      expect(updatedR2.symbols, [
        const TopoSymbol(type: SymbolType.bolt, position: placedAt),
      ]);
      expect(updatedR1.symbols, isEmpty);
    },
  );

  test(
    'S2: placeSymbol with routes empty does not throw, places nothing, '
    'leaves selectedRouteId null, and returns noRouteAvailable',
    () async {
      final notifier = container.read(drawControllerProvider.notifier);
      notifier.setActiveSymbol(SymbolType.bolt);
      expect(container.read(drawControllerProvider).routes, isEmpty);

      final outcome = await notifier.placeSymbol(const Offset(0.5, 0.5));

      expect(outcome, SymbolPlacementOutcome.noRouteAvailable);
      final state = container.read(drawControllerProvider);
      expect(state.routes, isEmpty);
      expect(state.selectedRouteId, isNull);
    },
  );

  test(
    'S3: placeSymbol with a route already explicitly selected places on '
    'THAT route (not routes.last, if different), leaves selectedRouteId '
    'unchanged, and returns the plain placed outcome (distinguishable from '
    'auto-selected)',
    () async {
      final notifier = container.read(drawControllerProvider.notifier);

      notifier.addPoint(const Offset(0.1, 0.1));
      notifier.addPoint(const Offset(0.2, 0.2));
      notifier.commitRoute();

      notifier.addPoint(const Offset(0.3, 0.3));
      notifier.addPoint(const Offset(0.4, 0.4));
      notifier.commitRoute();

      final routes = container.read(drawControllerProvider).routes;
      final r1 = routes[0];
      final r2 = routes[1];

      // Explicitly select r1 -- NOT routes.last (r2) -- so a bug that
      // ignored the explicit selection and fell back to routes.last would
      // be caught.
      notifier.selectRoute(r1.id);
      notifier.setActiveSymbol(SymbolType.anchor);

      const placedAt = Offset(0.15, 0.15);
      final outcome = await notifier.placeSymbol(placedAt);

      expect(outcome, SymbolPlacementOutcome.placed);
      expect(outcome, isNot(SymbolPlacementOutcome.autoSelectedAndPlaced));

      final state = container.read(drawControllerProvider);
      expect(state.selectedRouteId, r1.id);
      final updatedR1 = state.routes.firstWhere((r) => r.id == r1.id);
      final updatedR2 = state.routes.firstWhere((r) => r.id == r2.id);
      expect(updatedR1.symbols, [
        const TopoSymbol(type: SymbolType.anchor, position: placedAt),
      ]);
      expect(updatedR2.symbols, isEmpty);
    },
  );

  test(
    'S4: addPoint still appends to currentPoints exactly as before when no '
    'symbol is active -- the line-drawing path is untouched by the '
    'placeSymbol auto-select/hint fix',
    () {
      final notifier = container.read(drawControllerProvider.notifier);
      expect(container.read(drawControllerProvider).activeSymbol, isNull);

      notifier.addPoint(const Offset(0.7, 0.7));
      expect(container.read(drawControllerProvider).currentPoints, [
        const Offset(0.7, 0.7),
      ]);

      notifier.addPoint(const Offset(0.8, 0.8));
      expect(container.read(drawControllerProvider).currentPoints, [
        const Offset(0.7, 0.7),
        const Offset(0.8, 0.8),
      ]);
    },
  );

  test(
    'S4b: placeSymbol with no active symbol returns noActiveSymbol and '
    'makes no state change, even with a route already selected',
    () async {
      final notifier = container.read(drawControllerProvider.notifier);

      notifier.addPoint(const Offset(0.1, 0.1));
      notifier.addPoint(const Offset(0.2, 0.2));
      notifier.commitRoute();
      final routeId = container.read(drawControllerProvider).routes.first.id;
      notifier.selectRoute(routeId);
      expect(container.read(drawControllerProvider).activeSymbol, isNull);

      final before = container.read(drawControllerProvider);
      final outcome = await notifier.placeSymbol(const Offset(0.5, 0.5));

      expect(outcome, SymbolPlacementOutcome.noActiveSymbol);
      final after = container.read(drawControllerProvider);
      expect(after.routes, before.routes);
      expect(after.selectedRouteId, before.selectedRouteId);
      expect(after.currentPoints, before.currentPoints);
    },
  );

  test(
    'placeSymbol with no active symbol is a no-op and returns '
    'noActiveSymbol even with no route selected and no routes at all',
    () async {
      final notifier = container.read(drawControllerProvider.notifier);
      expect(container.read(drawControllerProvider).activeSymbol, isNull);
      expect(container.read(drawControllerProvider).selectedRouteId, isNull);
      expect(container.read(drawControllerProvider).routes, isEmpty);

      final outcome = await notifier.placeSymbol(const Offset(0.5, 0.5));

      expect(outcome, SymbolPlacementOutcome.noActiveSymbol);
      expect(container.read(drawControllerProvider).routes, isEmpty);
      expect(container.read(drawControllerProvider).selectedRouteId, isNull);
    },
  );

  test(
    'A6: removeRoute removes the route and clears selectedRouteId iff it '
    'pointed at the removed route',
    () {
      final notifier = container.read(drawControllerProvider.notifier);

      notifier.addPoint(const Offset(0.1, 0.1));
      notifier.addPoint(const Offset(0.2, 0.2));
      notifier.commitRoute();

      notifier.addPoint(const Offset(0.3, 0.3));
      notifier.addPoint(const Offset(0.4, 0.4));
      notifier.commitRoute();

      final routes = container.read(drawControllerProvider).routes;
      final firstId = routes[0].id;
      final secondId = routes[1].id;

      // Selecting a route NOT being removed: selection survives removal.
      notifier.selectRoute(secondId);
      notifier.removeRoute(firstId);

      var state = container.read(drawControllerProvider);
      expect(state.routes.length, 1);
      expect(state.routes.first.id, secondId);
      expect(state.selectedRouteId, secondId);

      // Removing the selected route clears the selection.
      notifier.removeRoute(secondId);
      state = container.read(drawControllerProvider);
      expect(state.routes, isEmpty);
      expect(state.selectedRouteId, isNull);
    },
  );

  test('removeRoute with an absent id is a no-op', () {
    final notifier = container.read(drawControllerProvider.notifier);

    notifier.addPoint(const Offset(0.1, 0.1));
    notifier.addPoint(const Offset(0.2, 0.2));
    notifier.commitRoute();
    final before = container.read(drawControllerProvider);

    notifier.removeRoute(9999);

    final after = container.read(drawControllerProvider);
    expect(after.routes, before.routes);
    expect(after.selectedRouteId, before.selectedRouteId);
  });

  // --- M4: route metadata / grade-key computation ---------------------

  test(
    'A1: setRouteMetadata sets name/grade and computes gradeSortKey from '
    'the grade service; other routes are unchanged',
    () async {
      final notifier = container.read(drawControllerProvider.notifier);

      notifier.addPoint(const Offset(0.1, 0.1));
      notifier.addPoint(const Offset(0.2, 0.2));
      notifier.commitRoute();

      notifier.addPoint(const Offset(0.3, 0.3));
      notifier.addPoint(const Offset(0.4, 0.4));
      notifier.commitRoute();

      final routes = container.read(drawControllerProvider).routes;
      final targetId = routes[0].id;
      final otherBefore = routes[1];

      await notifier.setRouteMetadata(
        targetId,
        name: 'Crux',
        gradeSystem: GradeSystem.french,
        gradeRaw: '6a+',
      );

      final state = container.read(drawControllerProvider);
      final target = state.routes.firstWhere((r) => r.id == targetId);
      final other = state.routes.firstWhere((r) => r.id != targetId);

      expect(target.name, 'Crux');
      expect(target.gradeSystem, GradeSystem.french);
      expect(target.gradeRaw, '6a+');
      expect(
        target.gradeSortKey,
        gradeSortKey(GradeSystem.french, '6a+'),
      );
      expect(target.gradeSortKey, isNotNull);
      expect(other, otherBefore);
    },
  );

  test(
    'A2: setRouteMetadata with an invalid grade leaves gradeSortKey null '
    'without throwing, while still setting other provided fields',
    () async {
      final notifier = container.read(drawControllerProvider.notifier);

      notifier.addPoint(const Offset(0.1, 0.1));
      notifier.addPoint(const Offset(0.2, 0.2));
      notifier.commitRoute();
      final routeId = container.read(drawControllerProvider).routes.single.id;

      await notifier.setRouteMetadata(
        routeId,
        name: 'Bad Grade Route',
        gradeSystem: GradeSystem.french,
        gradeRaw: 'zzz',
      );

      final route = container.read(drawControllerProvider).routes.single;
      expect(route.name, 'Bad Grade Route');
      expect(route.gradeSystem, GradeSystem.french);
      expect(route.gradeRaw, 'zzz');
      expect(route.gradeSortKey, isNull);
    },
  );

  test(
    'A4: setRouteMetadata mutates state synchronously before any await '
    '(un-awaited call still shows the update immediately)',
    () {
      final notifier = container.read(drawControllerProvider.notifier);

      notifier.addPoint(const Offset(0.1, 0.1));
      notifier.addPoint(const Offset(0.2, 0.2));
      notifier.commitRoute();
      final routeId = container.read(drawControllerProvider).routes.single.id;

      // Deliberately not awaited.
      // ignore: unawaited_futures
      notifier.setRouteMetadata(routeId, name: 'Immediate');

      final route = container.read(drawControllerProvider).routes.single;
      expect(route.name, 'Immediate');
    },
  );

  test('A5: setRouteMetadata with an unknown id is a no-op (no throw)', () async {
    final notifier = container.read(drawControllerProvider.notifier);

    notifier.addPoint(const Offset(0.1, 0.1));
    notifier.addPoint(const Offset(0.2, 0.2));
    notifier.commitRoute();
    final before = container.read(drawControllerProvider).routes;

    await notifier.setRouteMetadata(
      9999,
      name: 'Ghost',
      gradeSystem: GradeSystem.french,
      gradeRaw: '6a',
    );

    expect(container.read(drawControllerProvider).routes, before);
  });

  test(
    'A10: setRouteMetadata with a valid grade followed by an invalid grade '
    'clears the stale gradeSortKey instead of leaving it stale',
    () async {
      final notifier = container.read(drawControllerProvider.notifier);

      notifier.addPoint(const Offset(0.1, 0.1));
      notifier.addPoint(const Offset(0.2, 0.2));
      notifier.commitRoute();
      final routeId = container.read(drawControllerProvider).routes.single.id;

      await notifier.setRouteMetadata(
        routeId,
        gradeSystem: GradeSystem.french,
        gradeRaw: '6a+',
      );
      final graded = container.read(drawControllerProvider).routes.single;
      expect(graded.gradeSortKey, isNotNull);

      await notifier.setRouteMetadata(
        routeId,
        gradeSystem: GradeSystem.french,
        gradeRaw: 'zzz',
      );

      final route = container.read(drawControllerProvider).routes.single;
      expect(route.gradeRaw, 'zzz');
      expect(route.gradeSortKey, isNull);
    },
  );

  test(
    'A11: setRouteMetadata is AUTHORITATIVE — a call with only name '
    'provided (grade args omitted/null) CLEARS a previously-set grade, '
    'since RouteMetadataSheet always sends the full sheet state and '
    'omitted now means "cleared", not "unchanged"',
    () async {
      final notifier = container.read(drawControllerProvider.notifier);

      notifier.addPoint(const Offset(0.1, 0.1));
      notifier.addPoint(const Offset(0.2, 0.2));
      notifier.commitRoute();
      final routeId = container.read(drawControllerProvider).routes.single.id;

      await notifier.setRouteMetadata(
        routeId,
        gradeSystem: GradeSystem.french,
        gradeRaw: '6a+',
      );
      final graded = container.read(drawControllerProvider).routes.single;
      expect(graded.gradeSortKey, isNotNull);

      // A save with name + grade both provided sets both.
      await notifier.setRouteMetadata(
        routeId,
        name: 'Named And Graded',
        gradeSystem: GradeSystem.french,
        gradeRaw: '7a',
      );
      final namedAndGraded = container.read(drawControllerProvider).routes.single;
      expect(namedAndGraded.name, 'Named And Graded');
      expect(namedAndGraded.gradeRaw, '7a');
      expect(namedAndGraded.gradeSortKey, gradeSortKey(GradeSystem.french, '7a'));

      // A save with only name (grade args null, as a sheet with the grade
      // dropdown cleared would send) clears the grade entirely.
      await notifier.setRouteMetadata(routeId, name: 'Name Only');

      final route = container.read(drawControllerProvider).routes.single;
      expect(route.name, 'Name Only');
      expect(route.gradeSystem, isNull);
      expect(route.gradeRaw, isNull);
      expect(route.gradeSortKey, isNull);
    },
  );

  test(
    'setRouteMetadata clears the name when name:null is passed (matching '
    'the sheet\'s name field having been emptied) instead of preserving '
    'the old name',
    () async {
      final notifier = container.read(drawControllerProvider.notifier);

      notifier.addPoint(const Offset(0.1, 0.1));
      notifier.addPoint(const Offset(0.2, 0.2));
      notifier.commitRoute();
      final routeId = container.read(drawControllerProvider).routes.single.id;

      await notifier.setRouteMetadata(routeId, name: 'Has A Name');
      expect(
        container.read(drawControllerProvider).routes.single.name,
        'Has A Name',
      );

      await notifier.setRouteMetadata(routeId, name: null);

      expect(container.read(drawControllerProvider).routes.single.name, isNull);
    },
  );

  test(
    'setRouteMetadata clears style and description when passed null, '
    'matching the sheet fields having been emptied',
    () async {
      final notifier = container.read(drawControllerProvider.notifier);

      notifier.addPoint(const Offset(0.1, 0.1));
      notifier.addPoint(const Offset(0.2, 0.2));
      notifier.commitRoute();
      final routeId = container.read(drawControllerProvider).routes.single.id;

      await notifier.setRouteMetadata(
        routeId,
        style: 'trad',
        description: 'Some beta notes.',
      );
      final withMeta = container.read(drawControllerProvider).routes.single;
      expect(withMeta.style, 'trad');
      expect(withMeta.description, 'Some beta notes.');

      await notifier.setRouteMetadata(routeId, style: null, description: null);

      final cleared = container.read(drawControllerProvider).routes.single;
      expect(cleared.style, isNull);
      expect(cleared.description, isNull);
    },
  );

  test(
    'setRouteMetadata with no active wall updates in-memory state and does '
    'not throw (no DB touched)',
    () async {
      final notifier = container.read(drawControllerProvider.notifier);

      notifier.addPoint(const Offset(0.1, 0.1));
      notifier.addPoint(const Offset(0.2, 0.2));
      notifier.commitRoute();
      final routeId = container.read(drawControllerProvider).routes.single.id;
      expect(container.read(drawControllerProvider).activeWallId, isNull);

      await expectLater(
        notifier.setRouteMetadata(
          routeId,
          name: 'No Wall',
          gradeSystem: GradeSystem.uiaa,
          gradeRaw: 'VI+',
        ),
        completes,
      );

      final route = container.read(drawControllerProvider).routes.single;
      expect(route.name, 'No Wall');
      expect(route.gradeSystem, GradeSystem.uiaa);
      expect(route.gradeRaw, 'VI+');
      expect(route.gradeSortKey, gradeSortKey(GradeSystem.uiaa, 'VI+'));
    },
  );

  test('setActiveSymbol sets and clears the active symbol', () {
    final notifier = container.read(drawControllerProvider.notifier);

    notifier.setActiveSymbol(SymbolType.crux);
    expect(
      container.read(drawControllerProvider).activeSymbol,
      SymbolType.crux,
    );

    notifier.setActiveSymbol(null);
    expect(container.read(drawControllerProvider).activeSymbol, isNull);
  });
}
