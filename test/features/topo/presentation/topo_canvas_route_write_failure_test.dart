// UF-1, last gap: `DrawState.lastWriteFailure` had NO consumer.
//
// `DrawController._writeThrough` already stops the silent corruption — a route
// write that throws is reverted and recorded — but nothing on screen read that
// record. So the climber's line simply VANISHED, with no message: strictly
// better than the old "looks saved, was never written", and still not the
// invariant, which is *if the write failed, the climber is told*.
//
// These tests drive the REAL `TopoCanvasScreen` against a real in-memory
// `AppDatabase` and a `RouteRepository` that can be told to reject its writes,
// and assert the two halves of the wiring:
//   1. the failure reaches the climber as a SnackBar, in the route wording
//      (`this route` / `this change`), and
//   2. `DrawController.clearWriteFailure` is called once it has been shown, so
//      `DrawState` stops carrying a failure the climber has already seen.
//
// Delete the `ref.listen` in `topo_canvas_screen.dart`'s `build` and every
// expectation below fails.
//
// Seeding follows `topo_canvas_log_ascent_test.dart`: a real photo via
// `attachPhotoToWall` (inside `tester.runAsync`, since it copies a real file)
// plus `debugInitialImageSize`, so the canvas never drives a real image-codec
// decode — that hangs under fake-async (see the project CLAUDE.md).
import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';
import 'package:masi/app/theme.dart';
import 'package:masi/core/db/app_database.dart';
import 'package:masi/core/db/database_provider.dart';
import 'package:masi/features/library/application/library_providers.dart';
import 'package:masi/features/topo/application/draw_controller.dart';
import 'package:masi/features/topo/data/route_repository.dart';
import 'package:masi/features/topo/domain/topo_route.dart';
import 'package:masi/features/topo/presentation/topo_canvas_screen.dart';

/// A [RouteRepository] whose writes can be switched to failing mid-test.
/// Mirrors `draw_controller_persist_failure_test.dart`'s identical class
/// (file-private there) so both levels of this fix — the controller's revert
/// and this screen's message — are exercised against the same fake.
class _FlakyRouteRepository extends RouteRepository {
  _FlakyRouteRepository(super.db, {required super.nowMs});

  /// When non-null, every [upsertRoute]/[softDeleteRoute] throws this instead
  /// of touching the database. Null (the default) delegates to the real
  /// implementation, so a test can seed real rows and only THEN start failing.
  Object? writeError;

  /// Awaited inside a failing write before it throws, when non-null — lets a
  /// test mutate [DrawState] DURING the write's `await` gap to reach the
  /// "state moved on, the revert was skipped" branch
  /// ([RouteWriteException.rolledBack] `false`).
  Future<void>? beforeThrow;

  @override
  Future<void> upsertRoute(
    String wallId,
    String photoId,
    TopoRoute route,
  ) async {
    final error = writeError;
    if (error == null) return super.upsertRoute(wallId, photoId, route);
    final gate = beforeThrow;
    if (gate != null) await gate;
    throw error;
  }

  @override
  Future<void> softDeleteRoute(
    String wallId,
    String photoId,
    int number,
  ) async {
    final error = writeError;
    if (error == null) return super.softDeleteRoute(wallId, photoId, number);
    final gate = beforeThrow;
    if (gate != null) await gate;
    throw error;
  }
}

/// Stands in for the browser's out-of-room signal. `classifyPhotoWriteFailure`
/// is deliberately STRING-based (see its doc), so reproducing the marker text
/// is enough to exercise the real classification path on the plain Dart VM —
/// which is what makes the assertions below check the REAL quota copy rather
/// than the generic fallback.
class _QuotaExceededError {
  @override
  String toString() => 'QuotaExceededError: The quota has been exceeded.';
}

void main() {
  /// Seeds Area -> Sector -> Wall -> photo, with [routeRepositoryProvider]
  /// overridden by a [_FlakyRouteRepository] that starts out working (so the
  /// canvas can load normally) and can be told to reject writes afterwards.
  Future<
    ({
      AppDatabase db,
      ProviderContainer container,
      String wallId,
      String photoId,
      _FlakyRouteRepository repo,
    })
  >
  seedWall(WidgetTester tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    final repo = _FlakyRouteRepository(db, nowMs: () => 1000);
    final container = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWithValue(db),
        nowMsProvider.overrideWithValue(() => 1000),
        routeRepositoryProvider.overrideWithValue(repo),
      ],
    );

    final crud = container.read(libraryCrudRepositoryProvider);
    final area = await crud.createArea('Area');
    final sector = await crud.createSector(area.id, 'Sector');
    final wall = await crud.createWall(sector.id, 'Wall');

    late String photoId;
    await tester.runAsync(() async {
      photoId = await crud.attachPhotoToWall(
        wall.id,
        XFile('/tmp/topo-canvas-route-write-failure-test-photo.jpg'),
        1000,
        2000,
      );
    });

    return (
      db: db,
      container: container,
      wallId: wall.id,
      photoId: photoId,
      repo: repo,
    );
  }

  Future<void> pumpCanvas(
    WidgetTester tester,
    ProviderContainer container,
    String wallId,
  ) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: MasiTheme.light,
          home: TopoCanvasScreen(
            wallId: wallId,
            debugInitialImageSize: const Size(1000, 2000),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// Draws a two-point line on the live controller the screen is watching —
  /// the minimum `commitRoute` acts on (see its doc: it no-ops below 2 points).
  void drawLine(DrawController c) {
    c.setMode(DrawMode.draw);
    c.addPoint(const Offset(0.2, 0.2));
    c.addPoint(const Offset(0.4, 0.5));
  }

  testWidgets(
    'UF-1: a route whose commit write is refused is reported to the climber, '
    'in the route wording, and the failure is cleared once shown',
    (tester) async {
      final seeded = await seedWall(tester);
      addTearDown(seeded.db.close);
      addTearDown(seeded.container.dispose);

      await pumpCanvas(tester, seeded.container, seeded.wallId);

      final controller = seeded.container.read(
        drawControllerProvider(seeded.wallId).notifier,
      );
      // Precondition: the canvas really is bound to this wall/photo, so
      // `commitRoute` will attempt a write at all (it no-ops without both).
      expect(
        seeded.container.read(drawControllerProvider(seeded.wallId)).activePhotoId,
        seeded.photoId,
        reason: 'precondition: the canvas must have loaded its photo, or the '
            'commit below never reaches the repository and this test proves '
            'nothing',
      );

      seeded.repo.writeError = _QuotaExceededError();
      drawLine(controller);
      await controller.commitRoute();
      await tester.pump();

      expect(
        find.textContaining('Out of storage space'),
        findsOneWidget,
        reason: 'the route the climber just drew never reached the database. '
            'Without a listener on DrawState.lastWriteFailure the line simply '
            'vanishes off the canvas (DrawController reverted it) with no '
            'explanation at all — which is the whole gap this closes',
      );
      expect(
        find.textContaining('this route was not saved'),
        findsOneWidget,
        reason: "a lost ROUTE must be named as one — RouteWriteException's "
            'commitRoute wording, not the generic "this change" used for a '
            'marker/grade/deletion',
      );

      expect(
        seeded.container.read(drawControllerProvider(seeded.wallId)).lastWriteFailure,
        isNull,
        reason: 'the presenter must call DrawController.clearWriteFailure once '
            'it has shown the message (see that method + '
            'DrawState.lastWriteFailure docs), so DrawState stops carrying a '
            'failure the climber has already been told about',
      );

      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'UF-1: a refused marker/grade write says "this change", not "this route"',
    (tester) async {
      final seeded = await seedWall(tester);
      addTearDown(seeded.db.close);
      addTearDown(seeded.container.dispose);

      await pumpCanvas(tester, seeded.container, seeded.wallId);
      final controller = seeded.container.read(
        drawControllerProvider(seeded.wallId).notifier,
      );

      // A route that IS safely persisted first, so the failure below is the
      // metadata write and nothing else.
      drawLine(controller);
      await controller.commitRoute();
      await tester.pump();
      final routeId = seeded.container
          .read(drawControllerProvider(seeded.wallId))
          .routes
          .single
          .id;

      seeded.repo.writeError = _QuotaExceededError();
      await controller.setRouteMetadata(routeId, name: 'Nose', gradeRaw: '6a');
      await tester.pump();

      expect(find.textContaining('this change was not saved'), findsOneWidget);
      expect(find.textContaining('this route was not saved'), findsNothing);
      expect(
        seeded.container.read(drawControllerProvider(seeded.wallId)).lastWriteFailure,
        isNull,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'UF-1: a SECOND failure is reported too — clearing the first must not '
    'swallow the next lost route',
    (tester) async {
      final seeded = await seedWall(tester);
      addTearDown(seeded.db.close);
      addTearDown(seeded.container.dispose);

      await pumpCanvas(tester, seeded.container, seeded.wallId);
      final controller = seeded.container.read(
        drawControllerProvider(seeded.wallId).notifier,
      );
      seeded.repo.writeError = _QuotaExceededError();

      drawLine(controller);
      await controller.commitRoute();
      await tester.pump();
      expect(find.textContaining('Out of storage space'), findsOneWidget);

      // Dismiss the first message so the second is unambiguously a NEW one
      // rather than the first still sitting on screen.
      ScaffoldMessenger.of(
        tester.element(find.byType(TopoCanvasScreen)),
      ).removeCurrentSnackBar();
      await tester.pumpAndSettle();
      expect(find.textContaining('Out of storage space'), findsNothing);

      drawLine(controller);
      await controller.commitRoute();
      await tester.pump();

      expect(
        find.textContaining('Out of storage space'),
        findsOneWidget,
        reason: 'two identical consecutive failures are two lost routes; the '
            'second must not be deduplicated into silence',
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'UF-1: the climber is told even when the revert was skipped '
    '(rolledBack == false) — that is the case where the canvas is knowingly '
    'ahead of the database, so silence would be worst of all',
    (tester) async {
      final seeded = await seedWall(tester);
      addTearDown(seeded.db.close);
      addTearDown(seeded.container.dispose);

      await pumpCanvas(tester, seeded.container, seeded.wallId);
      final controller = seeded.container.read(
        drawControllerProvider(seeded.wallId).notifier,
      );

      seeded.repo.writeError = _QuotaExceededError();
      final gate = Completer<void>();
      seeded.repo.beforeThrow = gate.future;

      drawLine(controller);
      // The write is parked mid-`await`; the climber starts a new line before
      // it fails, which makes reverting unsafe (it would clobber the newer
      // work) — see DrawController._writeThrough's conditional-revert doc.
      final pending = controller.commitRoute();
      controller.addPoint(const Offset(0.7, 0.7));
      gate.complete();
      await pending;
      await tester.pump();

      expect(
        seeded.container
            .read(drawControllerProvider(seeded.wallId))
            .routes,
        hasLength(1),
        reason: 'precondition: no revert happened, so the canvas is showing a '
            'route the database does not have',
      );
      expect(
        find.textContaining('this route was not saved'),
        findsOneWidget,
        reason: 'the route is still ON SCREEN but was never written — the one '
            'case where the climber cannot possibly notice the loss for '
            'themselves, so it is the LAST case that may be silent',
      );
      expect(
        seeded.container.read(drawControllerProvider(seeded.wallId)).lastWriteFailure,
        isNull,
      );
      expect(tester.takeException(), isNull);
    },
  );
}
