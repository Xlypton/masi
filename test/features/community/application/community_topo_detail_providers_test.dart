import 'package:masi/core/db/app_database.dart';
import 'package:masi/core/db/database_provider.dart';
import 'package:masi/features/community/application/community_topo_detail_providers.dart';
import 'package:masi/features/library/application/library_providers.dart';
import 'package:masi/features/topo/data/route_repository.dart';
import 'package:masi/features/topo/domain/topo_route.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';

/// Covers Fix #3 (HIGH/CONFIRMED): `routeEntriesForWallProvider` must
/// resolve each route's real DB id scoped to the SAME photo it read routes
/// from (`PhotoRepository.loadOriginal`'s pick), not unscoped across the
/// whole wall — otherwise, on a multi-photo wall, a route `number` that
/// exists on more than one photo resolves to the WRONG photo's DB row and a
/// logged ascent gets attributed to the wrong route entirely.
void main() {
  late AppDatabase db;

  ProviderContainer makeContainer() {
    final container = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWithValue(db),
        nowMsProvider.overrideWithValue(() => 1000),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
  });

  tearDown(() async {
    await db.close();
  });

  test(
    'on a 2-photo wall where one climb is drawn on both, '
    'routeEntriesForWallProvider resolves the ONE climb id — the ambiguity '
    'this used to have to pick a winner for cannot arise any more',
    () async {
      final container = makeContainer();
      final crud = container.read(libraryCrudRepositoryProvider);

      final area = await crud.createArea('Area');
      final sector = await crud.createSector(area.id, 'Sector');
      final wall = await crud.createWall(sector.id, 'Wall');

      // First-attached photo becomes PRIMARY (`isPrimary: true`) —
      // `loadOriginal`/this provider's `photo` — the second is secondary.
      final primaryPhotoId = await crud.attachPhotoToWall(
        wall.id,
        XFile('/tmp/primary.jpg'),
        1000,
        2000,
      );
      final secondaryPhotoId = await crud.attachPhotoToWall(
        wall.id,
        XFile('/tmp/secondary.jpg'),
        1000,
        2000,
      );

      final routeRepo = RouteRepository(db, nowMs: () => 1000);
      // Drawing `number: 1` on BOTH photos. Before v16 that produced two
      // unrelated routes that happened to share a number, and this test
      // existed to pin down WHICH of them the provider picked — a choice it
      // should never have had to make. Since v16 it is one climb drawn twice
      // (the second call writes a `route_lines` row), so there is one id and
      // nothing to disambiguate.
      await routeRepo.upsertRoute(
        wall.id,
        primaryPhotoId,
        const TopoRoute(id: 1, number: 1, points: [Offset(0.1, 0.1)]),
      );
      await routeRepo.upsertRoute(
        wall.id,
        secondaryPhotoId,
        const TopoRoute(id: 1, number: 1, points: [Offset(0.9, 0.9)]),
      );

      final fromPrimary = await routeRepo.routeDbIdsByNumber(
        wall.id,
        primaryPhotoId,
      );
      final fromSecondary = await routeRepo.routeDbIdsByNumber(
        wall.id,
        secondaryPhotoId,
      );
      // The guarantee that replaced the old disambiguation: whichever photo
      // you ask from, route 1 is the same climb. An ascent logged from the
      // second photo therefore lands on the route the first photo shows.
      expect(fromPrimary[1], isNotNull);
      expect(fromPrimary[1], fromSecondary[1]);

      final entries = await container.read(
        routeEntriesForWallProvider(wall.id).future,
      );

      expect(entries, hasLength(1));
      expect(entries.single.dbId, fromPrimary[1]);
    },
  );
}
