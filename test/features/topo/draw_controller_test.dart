import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

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

  test('placeSymbol is a no-op when there is no selected route', () {
    final notifier = container.read(drawControllerProvider.notifier);

    notifier.addPoint(const Offset(0.1, 0.1));
    notifier.addPoint(const Offset(0.2, 0.2));
    notifier.commitRoute();

    notifier.setActiveSymbol(SymbolType.anchor);
    final before = container.read(drawControllerProvider).routes;

    notifier.placeSymbol(const Offset(0.5, 0.5));

    expect(container.read(drawControllerProvider).routes, before);
  });

  test('placeSymbol is a no-op when there is no active symbol', () {
    final notifier = container.read(drawControllerProvider.notifier);

    notifier.addPoint(const Offset(0.1, 0.1));
    notifier.addPoint(const Offset(0.2, 0.2));
    notifier.commitRoute();
    final routeId = container.read(drawControllerProvider).routes.first.id;

    notifier.selectRoute(routeId);
    final before = container.read(drawControllerProvider).routes;

    notifier.placeSymbol(const Offset(0.5, 0.5));

    expect(container.read(drawControllerProvider).routes, before);
  });

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
