import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:masi/core/db/app_database.dart';
import 'package:masi/core/grades/grade_system.dart';
import 'package:masi/features/import/data/guidebook_import_applier.dart';
import 'package:masi/features/import/domain/guidebook_import.dart';
import 'package:masi/features/topo/data/route_repository.dart';
import 'package:masi/features/topo/domain/topo_route.dart';

/// Exercises the applier against a real in-memory database, because the
/// property that matters most here — that an import cannot overwrite routes
/// the user drew by hand — is a property of `(photoId, number)` upsert
/// behaviour, which a fake repository would not reproduce.
void main() {
  const wallId = 'wall-1';
  const photoId = 'photo-1';

  late AppDatabase db;
  late RouteRepository routes;
  late GuidebookImportApplier applier;
  var clock = 1000;

  /// `Routes` has real foreign keys onto `Photos` and `Walls`, which chain up
  /// through `Sectors` to `Areas`, so the whole spine has to exist before a
  /// route can be written at all.
  Future<void> seedPhoto(String id) async {
    await db.into(db.photos).insert(
          PhotosCompanion.insert(
            id: id,
            createdAt: clock,
            updatedAt: clock,
            wallId: wallId,
            localPath: '/$id.jpg',
            kind: 'original',
            width: 4032,
            height: 3024,
          ),
        );
  }

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    routes = RouteRepository(db, nowMs: () => clock++);
    applier = GuidebookImportApplier(routes);

    await db.into(db.areas).insert(
          AreasCompanion.insert(
            id: 'area-1',
            createdAt: clock,
            updatedAt: clock,
            name: 'Fontainebleau',
          ),
        );
    await db.into(db.sectors).insert(
          SectorsCompanion.insert(
            id: 'sector-1',
            createdAt: clock,
            updatedAt: clock,
            areaId: 'area-1',
            name: 'Cul de Chien',
            sortOrder: 0,
          ),
        );
    await db.into(db.walls).insert(
          WallsCompanion.insert(
            id: wallId,
            createdAt: clock,
            updatedAt: clock,
            sectorId: 'sector-1',
            name: 'The Boulder',
            sortOrder: 0,
          ),
        );
    await seedPhoto(photoId);
    await seedPhoto('photo-2');
  });

  tearDown(() async => db.close());

  GuidebookImport importOf(List<ImportedRoute> list, {GradeSystem? system}) {
    return GuidebookImport(routes: list, gradeSystem: system);
  }

  ImportedRoute route(
    int number, {
    String? name,
    String? gradeRaw,
    List<Offset> points = const [],
    int? stars,
    String? description,
  }) {
    return ImportedRoute(
      number: number,
      name: name ?? 'Route $number',
      gradeRaw: gradeRaw,
      points: points,
      stars: stars,
      description: description,
    );
  }

  const line = [Offset(0.2, 0.9), Offset(0.3, 0.1)];

  group('writing an import onto an empty photo', () {
    test('routes land numbered 1..N in order (assertion 6)', () async {
      final result = await applier.apply(
        import: importOf([route(1, name: 'A'), route(2, name: 'B'), route(3, name: 'C')]),
        wallId: wallId,
        photoId: photoId,
      );

      expect(result.added, 3);
      expect(result.firstNumber, 1);
      expect(result.appended, isFalse);

      final stored = await routes.loadRoutes(wallId, photoId);
      expect(stored.map((r) => r.number), [1, 2, 3]);
      expect(stored.map((r) => r.name), ['A', 'B', 'C']);
    });

    test('metadata round-trips through the database intact', () async {
      await applier.apply(
        import: importOf(
          [
            route(1,
                name: 'Le Toit',
                gradeRaw: '6a+',
                stars: 2,
                description: 'Sit start',
                points: line),
          ],
          system: GradeSystem.french,
        ),
        wallId: wallId,
        photoId: photoId,
        system: GradeSystem.french,
      );

      final stored = (await routes.loadRoutes(wallId, photoId)).single;
      expect(stored.name, 'Le Toit');
      expect(stored.gradeRaw, '6a+');
      expect(stored.gradeSystem, GradeSystem.french);
      expect(stored.gradeSortKey, gradeSortKey(GradeSystem.french, '6a+'));
      expect(stored.stars, 2);
      expect(stored.description, 'Sit start');
      expect(stored.points, line);
      expect(stored.style, 'boulder');
    });

    test('an unplaced route persists with its metadata and no line', () async {
      final result = await applier.apply(
        import: importOf([route(1, name: 'Undrawn', gradeRaw: '7a')],
            system: GradeSystem.french),
        wallId: wallId,
        photoId: photoId,
        system: GradeSystem.french,
      );

      expect(result.placed, 0);
      expect(result.unplaced, 1);

      // The whole point of persisting these: the names and grades must
      // survive a reload before the user has drawn anything.
      final stored = (await routes.loadRoutes(wallId, photoId)).single;
      expect(stored.points, isEmpty);
      expect(stored.name, 'Undrawn');
      expect(stored.gradeRaw, '7a');
    });

    test('placed and unplaced are counted separately', () async {
      final result = await applier.apply(
        import: importOf([
          route(1, points: line),
          route(2),
          route(3, points: line),
        ]),
        wallId: wallId,
        photoId: photoId,
      );

      expect(result.added, 3);
      expect(result.placed, 2);
      expect(result.unplaced, 1);
    });
  });

  group('grades are resolved against the chosen ladder', () {
    test('a grade that does not resolve is stored as no grade', () async {
      await applier.apply(
        import: importOf([route(1, gradeRaw: '7Z+')]),
        wallId: wallId,
        photoId: photoId,
        system: GradeSystem.french,
      );

      final stored = (await routes.loadRoutes(wallId, photoId)).single;
      expect(stored.gradeRaw, isNull);
      expect(stored.gradeSystem, isNull);
      expect(stored.gradeSortKey, isNull);
    });

    test('the sheet\'s chosen system wins over the payload\'s', () async {
      // The model said UIAA; the user corrected it to French in the review
      // sheet. The French reading is what must be written.
      final result = await applier.apply(
        import: importOf([route(1, gradeRaw: '6a+')], system: GradeSystem.uiaa),
        wallId: wallId,
        photoId: photoId,
        system: GradeSystem.french,
      );

      expect(result.graded, 1);
      final stored = (await routes.loadRoutes(wallId, photoId)).single;
      expect(stored.gradeSystem, GradeSystem.french);
      expect(stored.gradeRaw, '6a+');
    });

    test('with no system chosen, no grade is written', () async {
      final result = await applier.apply(
        import: importOf([route(1, gradeRaw: '6a+')]),
        wallId: wallId,
        photoId: photoId,
      );

      expect(result.graded, 0);
      final stored = (await routes.loadRoutes(wallId, photoId)).single;
      expect(stored.gradeRaw, isNull);
      expect(stored.name, isNotNull, reason: 'the rest must still import');
    });
  });

  group('an import never overwrites existing routes (assertion 7)', () {
    Future<void> drawByHand(int number, String name) async {
      await routes.upsertRoute(
        wallId,
        photoId,
        TopoRoute(
          id: number,
          number: number,
          points: const [Offset(0.5, 0.9), Offset(0.5, 0.1)],
          name: name,
        ),
      );
    }

    test('it appends after hand-drawn routes rather than clobbering', () async {
      await drawByHand(1, 'Mine 1');
      await drawByHand(2, 'Mine 2');
      await drawByHand(3, 'Mine 3');

      final result = await applier.apply(
        import: importOf([route(1, name: 'Book A'), route(2, name: 'Book B')]),
        wallId: wallId,
        photoId: photoId,
      );

      expect(result.firstNumber, 4);
      expect(result.appended, isTrue);

      final stored = await routes.loadRoutes(wallId, photoId);
      expect(stored.map((r) => r.name),
          ['Mine 1', 'Mine 2', 'Mine 3', 'Book A', 'Book B']);
    });

    test('the user\'s own geometry is untouched', () async {
      await drawByHand(1, 'Mine');
      final before = (await routes.loadRoutes(wallId, photoId)).single.points;

      await applier.apply(
        import: importOf([route(1, name: 'Book', points: line)]),
        wallId: wallId,
        photoId: photoId,
      );

      final mine = (await routes.loadRoutes(wallId, photoId))
          .firstWhere((r) => r.name == 'Mine');
      expect(mine.points, before);
    });

    test('a second import appends again rather than overwriting the first',
        () async {
      await applier.apply(
        import: importOf([route(1, name: 'First')]),
        wallId: wallId,
        photoId: photoId,
      );
      final second = await applier.apply(
        import: importOf([route(1, name: 'Second')]),
        wallId: wallId,
        photoId: photoId,
      );

      // Deliberately NOT idempotent: a duplicate import is visible and
      // deletable in a few taps, whereas an overwritten route is neither.
      expect(second.firstNumber, 2);
      final stored = await routes.loadRoutes(wallId, photoId);
      expect(stored.map((r) => r.name), ['First', 'Second']);
    });

    test('numbering resumes above the highest number, not the count', () async {
      // A photo whose routes 1 and 2 were deleted, leaving only number 5.
      await drawByHand(5, 'Lonely');

      final result = await applier.apply(
        import: importOf([route(1, name: 'Book')]),
        wallId: wallId,
        photoId: photoId,
      );

      expect(result.firstNumber, 6,
          reason: 'starting at 2 would collide with the surviving route 5');
      final stored = await routes.loadRoutes(wallId, photoId);
      expect(stored.map((r) => r.number), [5, 6]);
    });

    test('colour follows the final number, not the payload position', () async {
      await drawByHand(1, 'Mine');

      await applier.apply(
        import: importOf([route(1, name: 'Book')]),
        wallId: wallId,
        photoId: photoId,
      );

      final book = (await routes.loadRoutes(wallId, photoId))
          .firstWhere((r) => r.name == 'Book');
      expect(book.colorIndex, routeColorIndexFor(2),
          reason: 'restarting the palette would repeat its neighbour');
    });
  });

  group('scoping', () {
    test('an import onto a second photo adds new climbs, never folding into '
        'the ones already on the wall', () async {
      await applier.apply(
        import: importOf([route(1, name: 'On photo 1')]),
        wallId: wallId,
        photoId: photoId,
      );
      await applier.apply(
        import: importOf([route(1, name: 'On photo 2')]),
        wallId: wallId,
        photoId: 'photo-2',
      );

      // Each import produced its own climb, numbered across the wall, and
      // each is drawn only on the photo it was imported onto.
      expect((await routes.loadRoutes(wallId, photoId)).map((r) => r.name),
          ['On photo 1']);
      expect((await routes.loadRoutes(wallId, 'photo-2')).map((r) => r.name),
          ['On photo 2']);
      expect(
        (await routes.routeDbIdsByNumber(wallId)).keys.toList()..sort(),
        [1, 2],
        reason: 'the second import took the next free number on the wall',
      );
    });

    test('climbs on another photo DO shift this import\'s numbering — one '
        'number means one climb across the whole rock', () async {
      await routes.upsertRoute(
        wallId,
        'photo-2',
        const TopoRoute(id: 9, number: 9, points: [], name: 'Elsewhere'),
      );

      final result = await applier.apply(
        import: importOf([route(1, name: 'Here')]),
        wallId: wallId,
        photoId: photoId,
      );

      expect(
        result.firstNumber,
        10,
        reason: 'starting at 1 is safe per photo and wrong per wall: since '
            'v16 a number identifies a climb across every photo of the rock, '
            'so an import must clear the wall maximum, not this photo\'s',
      );
    });
  });
}
