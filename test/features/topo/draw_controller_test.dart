import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:climbtopo/features/topo/application/draw_controller.dart';

void main() {
  late ProviderContainer container;

  setUp(() {
    container = ProviderContainer();
    addTearDown(container.dispose);
  });

  test('A1: initial state is view mode with empty points/routes', () {
    final state = container.read(drawControllerProvider);

    expect(state.mode, DrawMode.view);
    expect(state.currentPoints, isEmpty);
    expect(state.completedRoutes, isEmpty);
  });

  test('A2: toggleMode flips view <-> draw', () {
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

  test('A3: addPoint appends and increments length', () {
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
    'A4: undo/redo round trip; new addPoint after undo clears redo stack',
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

  test('A5: commitRoute moves >=2 points into completedRoutes and empties '
      'currentPoints', () {
    final notifier = container.read(drawControllerProvider.notifier);

    notifier.addPoint(const Offset(0.1, 0.1));
    notifier.addPoint(const Offset(0.2, 0.2));
    notifier.addPoint(const Offset(0.3, 0.3));

    notifier.commitRoute();

    final state = container.read(drawControllerProvider);
    expect(state.currentPoints, isEmpty);
    expect(state.completedRoutes.length, 1);
    expect(state.completedRoutes.first, [
      const Offset(0.1, 0.1),
      const Offset(0.2, 0.2),
      const Offset(0.3, 0.3),
    ]);
  });

  test('A5: commitRoute with <2 points is a no-op', () {
    final notifier = container.read(drawControllerProvider.notifier);

    notifier.addPoint(const Offset(0.1, 0.1));
    final before = container.read(drawControllerProvider);

    notifier.commitRoute();

    final after = container.read(drawControllerProvider);
    expect(after.currentPoints, before.currentPoints);
    expect(after.completedRoutes, before.completedRoutes);
    expect(after.completedRoutes, isEmpty);
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

  test('A6: movePoint replaces the point at index, others unchanged', () {
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
        .completedRoutes
        .first;

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
    expect(state.completedRoutes.length, 2);
    expect(
      identical(state.completedRoutes[0], state.completedRoutes[1]),
      isFalse,
    );
    expect(state.completedRoutes[0], [
      const Offset(0.1, 0.1),
      const Offset(0.2, 0.2),
    ]);
    expect(state.completedRoutes[1], [
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
    expect(state.completedRoutes.length, 1);
    expect(state.completedRoutes.first, [
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
}
