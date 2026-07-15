import 'package:climbtopo/core/db/app_database.dart';
import 'package:climbtopo/features/community/data/comments_repository.dart';
import 'package:climbtopo/features/library/data/library_crud_repository.dart';
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
}
