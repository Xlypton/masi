import 'package:masi/core/db/app_database.dart';
import 'package:masi/features/account/data/profile_repository.dart';
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

  group('adoptProviderAvatarUrl', () {
    /// The picture is what OTHER people see. The provider avatar lives on the
    /// auth session and a session is readable only by its own user, so
    /// without this step a user who never opened Account and picked a photo
    /// appeared to the whole community as their initials.
    const google = 'https://lh3.googleusercontent.com/a/abc123';

    test('signed out is a safe no-op: no row is created', () async {
      final repo = makeRepo();
      await repo.adoptProviderAvatarUrl(google);

      expect(await db.select(db.profiles).get(), isEmpty);
    });

    test('a null or blank provider URL writes nothing', () async {
      final repo = makeRepo(uid: uid);
      await repo.adoptProviderAvatarUrl(null);
      await repo.adoptProviderAvatarUrl('');
      await repo.adoptProviderAvatarUrl('   ');

      expect(await db.select(db.profiles).get(), isEmpty);
    });

    test(
      'a non-http value is refused — only an identity provider hands out a '
      'URL here, and anything else reaching this method is a bug, not a '
      'picture',
      () async {
        final repo = makeRepo(uid: uid);
        await repo.adoptProviderAvatarUrl('data:image/jpeg;base64,AAAA');
        await repo.adoptProviderAvatarUrl('/local/path.jpg');

        expect(await db.select(db.profiles).get(), isEmpty);
      },
    );

    test('adopts into a profile that has no picture yet', () async {
      final repo = makeRepo(uid: uid);
      await repo.adoptProviderAvatarUrl(google);

      final row = await (db.select(
        db.profiles,
      )..where((t) => t.id.equals(uid))).getSingle();
      expect(row.avatarUrl, google);
      // Marked dirty so the sync push carries it to the cloud — the whole
      // point is that other devices and other people can read it.
      expect(row.dirty, isTrue);
    });

    test(
      'NEVER overwrites a picture the user picked in-app: those are always '
      'data: URLs (avatar_picker base64-encodes the bytes), and an explicit '
      'choice must not be undone by whatever Google happens to hold',
      () async {
        final repo = makeRepo(uid: uid);
        await repo.setMyAvatarUrl('data:image/jpeg;base64,MINE');
        await repo.adoptProviderAvatarUrl(google);

        final row = await (db.select(
          db.profiles,
        )..where((t) => t.id.equals(uid))).getSingle();
        expect(row.avatarUrl, 'data:image/jpeg;base64,MINE');
      },
    );

    test(
      'refreshes a previously-adopted http URL when the provider rotates it '
      '— a stale lh3.googleusercontent.com link 404s, which MasiAvatar draws '
      'as the initials',
      () async {
        final repo = makeRepo(uid: uid);
        await repo.adoptProviderAvatarUrl(google);
        now = 2000;
        await repo.adoptProviderAvatarUrl('$google-rotated');

        final row = await (db.select(
          db.profiles,
        )..where((t) => t.id.equals(uid))).getSingle();
        expect(row.avatarUrl, '$google-rotated');
        expect(row.updatedAt, 2000);
      },
    );

    test('re-adopting the SAME URL does not touch the row', () async {
      final repo = makeRepo(uid: uid);
      await repo.adoptProviderAvatarUrl(google);
      final before = await (db.select(
        db.profiles,
      )..where((t) => t.id.equals(uid))).getSingle();

      now = 5000;
      await repo.adoptProviderAvatarUrl(google);

      final after = await (db.select(
        db.profiles,
      )..where((t) => t.id.equals(uid))).getSingle();
      // Not merely "the URL is unchanged" — `updatedAt` must not move either,
      // or every sign-in would dirty the row and push a no-op change.
      expect(after.updatedAt, before.updatedAt);
    });
  });
}
