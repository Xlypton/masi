import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:masi/core/db/app_database.dart';
import 'package:masi/core/db/database_provider.dart';
import 'package:masi/core/grades/grade_system.dart';
import 'package:masi/features/topo/application/draw_controller.dart';
import 'package:masi/features/topo/data/photo_write_exception.dart';
import 'package:masi/features/topo/data/route_repository.dart';
import 'package:masi/features/topo/domain/topo_route.dart';

/// UF-1 (silent data loss on a failed route write).
///
/// Every persisting [DrawController] method mutates [DrawState] FIRST and then
/// attempts the repository write. Before this fix, a write that threw was
/// swallowed by a `debugPrint`, so the canvas went on showing a route/symbol/
/// grade that had never reached the database — the climber saw "saved", closed
/// the app, and the work was gone with no warning at any point. On web that is
/// not hypothetical: an exhausted origin quota makes drift/IndexedDB writes
/// reject (see `photo_write_exception.dart`, the same problem on the photo
/// path).
///
/// These tests drive the real [DrawController] against a real in-memory
/// [AppDatabase] with a [_FlakyRouteRepository] that can be told to fail its
/// writes mid-test, and assert the invariant: **what the canvas shows never
/// silently diverges from what is stored.**
class _FlakyRouteRepository extends RouteRepository {
  _FlakyRouteRepository(super.db, {required super.nowMs});

  /// When non-null, every [upsertRoute]/[softDeleteRoute] throws this instead
  /// of touching the database. Null (the default) delegates to the real
  /// implementation, so a test can seed real rows and only THEN start failing.
  Object? writeError;

  /// Awaited inside a failing write before it throws, when non-null — lets a
  /// test run other controller methods DURING the write's `await` gap to
  /// exercise the "state moved on, rollback is no longer safe" branch.
  Future<void>? beforeThrow;

  int upsertAttempts = 0;
  int softDeleteAttempts = 0;

  @override
  Future<void> upsertRoute(
    String wallId,
    String photoId,
    TopoRoute route, {
    bool markDirty = true,
  }) async {
    upsertAttempts++;
    final error = writeError;
    if (error == null) {
      return super.upsertRoute(wallId, photoId, route, markDirty: markDirty);
    }
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
    softDeleteAttempts++;
    final error = writeError;
    if (error == null) return super.softDeleteRoute(wallId, photoId, number);
    final gate = beforeThrow;
    if (gate != null) await gate;
    throw error;
  }
}

/// Stands in for the browser's out-of-room signal. `classifyPhotoWriteFailure`
/// is deliberately STRING-based (see its doc), so reproducing the marker text
/// is enough to exercise the real classification path on the plain Dart VM.
class _QuotaExceededError {
  @override
  String toString() => 'QuotaExceededError: The quota has been exceeded.';
}

void main() {
  const wallId = 'wall-1';
  const photoId = 'photo-1';
  const otherPhotoId = 'photo-2';
  const now = 1000;

  late AppDatabase db;
  late _FlakyRouteRepository repo;
  late ProviderContainer container;

  Future<void> seedHierarchy() async {
    await db
        .into(db.areas)
        .insert(
          AreasCompanion.insert(
            id: 'area-1',
            createdAt: now,
            updatedAt: now,
            name: 'Test Area',
          ),
        );
    await db
        .into(db.sectors)
        .insert(
          SectorsCompanion.insert(
            id: 'sector-1',
            createdAt: now,
            updatedAt: now,
            areaId: 'area-1',
            name: 'Test Sector',
            sortOrder: 0,
          ),
        );
    await db
        .into(db.walls)
        .insert(
          WallsCompanion.insert(
            id: wallId,
            createdAt: now,
            updatedAt: now,
            sectorId: 'sector-1',
            name: 'Test Wall',
            sortOrder: 0,
          ),
        );
    for (final id in const [photoId, otherPhotoId]) {
      await db
          .into(db.photos)
          .insert(
            PhotosCompanion.insert(
              id: id,
              createdAt: now,
              updatedAt: now,
              wallId: wallId,
              localPath: '/tmp/$id.jpg',
              kind: 'original',
              width: 100,
              height: 200,
            ),
          );
    }
  }

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    await seedHierarchy();
    repo = _FlakyRouteRepository(db, nowMs: () => now);
    container = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWithValue(db),
        nowMsProvider.overrideWithValue(() => now),
        routeRepositoryProvider.overrideWithValue(repo),
      ],
    );
    // LIFO: the container is disposed first, then the database it read from.
    addTearDown(db.close);
    addTearDown(container.dispose);
  });

  DrawController controllerFor() =>
      container.read(drawControllerProvider(wallId).notifier);
  DrawState stateFor() => container.read(drawControllerProvider(wallId));

  /// Reads what is ACTUALLY on disk, bypassing the flaky double entirely.
  Future<List<TopoRoute>> persistedRoutes([String photo = photoId]) =>
      RouteRepository(db, nowMs: () => now).loadRoutes(wallId, photo);

  /// Draws a two-point line into the in-progress draft.
  void drawTwoPointDraft(DrawController c) {
    c.setMode(DrawMode.draw);
    c.addPoint(const Offset(0.1, 0.1));
    c.addPoint(const Offset(0.2, 0.2));
  }

  /// Commits one route for real (repository healthy) and returns the loaded
  /// controller, so a test can then start failing writes against it.
  Future<DrawController> loadedWithOneRoute() async {
    final c = controllerFor();
    await c.loadForWall(wallId, photoId);
    drawTwoPointDraft(c);
    await c.commitRoute();
    expect(await persistedRoutes(), hasLength(1));
    return c;
  }

  group('UF-1: a failed route write must never read as saved', () {
    test('commitRoute — the drawn line does not survive on screen unstored',
        () async {
      final c = controllerFor();
      await c.loadForWall(wallId, photoId);
      drawTwoPointDraft(c);

      repo.writeError = _QuotaExceededError();
      await c.commitRoute();

      expect(
        await persistedRoutes(),
        isEmpty,
        reason: 'precondition: the write really did fail',
      );
      expect(
        stateFor().routes,
        isEmpty,
        reason: 'the canvas must not show a route the database never got',
      );
      expect(
        stateFor().currentPoints,
        const [Offset(0.1, 0.1), Offset(0.2, 0.2)],
        reason: 'the climber gets their unsaved line back as a live draft',
      );
    });

    test('removeRoute — a delete that never landed does not vanish from screen',
        () async {
      final c = await loadedWithOneRoute();

      repo.writeError = _QuotaExceededError();
      await c.removeRoute(1);

      expect(
        await persistedRoutes(),
        hasLength(1),
        reason: 'precondition: the soft-delete really did fail',
      );
      expect(
        stateFor().routes.map((r) => r.number),
        const [1],
        reason: 'a route still in the database must still be on the canvas',
      );
    });

    test('placeSymbol — an unstored marker is not left on the route', () async {
      final c = await loadedWithOneRoute();
      c.selectRoute(1);
      c.setActiveSymbol(SymbolType.crux);

      repo.writeError = _QuotaExceededError();
      await c.placeSymbol(const Offset(0.5, 0.5));

      expect((await persistedRoutes()).single.symbols, isEmpty);
      expect(
        stateFor().routes.single.symbols,
        isEmpty,
        reason: 'the crux marker never reached the database',
      );
    });

    test('setRouteMetadata — unstored name/grade edits are not left on screen',
        () async {
      final c = await loadedWithOneRoute();

      repo.writeError = _QuotaExceededError();
      await c.setRouteMetadata(
        1,
        name: 'Crimpy traverse',
        gradeSystem: GradeSystem.french,
        gradeRaw: '7a+',
      );

      expect((await persistedRoutes()).single.name, isNull);
      expect(
        stateFor().routes.single.name,
        isNull,
        reason: 'the metadata sheet reported a save that never happened',
      );
      expect(stateFor().routes.single.gradeRaw, isNull);
    });

    test('undo — a symbol removal that never landed stays on screen', () async {
      final c = await loadedWithOneRoute();
      c.selectRoute(1);
      c.setActiveSymbol(SymbolType.bolt);
      await c.placeSymbol(const Offset(0.5, 0.5));
      expect((await persistedRoutes()).single.symbols, hasLength(1));

      repo.writeError = _QuotaExceededError();
      await c.undo();

      expect((await persistedRoutes()).single.symbols, hasLength(1));
      expect(
        stateFor().routes.single.symbols,
        hasLength(1),
        reason: 'the bolt is still in the database, so it is still on the wall',
      );
      expect(
        stateFor().undoStack, hasLength(1),
        reason: 'the op was not consumed — undo did not actually happen',
      );
      expect(stateFor().redoStack, isEmpty);
    });

    test('redo — a symbol re-add that never landed does not appear', () async {
      final c = await loadedWithOneRoute();
      c.selectRoute(1);
      c.setActiveSymbol(SymbolType.anchor);
      await c.placeSymbol(const Offset(0.5, 0.5));
      await c.undo();
      expect((await persistedRoutes()).single.symbols, isEmpty);

      repo.writeError = _QuotaExceededError();
      await c.redo();

      expect((await persistedRoutes()).single.symbols, isEmpty);
      expect(
        stateFor().routes.single.symbols,
        isEmpty,
        reason: 'the anchor never got back into the database',
      );
      expect(stateFor().redoStack, hasLength(1));
      expect(stateFor().undoStack, isEmpty);
    });

    test(
      'loadForWall — a route committed mid-photo-switch that cannot be '
      'persisted is not silently kept',
      () async {
        final c = controllerFor();
        await c.loadForWall(wallId, photoId);

        // Switch photos, and commit a route while the switch is still open —
        // activeWallId is null, so this route lives ONLY in memory and
        // loadForWall's preserved-routes loop is its one chance to reach disk.
        c.beginPhotoSwitch();
        drawTwoPointDraft(c);
        await c.commitRoute();
        expect(stateFor().routes, hasLength(1));

        repo.writeError = _QuotaExceededError();
        await c.loadForWall(wallId, otherPhotoId);

        expect(
          await persistedRoutes(otherPhotoId),
          isEmpty,
          reason: 'precondition: the preserving write really did fail',
        );
        expect(
          stateFor().routes,
          isEmpty,
          reason:
              'the mid-switch route reached no database and must not read as '
              'saved',
        );
      },
    );
  });

  group('UF-1: the climber is told, in the photo path\'s words', () {
    test('a quota failure names the route and how to fix it', () async {
      final c = controllerFor();
      await c.loadForWall(wallId, photoId);
      drawTwoPointDraft(c);

      repo.writeError = _QuotaExceededError();
      await c.commitRoute();

      final failure = stateFor().lastWriteFailure;
      expect(failure, isNotNull);
      expect(failure!.operation, RouteWriteOperation.commitRoute);
      expect(failure.failure, PhotoWriteFailure.quotaExceeded);
      expect(failure.rolledBack, isTrue);
      expect(
        failure.userMessage,
        'Out of storage space — this route was not saved. Free up space on '
        'this device and try again.',
      );
    });

    test('an unclassifiable failure still gets a plain, actionable sentence',
        () async {
      final c = controllerFor();
      await c.loadForWall(wallId, photoId);
      drawTwoPointDraft(c);

      repo.writeError = StateError('database is closed');
      await c.commitRoute();

      final failure = stateFor().lastWriteFailure!;
      expect(failure.failure, PhotoWriteFailure.unknown);
      expect(
        failure.userMessage,
        'This route could not be saved on this device. Please try again.',
      );
      expect(
        failure.toString(),
        contains('database is closed'),
        reason: 'the cause belongs in the log, never in userMessage',
      );
      expect(failure.userMessage, isNot(contains('database is closed')));
    });

    test('a smaller edit says "this change", not "this route"', () async {
      final c = await loadedWithOneRoute();

      repo.writeError = _QuotaExceededError();
      await c.setRouteMetadata(1, name: 'Crimpy traverse');

      final failure = stateFor().lastWriteFailure!;
      expect(failure.operation, RouteWriteOperation.setRouteMetadata);
      expect(failure.userMessage, contains('this change was not saved'));
    });

    test('a write that succeeds reports nothing', () async {
      await loadedWithOneRoute();
      expect(stateFor().lastWriteFailure, isNull);
    });

    test('clearWriteFailure lets the next failure be seen as a new one',
        () async {
      final c = await loadedWithOneRoute();
      repo.writeError = _QuotaExceededError();

      await c.setRouteMetadata(1, name: 'first');
      final first = stateFor().lastWriteFailure;
      expect(first, isNotNull);

      c.clearWriteFailure();
      expect(stateFor().lastWriteFailure, isNull);

      // Clearing again must not churn state (a presenter may call it
      // defensively on every rebuild).
      final settled = stateFor();
      c.clearWriteFailure();
      expect(identical(stateFor(), settled), isTrue);

      await c.setRouteMetadata(1, name: 'second');
      expect(stateFor().lastWriteFailure, isNotNull);
      expect(
        identical(stateFor().lastWriteFailure, first),
        isFalse,
        reason: 'each failure is a distinct instance, so a listener refires',
      );
    });

    test(
      'two identical consecutive failures are two distinct instances',
      () async {
        final c = await loadedWithOneRoute();
        repo.writeError = _QuotaExceededError();

        await c.setRouteMetadata(1, name: 'a');
        final first = stateFor().lastWriteFailure;
        await c.setRouteMetadata(1, name: 'b');
        final second = stateFor().lastWriteFailure;

        expect(
          identical(first, second),
          isFalse,
          reason: 'a second lost edit must not be deduplicated into silence',
        );
      },
    );
  });

  group('UF-1: the revert is conditional', () {
    test(
      'state that moved on during the failed write is left alone, and the '
      'failure says so',
      () async {
        final c = controllerFor();
        await c.loadForWall(wallId, photoId);
        drawTwoPointDraft(c);

        final gate = Completer<void>();
        repo.writeError = _QuotaExceededError();
        repo.beforeThrow = gate.future;

        // The write is now parked mid-`await`; the climber starts a new line
        // before it fails.
        final pending = c.commitRoute();
        c.addPoint(const Offset(0.7, 0.7));
        gate.complete();
        await pending;

        final state = stateFor();
        expect(
          state.currentPoints,
          const [Offset(0.7, 0.7)],
          reason: 'reverting would have destroyed the newer, unrelated line',
        );
        expect(state.routes, hasLength(1), reason: 'no revert happened');
        expect(state.lastWriteFailure, isNotNull);
        expect(
          state.lastWriteFailure!.rolledBack,
          isFalse,
          reason: 'the canvas is knowingly ahead of the database here',
        );
      },
    );

    test(
      'a canvas closed during the failed write does not blow up on the way '
      'out',
      () async {
        final c = controllerFor();
        await c.loadForWall(wallId, photoId);
        drawTwoPointDraft(c);

        final gate = Completer<void>();
        repo.writeError = _QuotaExceededError();
        repo.beforeThrow = gate.future;

        // The revert/report happens AFTER the write's await, which is a state
        // write that did not exist before this fix -- so popping the screen
        // mid-write must not turn a storage failure into a crash. The
        // controller is autoDispose, so this is an ordinary navigation.
        final pending = c.commitRoute();
        container.dispose();
        gate.complete();

        await expectLater(pending, completes);
      },
    );
  });

  group('UF-1 exception: toggleRouteVisibility stays log-and-carry-on', () {
    test(
      'a failed visibility write neither reverts nor warns — it destroys no '
      'authored content and must not be made to shout',
      () async {
        final c = await loadedWithOneRoute();
        expect(stateFor().routes.single.visible, isTrue);

        repo.writeError = _QuotaExceededError();
        await c.toggleRouteVisibility(1);

        expect(
          repo.upsertAttempts,
          greaterThan(1),
          reason: 'precondition: the visibility write really was attempted',
        );
        expect(
          (await persistedRoutes()).single.visible,
          isTrue,
          reason: 'precondition: it really did fail',
        );
        expect(
          stateFor().routes.single.visible,
          isFalse,
          reason:
              'deliberate: the climber can still hide routes to read their '
              'own topo while storage is full',
        );
        expect(
          stateFor().lastWriteFailure,
          isNull,
          reason:
              'deliberate: a one-tap display toggle must not train the '
              'climber to dismiss the warning that matters',
        );
      },
    );
  });
}
