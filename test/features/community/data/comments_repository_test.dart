import 'package:drift/drift.dart' show Value;
import 'package:masi/core/db/app_database.dart';
import 'package:masi/features/community/data/comments_repository.dart';
import 'package:masi/features/library/data/library_crud_repository.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AppDatabase db;
  late CommentsRepository repo;
  late LibraryCrudRepository libraryRepo;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    repo = CommentsRepository(
      db,
      nowMs: () => 1000,
      currentUid: () => 'user-1',
    );
    // Comments.wallId is a foreign key (`REFERENCES walls (id)`) and this
    // AppDatabase enforces `PRAGMA foreign_keys = ON` in beforeOpen, so every
    // comment in these tests needs a real, physically-present Wall row.
    // LibraryCrudRepository is the existing seam for creating that
    // Area->Sector->Wall chain; it isn't the code under test here.
    libraryRepo = LibraryCrudRepository(db, nowMs: () => 1000);
  });

  tearDown(() async {
    await db.close();
  });

  Future<String> seedWall(String name) async {
    final area = await libraryRepo.createArea('Area for $name');
    final sector = await libraryRepo.createSector(area.id, 'Sector for $name');
    final wall = await libraryRepo.createWall(sector.id, name);
    return wall.id;
  }

  /// Seeds a full Wall->Photo->Route->Ascent chain (every table in it is a
  /// Drift FK, and this `AppDatabase` enforces `PRAGMA foreign_keys = ON`)
  /// and returns the Ascent row's id, so ascent-targeted comment tests have
  /// a real row `Comments.ascentId` can point at.
  Future<String> seedAscent(String name) async {
    final wallId = await seedWall(name);
    const now = 1000;
    final photoId = 'photo-for-$name';
    await db
        .into(db.photos)
        .insert(
          PhotosCompanion.insert(
            id: photoId,
            createdAt: now,
            updatedAt: now,
            wallId: wallId,
            localPath: '/tmp/$name.jpg',
            kind: 'original',
            width: 100,
            height: 100,
          ),
        );
    final routeId = 'route-for-$name';
    await db
        .into(db.routes)
        .insert(
          RoutesCompanion.insert(
            id: routeId,
            createdAt: now,
            updatedAt: now,
            wallId: wallId,
            photoId: photoId,
            number: 1,
            colorIndex: 0,
            pointsJson: '[]',
            symbolsJson: '[]',
            sortOrder: 0,
          ),
        );
    final ascentId = 'ascent-for-$name';
    await db
        .into(db.ascents)
        .insert(
          AscentsCompanion.insert(
            id: ascentId,
            createdAt: now,
            updatedAt: now,
            routeId: routeId,
            wallId: wallId,
            climbedAt: now,
            style: 'onsight',
          ),
        );
    return ascentId;
  }

  group('B1a: addComment', () {
    test(
      'persists a row with the given wallId+body+authorName, a non-null id, '
      'and ownerId from the currentUid seam',
      () async {
        final wallId = await seedWall('Wall');

        final comment = await repo.addComment(
          wallId: wallId,
          body: 'Great line!',
          authorName: 'Alex',
        );

        expect(comment.id, isNotNull);
        expect(comment.id, isNotEmpty);
        expect(comment.wallId, wallId);
        expect(comment.body, 'Great line!');
        expect(comment.authorName, 'Alex');
        expect(comment.ownerId, 'user-1');

        final rows = await repo.commentsForWall(wallId);
        expect(rows, hasLength(1));
        expect(rows.single.id, comment.id);
        expect(rows.single.wallId, wallId);
        expect(rows.single.body, 'Great line!');
        expect(rows.single.authorName, 'Alex');
        expect(rows.single.ownerId, 'user-1');
      },
    );

    test('owner-stamps null when the currentUid seam returns null', () async {
      final signedOutRepo = CommentsRepository(db, nowMs: () => 1000);
      final wallId = await seedWall('Wall');

      final comment = await signedOutRepo.addComment(
        wallId: wallId,
        body: 'Nice crimp',
      );

      expect(comment.ownerId, isNull);
      final rows = await signedOutRepo.commentsForWall(wallId);
      expect(rows.single.ownerId, isNull);
    });
  });

  group('B1b: commentsForWall', () {
    test(
      'returns only non-deleted comments for the given wall, chronological '
      'ascending, excluding comments on other walls',
      () async {
        final wallA = await seedWall('Wall A');
        final wallB = await seedWall('Wall B');

        final clock = [1000, 2000, 3000].iterator;
        int nextTime() {
          clock.moveNext();
          return clock.current;
        }

        final tickingRepo = CommentsRepository(
          db,
          nowMs: nextTime,
          currentUid: () => 'user-1',
        );

        final first = await tickingRepo.addComment(
          wallId: wallA,
          body: 'First',
        );
        final second = await tickingRepo.addComment(
          wallId: wallA,
          body: 'Second',
        );
        await tickingRepo.addComment(wallId: wallB, body: 'On wall B');

        final results = await repo.commentsForWall(wallA);

        expect(results.map((c) => c.id).toList(), [first.id, second.id]);
        expect(results.map((c) => c.body).toList(), ['First', 'Second']);
      },
    );

    test('watchCommentsForWall emits updates reactively', () async {
      final wallId = await seedWall('Wall');

      final emissions = <int>[];
      final sub = repo.watchCommentsForWall(wallId).listen((rows) {
        emissions.add(rows.length);
      });

      await Future<void>.delayed(Duration.zero);
      await repo.addComment(wallId: wallId, body: 'Hello');
      await Future<void>.delayed(Duration.zero);

      await sub.cancel();
      expect(emissions.last, 1);
    });
  });

  group('B1c: softDeleteComment', () {
    test(
      'sets deletedAt (row remains physically present) and the comment no '
      'longer appears in commentsForWall',
      () async {
        final wallId = await seedWall('Wall');
        final comment = await repo.addComment(wallId: wallId, body: 'Body');

        await repo.softDeleteComment(comment.id);

        expect(await repo.commentsForWall(wallId), isEmpty);

        final rawRow = await (db.select(
          db.comments,
        )..where((t) => t.id.equals(comment.id))).getSingle();
        expect(rawRow.deletedAt, isNotNull);
        expect(rawRow.dirty, isTrue);
      },
    );
  });

  group('Feature #12: ascent-targeted comments', () {
    test(
      'addAscentComment persists a row with ascentId set, wallId NULL, and '
      'the given body/authorName/ownerId, and it round-trips through '
      'commentsForAscent WITHOUT crashing (the wallId! force-unwrap '
      'regression this feature introduced)',
      () async {
        final ascentId = await seedAscent('Ascent Wall');

        final comment = await repo.addAscentComment(
          ascentId: ascentId,
          body: 'Nice send!',
          authorName: 'Alex',
        );

        expect(comment.id, isNotEmpty);
        expect(comment.ascentId, ascentId);
        expect(comment.wallId, isNull);
        expect(comment.body, 'Nice send!');
        expect(comment.authorName, 'Alex');
        expect(comment.ownerId, 'user-1');

        final rows = await repo.commentsForAscent(ascentId);
        expect(rows, hasLength(1));
        expect(rows.single.id, comment.id);
        expect(rows.single.ascentId, ascentId);
        expect(rows.single.wallId, isNull);

        final rawRow = await (db.select(
          db.comments,
        )..where((t) => t.id.equals(comment.id))).getSingle();
        expect(rawRow.wallId, isNull);
        expect(rawRow.ascentId, ascentId);
      },
    );

    test(
      'commentsForAscent/watchCommentsForAscent are scoped INDEPENDENTLY '
      'of wall comments — a wall comment on an unrelated wall never leaks '
      'into an ascent thread and vice versa',
      () async {
        final ascentId = await seedAscent('Ascent Wall 2');
        final otherWallId = await seedWall('Other Wall');

        await repo.addComment(wallId: otherWallId, body: 'Wall comment');
        expect(await repo.commentsForAscent(ascentId), isEmpty);

        final emissions = <int>[];
        final sub = repo
            .watchCommentsForAscent(ascentId)
            .listen((rows) => emissions.add(rows.length));
        await pumpEventQueue();

        await repo.addAscentComment(ascentId: ascentId, body: 'Ascent one');
        await pumpEventQueue();

        // The ascent thread must not include the earlier wall comment.
        final ascentRows = await repo.commentsForAscent(ascentId);
        expect(ascentRows, hasLength(1));
        expect(ascentRows.single.body, 'Ascent one');

        // And the wall thread is unaffected by the ascent comment.
        final wallRows = await repo.commentsForWall(otherWallId);
        expect(wallRows, hasLength(1));
        expect(wallRows.single.body, 'Wall comment');

        await sub.cancel();
        expect(emissions.last, 1);
      },
    );

    test(
      'softDeleteComment works for an ascent-attached comment: it '
      'disappears from commentsForAscent but the tombstone row remains',
      () async {
        final ascentId = await seedAscent('Ascent Wall 3');
        final comment = await repo.addAscentComment(
          ascentId: ascentId,
          body: 'Body',
        );

        await repo.softDeleteComment(comment.id);

        expect(await repo.commentsForAscent(ascentId), isEmpty);

        final rawRow = await (db.select(
          db.comments,
        )..where((t) => t.id.equals(comment.id))).getSingle();
        expect(rawRow.deletedAt, isNotNull);
        expect(rawRow.dirty, isTrue);
      },
    );
  });

  // Tagging other climbers (@mentions). The uids are the reference — display
  // names are editable, so the `@name` text in the body is only a description
  // of who somebody was that day (see `Comments.mentionedUids`).
  group('mentions', () {
    test(
      'the tagged uids come back as a decoded list, never the raw JSON — the '
      'column shape is a storage detail and no widget should have to parse it',
      () async {
        final wallId = await seedWall('Wall');

        final comment = await repo.addComment(
          wallId: wallId,
          body: 'Nice one @Bogi',
          mentionedUids: const ['uid-bogi'],
        );

        expect(comment.mentionedUids, ['uid-bogi']);
        final rows = await repo.commentsForWall(wallId);
        expect(rows.single.mentionedUids, ['uid-bogi']);
      },
    );

    test(
      'a comment that tags nobody stores NULL, not "[]" — most comments tag '
      'nobody and the column should stay empty',
      () async {
        final wallId = await seedWall('Wall');

        final comment = await repo.addComment(wallId: wallId, body: 'Nice');

        expect(comment.mentionedUids, isEmpty);
        final rawRow = await (db.select(
          db.comments,
        )..where((t) => t.id.equals(comment.id))).getSingle();
        expect(rawRow.mentionedUids, isNull);
      },
    );

    test(
      'blanks and duplicates handed in by a caller are tidied before storage, '
      'so the row and the returned model always agree',
      () async {
        final wallId = await seedWall('Wall');

        final comment = await repo.addComment(
          wallId: wallId,
          body: 'Nice one @Bogi',
          mentionedUids: const ['uid-bogi', '', ' uid-bogi ', 'uid-zsofi'],
        );

        expect(comment.mentionedUids, ['uid-bogi', 'uid-zsofi']);
        final rawRow = await (db.select(
          db.comments,
        )..where((t) => t.id.equals(comment.id))).getSingle();
        expect(rawRow.mentionedUids, '["uid-bogi","uid-zsofi"]');
      },
    );

    test('an ascent comment carries its tags the same way a wall comment does', () async {
      final ascentId = await seedAscent('Ascent Wall 4');

      final comment = await repo.addAscentComment(
        ascentId: ascentId,
        body: 'Well done @Zsofi',
        mentionedUids: const ['uid-zsofi'],
      );

      expect(comment.mentionedUids, ['uid-zsofi']);
      final rows = await repo.commentsForAscent(ascentId);
      expect(rows.single.mentionedUids, ['uid-zsofi']);
    });

    test(
      'a row whose column holds garbage still reads as a comment — a bad value '
      'from an older client or a bad sync must not break a whole thread',
      () async {
        final wallId = await seedWall('Wall');
        await db
            .into(db.comments)
            .insert(
              CommentsCompanion.insert(
                id: 'broken-1',
                createdAt: 1000,
                updatedAt: 1000,
                wallId: Value(wallId),
                body: 'Nice one @Bogi',
                mentionedUids: const Value('{not json'),
              ),
            );

        final rows = await repo.commentsForWall(wallId);
        expect(rows.single.body, 'Nice one @Bogi');
        expect(rows.single.mentionedUids, isEmpty);
      },
    );
  });
}
