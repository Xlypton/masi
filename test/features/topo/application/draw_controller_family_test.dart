import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:climbtopo/features/topo/application/draw_controller.dart';
import 'package:climbtopo/features/topo/presentation/route_legend.dart';

/// FIX #6 (HIGH, CONFIRMED — backlog #32, "family-key the canvas providers
/// by wallId"): [drawControllerProvider]/[legendExpandedProvider] used to be
/// single app-lifetime globals — two simultaneously-mounted [TopoCanvasScreen]
/// instances (e.g. the read-only embedded canvas inside a community
/// topo-detail page for wall A, plus a pushed editor for wall B) shared ONE
/// [DrawController]/[LegendExpandedController], clobbering each other's
/// state. These tests exercise the family conversion directly against a
/// [ProviderContainer] (mirroring `draw_controller_test.dart`'s style),
/// without needing any widget pumped: two different wallId family members,
/// requested from the SAME container, must be fully independent.
void main() {
  late ProviderContainer container;

  setUp(() {
    container = ProviderContainer();
    addTearDown(container.dispose);
  });

  test(
    'drawControllerProvider(wallA) and drawControllerProvider(wallB) are '
    'independent DrawController instances with independent DrawState: '
    'drawing/committing on A does not affect B, and vice versa',
    () {
      final notifierA = container.read(drawControllerProvider('wall-A').notifier);
      final notifierB = container.read(drawControllerProvider('wall-B').notifier);

      expect(
        identical(notifierA, notifierB),
        isFalse,
        reason: 'each wallId must resolve to its own DrawController',
      );

      notifierA.addPoint(const Offset(0.1, 0.1));
      notifierA.addPoint(const Offset(0.2, 0.2));
      notifierA.commitRoute();

      final stateA = container.read(drawControllerProvider('wall-A'));
      final stateB = container.read(drawControllerProvider('wall-B'));

      expect(
        stateA.routes,
        hasLength(1),
        reason: "wall A's own committed route",
      );
      expect(
        stateB.routes,
        isEmpty,
        reason:
            "wall B's DrawState must be untouched by wall A's commit -- "
            'this is exactly the multi-instance state bleed FIX #6 closes',
      );

      // And the reverse: mutating B never reaches back into A.
      notifierB.toggleMode();
      expect(container.read(drawControllerProvider('wall-B')).mode, DrawMode.draw);
      expect(
        container.read(drawControllerProvider('wall-A')).mode,
        DrawMode.view,
        reason: "wall A's mode must be unaffected by wall B's toggle",
      );
    },
  );

  test(
    'drawControllerProvider(wallId) is autoDispose: with no more listeners, '
    'a fresh read for the SAME wallId starts over from a clean DrawState '
    '(mirrors "opens in a clean state" behavior, instead of leaking state '
    'across re-opens forever)',
    () async {
      // A `listen` (rather than a bare `read`) keeps the provider alive for
      // as long as the subscription is held -- mirroring a mounted
      // TopoCanvasScreen's `ref.watch`. Cancelling it drops the last
      // listener, which is what actually lets an autoDispose provider tear
      // down.
      final sub = container.listen(drawControllerProvider('wall-A'), (_, _) {});
      final notifierA = container.read(drawControllerProvider('wall-A').notifier);
      notifierA.addPoint(const Offset(0.1, 0.1));
      notifierA.addPoint(const Offset(0.2, 0.2));
      notifierA.commitRoute();
      expect(container.read(drawControllerProvider('wall-A')).routes, hasLength(1));

      sub.close();
      // autoDispose schedules its teardown via a real `Timer(Duration.zero,
      // ...)` (see riverpod's `_DefaultVsync.scheduleDispose`), not a plain
      // microtask -- a bare `Future.value()` await only yields one
      // microtask turn and never lets that Timer fire. `Future.delayed`
      // enqueues onto the real event loop's timer queue, so awaiting it
      // guarantees at least one full loop turn has passed and the disposal
      // Timer has already run before we re-read.
      await Future<void>.delayed(Duration.zero);

      // Re-reading now must recreate the provider fresh from `build()`'s
      // default (empty) DrawState rather than keeping wall A's route.
      final freshState = container.read(drawControllerProvider('wall-A'));
      expect(
        freshState.routes,
        isEmpty,
        reason:
            'autoDispose must reset state once nothing was watching, exactly '
            'like re-opening a topo does today',
      );
    },
  );

  test(
    'legendExpandedProvider(wallA) and legendExpandedProvider(wallB) are '
    'independent booleans: collapsing the legend on A does not collapse it '
    'on B',
    () {
      final notifierA = container.read(legendExpandedProvider('wall-A').notifier);
      final notifierB = container.read(legendExpandedProvider('wall-B').notifier);

      expect(container.read(legendExpandedProvider('wall-A')), isTrue);
      expect(container.read(legendExpandedProvider('wall-B')), isTrue);

      notifierA.toggle();
      expect(
        container.read(legendExpandedProvider('wall-A')),
        isFalse,
        reason: "wall A's legend is now collapsed",
      );
      expect(
        container.read(legendExpandedProvider('wall-B')),
        isTrue,
        reason: "wall B's legend must be unaffected by wall A's toggle",
      );

      notifierB.setForMode(DrawMode.draw);
      expect(
        container.read(legendExpandedProvider('wall-B')),
        isFalse,
        reason: 'draw mode collapses B',
      );
      expect(
        container.read(legendExpandedProvider('wall-A')),
        isFalse,
        reason: "A stays exactly as A's own toggle left it, untouched by B",
      );
    },
  );
}
