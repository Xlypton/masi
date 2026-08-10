// RouteMetadataSheet: a save-through write is LOCAL, an explicit Save is what
// PUBLISHES.
//
// The defect these tests pin. Save-through (see
// `route_metadata_save_through_test.dart`) writes the metadata form as the
// climber edits it — discrete controls immediately, text fields on a 600ms
// debounce — so dismissing the sheet does not throw away the typing. That part
// is wanted. But the write landed in `RouteRepository.upsertRoute`, which
// unconditionally set `dirty: true`, and `dirty` is precisely the flag the sync
// orchestrator's debounced push scopes on (`sync_orchestrator.dart` listens on
// an UNFILTERED `db.tableUpdates()`, waits 2s, then `pushOwn` selects every
// dirty own row). Net effect with no user action: ~2.6s after a pause, or
// instantly on any grade/style/tag/star tap, a HALF-TYPED route name was on the
// server — and on a published topo, in another climber's next pull. Cancel's
// revert was a further push, able to overwrite a concurrent remote edit.
//
// Save-through exists so the climber's typing is not LOST. It must not mean the
// typing is PUBLISHED. So every save-through write (and Cancel's revert) now
// goes through `markDirty: false`, and only Save marks the row pushable.
//
// Why a real in-memory database here, unlike the other sheet tests: `dirty` is
// a COLUMN. `DrawState` does not carry it, so the contract is only observable
// by reading the row the write actually produced — which also means these tests
// exercise the true `DrawController` -> `RouteRepository` -> drift path rather
// than a stand-in. No image is ever decoded (the sheet is pumped directly, per
// its class-doc testability contract).

import 'package:masi/app/theme.dart';
// `hide Route`: the generated drift row class for the `routes` table is
// named `Route`, which collides with Flutter's own `Route`. Nothing here
// needs to name it (the field helpers below return the columns directly).
import 'package:masi/core/db/app_database.dart' hide Route;
import 'package:masi/core/db/database_provider.dart';
import 'package:masi/core/grades/grade_system.dart';
import 'package:masi/features/account/application/auth_providers.dart';
import 'package:masi/features/topo/application/draw_controller.dart';
import 'package:masi/features/topo/domain/topo_route.dart';
import 'package:masi/features/topo/presentation/route_metadata_sheet.dart';
import 'package:drift/drift.dart' show BooleanExpressionOperators;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _wallId = 'wall-1';
const _photoId = 'photo-1';
const _uid = 'u1';

/// Just past [kRouteMetadataDraftDebounce].
const _pastDebounce = Duration(milliseconds: 700);

void main() {
  late AppDatabase db;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    const now = 1000;
    await db.into(db.areas).insert(
          AreasCompanion.insert(
            id: 'area-1',
            createdAt: now,
            updatedAt: now,
            name: 'Area',
          ),
        );
    await db.into(db.sectors).insert(
          SectorsCompanion.insert(
            id: 'sector-1',
            createdAt: now,
            updatedAt: now,
            areaId: 'area-1',
            name: 'Sector',
            sortOrder: 0,
          ),
        );
    await db.into(db.walls).insert(
          WallsCompanion.insert(
            id: _wallId,
            createdAt: now,
            updatedAt: now,
            sectorId: 'sector-1',
            name: 'Wall',
            sortOrder: 0,
          ),
        );
    await db.into(db.photos).insert(
          PhotosCompanion.insert(
            id: _photoId,
            createdAt: now,
            updatedAt: now,
            wallId: _wallId,
            localPath: 'photos/p.jpg',
            kind: 'original',
            width: 100,
            height: 200,
          ),
        );
  });

  tearDown(() async {
    await db.close();
  });

  ProviderContainer makeContainer() {
    final container = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWithValue(db),
        nowMsProvider.overrideWithValue(() => 2000),
        // So the route rows this test writes are OWNED, and the predicate
        // below is byte-for-byte the one the push uses.
        currentUidProvider.overrideWithValue(() => _uid),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  /// Exactly the WHERE clause `SyncService.hasPendingLocalChanges` and
  /// `PushScope.dirtyOnly` apply to the `routes` table (`sync_service.dart`) —
  /// so this reports the real "this row will be sent to the server" signal,
  /// not merely a column value.
  Future<bool> routeIsPushable() async {
    final row = await (db.select(db.routes)
          ..where((t) => t.ownerId.equals(_uid) & t.dirty.equals(true))
          ..limit(1))
        .getSingleOrNull();
    return row != null;
  }

  Future<String?> routeName() async =>
      (await (db.select(db.routes)..where((t) => t.number.equals(1)))
              .getSingle())
          .name;

  Future<String?> routeStyle() async =>
      (await (db.select(db.routes)..where((t) => t.number.equals(1)))
              .getSingle())
          .style;

  Future<int?> routeStars() async =>
      (await (db.select(db.routes)..where((t) => t.number.equals(1)))
              .getSingle())
          .stars;

  /// Seeds ONE committed route on the wall's photo, binds the controller to
  /// that wall/photo (so write-through is live), and clears `dirty` the way a
  /// confirmed push would — the same idiom `route_repository_test.dart` uses.
  /// Returns the route's in-memory id.
  Future<int> seedSyncedRoute(ProviderContainer container) async {
    container.listen(drawControllerProvider(_wallId), (_, _) {});
    final notifier = container.read(drawControllerProvider(_wallId).notifier);
    await notifier.loadForWall(_wallId, _photoId);
    notifier.addPoint(const Offset(0.1, 0.1));
    notifier.addPoint(const Offset(0.2, 0.2));
    await notifier.commitRoute();
    await db.customStatement('UPDATE routes SET dirty = 0');
    expect(
      await routeIsPushable(),
      isFalse,
      reason: 'baseline: the seeded route is fully synced',
    );
    return container.read(drawControllerProvider(_wallId)).routes.single.id;
  }

  Widget buildSheet({
    required ProviderContainer container,
    required int routeId,
    TopoRoute? initial,
  }) {
    return UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: MasiTheme.light,
        home: Scaffold(
          body: RouteMetadataSheet(
            wallId: _wallId,
            routeId: routeId,
            initial: initial,
          ),
        ),
      ),
    );
  }

  group('save-through writes locally and does NOT queue a push', () {
    testWidgets(
      'assertion 1a: a text field\'s debounced save-through write persists the '
      'value but leaves the row NOT dirty — a half-typed name never reaches '
      'the server',
      (tester) async {
        final container = makeContainer();
        final routeId = await seedSyncedRoute(container);

        await tester.pumpWidget(
          buildSheet(container: container, routeId: routeId),
        );
        await tester.pump();

        await tester.enterText(
          find.byKey(const Key('topo-meta-name')),
          'Half-typed nam',
        );
        await tester.pump(_pastDebounce);
        await tester.pumpAndSettle();

        expect(
          await routeName(),
          'Half-typed nam',
          reason: 'the draft must be persisted — that is what save-through is',
        );
        expect(
          await routeIsPushable(),
          isFalse,
          reason:
              'and it must NOT be queued for the push: an uncommitted draft is '
              'the climber\'s alone until they tap Save',
        );
      },
    );

    testWidgets(
      'assertion 1b: a DISCRETE control (star tap, style chip) writes '
      'immediately and likewise leaves the row NOT dirty',
      (tester) async {
        final container = makeContainer();
        final routeId = await seedSyncedRoute(container);

        await tester.pumpWidget(
          buildSheet(container: container, routeId: routeId),
        );
        await tester.pump();

        await tester.ensureVisible(find.byKey(const Key('topo-meta-stars-2')));
        await tester.tap(find.byKey(const Key('topo-meta-stars-2')));
        await tester.pumpAndSettle();

        expect(
          await routeStars(),
          2,
          reason: 'a discrete control writes with no debounce',
        );
        expect(
          await routeIsPushable(),
          isFalse,
          reason:
              'the instant-write path was the WORST case of the defect: one '
              'tap put the draft on the server with no pause at all',
        );

        await tester.ensureVisible(
          find.byKey(const Key('topo-meta-style-trad')),
        );
        await tester.tap(find.byKey(const Key('topo-meta-style-trad')));
        await tester.pumpAndSettle();

        expect(await routeStyle(), 'trad');
        expect(await routeIsPushable(), isFalse);
      },
    );

    testWidgets(
      'assertion 2: tapping SAVE marks the row dirty, so the committed '
      'metadata does reach the server',
      (tester) async {
        final container = makeContainer();
        final routeId = await seedSyncedRoute(container);

        await tester.pumpWidget(
          buildSheet(container: container, routeId: routeId),
        );
        await tester.pump();

        await tester.enterText(
          find.byKey(const Key('topo-meta-name')),
          'Le Toit',
        );
        await tester.pump(_pastDebounce);
        await tester.pumpAndSettle();
        expect(
          await routeIsPushable(),
          isFalse,
          reason: 'still a draft at this point',
        );

        await tester.ensureVisible(find.byKey(const Key('topo-meta-save')));
        await tester.tap(find.byKey(const Key('topo-meta-save')));
        await tester.pumpAndSettle();

        expect(await routeName(), 'Le Toit');
        expect(
          await routeIsPushable(),
          isTrue,
          reason:
              'Save is the climber saying "this is finished" — without the '
              'dirty flag the edit would only ever reach the cloud on a later '
              'full re-push, which is the bug the flag exists to prevent',
        );
      },
    );

    testWidgets(
      'assertion 3: CANCEL reverts locally and leaves the row NOT dirty — a '
      'revert must not push either (it would overwrite, last-writer-wins, a '
      'genuine remote edit made while the sheet sat open)',
      (tester) async {
        final container = makeContainer();
        final routeId = await seedSyncedRoute(container);
        final notifier = container.read(
          drawControllerProvider(_wallId).notifier,
        );
        await notifier.setRouteMetadata(
          routeId,
          name: 'Original',
          gradeSystem: GradeSystem.french,
          gradeRaw: '6a',
          style: 'sport',
        );
        await db.customStatement('UPDATE routes SET dirty = 0');
        final opened = container
            .read(drawControllerProvider(_wallId))
            .routes
            .single;

        await tester.pumpWidget(
          buildSheet(
            container: container,
            routeId: routeId,
            initial: opened,
          ),
        );
        await tester.pump();

        await tester.enterText(
          find.byKey(const Key('topo-meta-name')),
          'Should Not Survive Cancel',
        );
        await tester.pump(_pastDebounce);
        await tester.pumpAndSettle();
        expect(await routeName(), 'Should Not Survive Cancel');

        await tester.ensureVisible(find.byKey(const Key('topo-meta-cancel')));
        await tester.tap(find.byKey(const Key('topo-meta-cancel')));
        await tester.pumpAndSettle();

        expect(
          await routeName(),
          'Original',
          reason: 'Cancel still means DISCARD, save-through notwithstanding',
        );
        expect(
          await routeIsPushable(),
          isFalse,
          reason:
              'the revert restores values the server already has: pushing it '
              'would be a no-change round trip that can clobber a newer '
              'remote edit',
        );
      },
    );

    testWidgets(
      'assertion 4 (controller level): setRouteMetadata DEFAULTS to marking '
      'the row dirty — every caller that is not the sheet\'s save-through is '
      'unchanged, and the default cannot be silently flipped',
      (tester) async {
        final container = makeContainer();
        final routeId = await seedSyncedRoute(container);

        // No `markDirty` argument at all: the pre-existing call shape.
        await container
            .read(drawControllerProvider(_wallId).notifier)
            .setRouteMetadata(
              routeId,
              name: 'Committed By Some Other Caller',
              gradeSystem: GradeSystem.french,
              gradeRaw: '7a',
            );

        expect(await routeName(), 'Committed By Some Other Caller');
        expect(
          await routeIsPushable(),
          isTrue,
          reason:
              'setRouteMetadata must stay push-marking by default; only the '
              'save-through/revert call sites opt out',
        );
      },
    );

    testWidgets(
      'a save-through write does not CLEAR a dirty flag the row already had: '
      'editing metadata on a freshly-drawn, not-yet-pushed route leaves its '
      'pending push intact (with no outbox — D-4 — `dirty` is the only record '
      'that the commit is owed)',
      (tester) async {
        final container = makeContainer();
        container.listen(drawControllerProvider(_wallId), (_, _) {});
        final notifier = container.read(
          drawControllerProvider(_wallId).notifier,
        );
        await notifier.loadForWall(_wallId, _photoId);
        notifier.addPoint(const Offset(0.1, 0.1));
        notifier.addPoint(const Offset(0.2, 0.2));
        await notifier.commitRoute();
        // Deliberately NOT cleared: the route's own commit is still owed.
        expect(await routeIsPushable(), isTrue);
        final routeId = container
            .read(drawControllerProvider(_wallId))
            .routes
            .single
            .id;

        await tester.pumpWidget(
          buildSheet(container: container, routeId: routeId),
        );
        await tester.pump();
        await tester.enterText(find.byKey(const Key('topo-meta-name')), 'dr');
        await tester.pump(_pastDebounce);
        await tester.pumpAndSettle();

        expect(
          await routeIsPushable(),
          isTrue,
          reason:
              'a local-only write must never LOWER the flag — doing so would '
              'silently drop the drawn route from the next push',
        );
      },
    );
  });
}
