import 'package:climbtopo/core/db/app_database.dart';
import 'package:climbtopo/features/account/data/profile_repository.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AppDatabase db;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
  });

  tearDown(() async {
    await db.close();
  });

  const uid = 'user-1';
  var now = 1000;
  int nowMs() => now;

  /// Builds a [ProfileRepository] whose `currentUid` seam returns [uid]
  /// (`null` — the default — meaning signed-out).
  ProfileRepository makeRepo({String? uid}) {
    return ProfileRepository(db, nowMs: nowMs, currentUid: () => uid);
  }

  group('setMyDisplayName', () {
    test('signed out is a safe no-op: no row is created', () async {
      final repo = makeRepo();
      await repo.setMyDisplayName('Alex');

      final rows = await db.select(db.profiles).get();
      expect(rows, isEmpty);
    });

    test(
      'first call inserts a new row keyed by uid, with ownerId == id, '
      'dirty == true, and createdAt == updatedAt == nowMs()',
      () async {
        final repo = makeRepo(uid: uid);
        now = 1000;
        await repo.setMyDisplayName('Alex');

        final row = await (db.select(
          db.profiles,
        )..where((t) => t.id.equals(uid))).getSingle();
        expect(row.id, uid);
        expect(row.ownerId, uid);
        expect(row.displayName, 'Alex');
        expect(row.createdAt, 1000);
        expect(row.updatedAt, 1000);
        expect(row.dirty, isTrue);
      },
    );

    test(
      'a second call updates displayName/updatedAt/dirty but preserves '
      'the original createdAt',
      () async {
        final repo = makeRepo(uid: uid);
        now = 1000;
        await repo.setMyDisplayName('Alex');

        now = 2000;
        await repo.setMyDisplayName('Alexandra');

        final row = await (db.select(
          db.profiles,
        )..where((t) => t.id.equals(uid))).getSingle();
        expect(row.displayName, 'Alexandra');
        expect(
          row.createdAt,
          1000,
          reason: 'createdAt must never be rewritten on update',
        );
        expect(row.updatedAt, 2000);
        expect(row.dirty, isTrue);

        final rows = await db.select(db.profiles).get();
        expect(
          rows,
          hasLength(1),
          reason:
              'a second call upserts the same row, never inserts a second '
              'one',
        );
      },
    );
  });

  group('watchDisplayName', () {
    test('emits null when no row exists yet for the given uid', () async {
      final repo = makeRepo();
      expect(await repo.watchDisplayName('nobody').first, isNull);
    });

    test(
      'emits the current displayName, then the next value after a write '
      '(any uid, not just the signed-in one)',
      () async {
        final repo = makeRepo(uid: uid);
        final emissions = <String?>[];
        final sub = repo.watchDisplayName(uid).listen(emissions.add);

        await repo.setMyDisplayName('Alex');
        await pumpEventQueue();
        await repo.setMyDisplayName('Alexandra');
        await pumpEventQueue();

        await sub.cancel();
        expect(emissions, [null, 'Alex', 'Alexandra']);
      },
    );

    test('emits null once the row is soft-deleted (deletedAt set)', () async {
      final repo = makeRepo(uid: uid);
      await repo.setMyDisplayName('Alex');
      expect(await repo.watchDisplayName(uid).first, 'Alex');

      await (db.update(
        db.profiles,
      )..where((t) => t.id.equals(uid))).write(
        const ProfilesCompanion(deletedAt: Value(9999)),
      );

      expect(await repo.watchDisplayName(uid).first, isNull);
    });
  });
}
