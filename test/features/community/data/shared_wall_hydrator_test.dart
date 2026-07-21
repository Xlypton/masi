import 'dart:io';

import 'package:climbtopo/core/db/app_database.dart';
import 'package:climbtopo/features/backup/data/backup_repository.dart';
import 'package:climbtopo/features/backup/data/sync_remote.dart';
import 'package:climbtopo/features/community/data/shared_wall_hydrator.dart';
import 'package:climbtopo/features/topo/data/photo_files.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// In-memory [SharedWallRemote] test double: hands back a single canned
/// [SharedWallGraph] for a known wall id (or `null` for any other id, mimicking
/// the real anon RLS behavior where a not-found/not-shared wall is silently
/// invisible) plus a fixed map of `objectPath -> bytes` standing in for the
/// `shared/` Storage prefix — no [SupabaseClient], no network.
///
/// [fetchCallCount] is the seam the "fast no-op path" test asserts on: when
/// [SharedWallHydrator.ensureSharedWallLocal] finds the wall already local,
/// it must never call [fetchSharedWallGraph] at all.
class FakeSharedWallRemote implements SharedWallRemote {
  FakeSharedWallRemote({this.graph, Map<String, List<int>>? photoBytes})
    : photoBytes = photoBytes ?? {};

  SharedWallGraph? graph;
  final Map<String, List<int>> photoBytes;
  int fetchCallCount = 0;

  @override
  Future<SharedWallGraph?> fetchSharedWallGraph(String wallId) async {
    fetchCallCount++;
    final g = graph;
    if (g == null || g.wall['id'] != wallId) return null;
    return g;
  }

  @override
  Future<String?> signedUrlForSharedPhoto(
    String objectPath, {
    int expiresInSeconds = 3600,
  }) async => 'https://fake.signed.url/$objectPath';

  @override
  Future<List<int>?> downloadSharedPhotoAnon(String objectPath) async => photoBytes[objectPath];
}

const _ownerUid = 'owner-u2';
const _wallId = 'wall-shared';
const _sectorId = 'sector-shared';
const _areaId = 'area-shared';
const _photoId = 'photo-shared';
const _routeId = 'route-shared';

/// Builds a [SharedWallGraph] shaped exactly like [SupabaseSharedWallRemote]
/// would produce it — real drift row objects, `.toJson()`'d, so the map
/// shape is guaranteed to match what `db.Wall.fromJson`/etc. actually decode
/// (rather than a hand-rolled map that could silently drift out of sync with
/// the real column set).
SharedWallGraph _buildGraph({
  int updatedAt = 100,
  String? displayName = 'Alex',
  bool includeProfile = true,
}) {
  final area = Area(
    id: _areaId,
    createdAt: 100,
    updatedAt: updatedAt,
    dirty: false,
    ownerId: _ownerUid,
    name: 'Shared Area',
  );
  final sector = Sector(
    id: _sectorId,
    createdAt: 100,
    updatedAt: updatedAt,
    dirty: false,
    ownerId: _ownerUid,
    areaId: _areaId,
    name: 'Shared Sector',
    sortOrder: 0,
  );
  final wall = Wall(
    id: _wallId,
    createdAt: 100,
    updatedAt: updatedAt,
    dirty: false,
    ownerId: _ownerUid,
    sectorId: _sectorId,
    name: 'Shared Wall',
    sortOrder: 0,
    visibility: 'shared',
  );
  final photo = Photo(
    id: _photoId,
    createdAt: 100,
    updatedAt: updatedAt,
    dirty: false,
    ownerId: _ownerUid,
    wallId: _wallId,
    // The ORIGINAL uploader's relative path — only its extension matters to
    // the hydrator (it derives the shared object path from
    // canonicalId + extension, then overwrites this with the freshly
    // downloaded LOCAL path).
    localPath: 'photos/$_photoId.jpg',
    kind: 'original',
    width: 800,
    height: 600,
    sortOrder: 0,
    isPrimary: true,
  );
  final route = Route(
    id: _routeId,
    createdAt: 100,
    updatedAt: updatedAt,
    dirty: false,
    ownerId: _ownerUid,
    wallId: _wallId,
    photoId: _photoId,
    number: 1,
    colorIndex: 0,
    pointsJson: '[]',
    symbolsJson: '[]',
    sortOrder: 0,
    visible: true,
  );
  final profile = includeProfile
      ? Profile(
          id: _ownerUid,
          createdAt: 100,
          updatedAt: updatedAt,
          dirty: false,
          ownerId: _ownerUid,
          displayName: displayName,
        )
      : null;

  return SharedWallGraph(
    wall: wall.toJson(),
    sector: sector.toJson(),
    area: area.toJson(),
    photos: [photo.toJson()],
    routes: [route.toJson()],
    authorProfile: profile?.toJson(),
  );
}

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('shared_wall_hydrator_test_');
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  /// One (db, docsDir, hydrator, remote) bundle — a fresh local device with
  /// its own in-memory Drift DB and its own app-owned photos directory.
  ({AppDatabase db, Directory docsDir, SharedWallHydrator hydrator, FakeSharedWallRemote remote})
  makeBundle({SharedWallGraph? graph, Map<String, List<int>>? photoBytes}) {
    final db = AppDatabase(NativeDatabase.memory());
    final docsDir = Directory(p.join(tmp.path, 'docs_${db.hashCode}'))..createSync();
    final remote = FakeSharedWallRemote(graph: graph, photoBytes: photoBytes);
    final hydrator = SharedWallHydrator(
      db: db,
      backupRepository: BackupRepository(db),
      remote: remote,
      photoFiles: PhotoFiles(docsDir: () async => docsDir),
    );
    return (db: db, docsDir: docsDir, hydrator: hydrator, remote: remote);
  }

  group('ensureSharedWallLocal: empty local DB', () {
    test(
      'inserts area, sector, wall, photo row, route, and author profile — '
      'all readable back via plain Drift selects (the existing detail/canvas '
      'render path reads through the exact same tables)',
      () async {
        final photoBytes = List<int>.filled(16, 42);
        final b = makeBundle(
          graph: _buildGraph(),
          photoBytes: {sharedPhotoPath(_photoId, '.jpg'): photoBytes},
        );
        addTearDown(() => b.db.close());

        // No AuthRepository / session anywhere in this test at all —
        // demonstrates the anon path never needs one (see the dedicated
        // "signed-out" group below for an explicit assertion of this).
        await b.hydrator.ensureSharedWallLocal(_wallId);

        final area = await (b.db.select(
          b.db.areas,
        )..where((t) => t.id.equals(_areaId))).getSingleOrNull();
        expect(area, isNotNull);
        expect(area!.ownerId, _ownerUid);

        final sector = await (b.db.select(
          b.db.sectors,
        )..where((t) => t.id.equals(_sectorId))).getSingleOrNull();
        expect(sector, isNotNull);
        expect(sector!.areaId, _areaId);

        final wall = await (b.db.select(
          b.db.walls,
        )..where((t) => t.id.equals(_wallId))).getSingleOrNull();
        expect(wall, isNotNull);
        expect(wall!.visibility, 'shared');
        expect(wall.ownerId, _ownerUid);

        final photo = await (b.db.select(
          b.db.photos,
        )..where((t) => t.id.equals(_photoId))).getSingleOrNull();
        expect(photo, isNotNull);
        expect(photo!.wallId, _wallId);

        final route = await (b.db.select(
          b.db.routes,
        )..where((t) => t.id.equals(_routeId))).getSingleOrNull();
        expect(route, isNotNull);
        expect(route!.wallId, _wallId);

        final profile = await (b.db.select(
          b.db.profiles,
        )..where((t) => t.id.equals(_ownerUid))).getSingleOrNull();
        expect(profile, isNotNull);
        expect(profile!.displayName, 'Alex');

        expect(b.remote.fetchCallCount, 1);
      },
    );

    test(
      'photo bytes land at the EXACT key the renderer reads: '
      "PhotoFiles.resolvePhotoPathSync's relative-path convention "
      '(<appDocuments>/photos/<id><ext>) — a subsequent local read via '
      "PhotoFiles.readPhotoBytes returns the downloaded bytes, matching "
      "the mock signed-url/download's known payload",
      () async {
        final knownBytes = List<int>.filled(32, 7);
        final b = makeBundle(
          graph: _buildGraph(),
          photoBytes: {sharedPhotoPath(_photoId, '.jpg'): knownBytes},
        );
        addTearDown(() => b.db.close());

        await b.hydrator.ensureSharedWallLocal(_wallId);

        final photo = await (b.db.select(
          b.db.photos,
        )..where((t) => t.id.equals(_photoId))).getSingle();

        // The renderer (`PhotoImage` -> `PlatformPhotoImage` ->
        // `PhotoFiles.resolvePhotoPathSync`) resolves a RELATIVE
        // Photos.localPath by joining it against the current app-documents
        // dir — exactly what PhotoFiles.writePhotoBytes returns and what
        // must be stored here.
        expect(p.isRelative(photo.localPath), isTrue);
        expect(photo.localPath, p.join('photos', '$_photoId.jpg'));

        final absolutePath = p.join(b.docsDir.path, photo.localPath);
        expect(File(absolutePath).existsSync(), isTrue);
        expect(File(absolutePath).readAsBytesSync(), knownBytes);

        // Read back through the SAME PhotoFiles seam the renderer's
        // PhotoImage/photo_image_source.dart goes through, proving the
        // stored key resolves correctly, not just that a file happens to
        // exist on disk.
        final reader = PhotoFiles(docsDir: () async => b.docsDir);
        final reReadBytes = await reader.readPhotoBytes(photo.localPath);
        expect(reReadBytes, knownBytes);
      },
    );
  });

  group('ensureSharedWallLocal: idempotence', () {
    test('calling it twice in a row does not create duplicate rows', () async {
      final b = makeBundle(
        graph: _buildGraph(),
        photoBytes: {sharedPhotoPath(_photoId, '.jpg'): List<int>.filled(8, 1)},
      );
      addTearDown(() => b.db.close());

      await b.hydrator.ensureSharedWallLocal(_wallId);
      await b.hydrator.ensureSharedWallLocal(_wallId);

      expect(await b.db.select(b.db.areas).get(), hasLength(1));
      expect(await b.db.select(b.db.sectors).get(), hasLength(1));
      expect(await b.db.select(b.db.walls).get(), hasLength(1));
      expect(await b.db.select(b.db.photos).get(), hasLength(1));
      expect(await b.db.select(b.db.routes).get(), hasLength(1));
      expect(await b.db.select(b.db.profiles).get(), hasLength(1));

      // The second call took the fast no-op path (wall already local), so
      // only the FIRST call ever reached the remote.
      expect(b.remote.fetchCallCount, 1);
    });
  });

  group('ensureSharedWallLocal: fast no-op path', () {
    test(
      'when the wall already exists locally (e.g. this device is the '
      "owner's own, or a prior sync already pulled it), the remote's "
      'fetchSharedWallGraph is NEVER invoked',
      () async {
        final b = makeBundle(graph: _buildGraph());
        addTearDown(() => b.db.close());

        // Seed just the wall row directly — no need for the full hierarchy
        // to exercise the fast-path check, which only looks at Walls.
        await b.db.into(b.db.areas).insert(
          AreasCompanion.insert(
            id: _areaId,
            createdAt: 100,
            updatedAt: 100,
            name: 'Pre-existing area',
          ),
        );
        await b.db.into(b.db.sectors).insert(
          SectorsCompanion.insert(
            id: _sectorId,
            createdAt: 100,
            updatedAt: 100,
            areaId: _areaId,
            name: 'Pre-existing sector',
            sortOrder: 0,
          ),
        );
        await b.db.into(b.db.walls).insert(
          WallsCompanion.insert(
            id: _wallId,
            createdAt: 100,
            updatedAt: 100,
            sectorId: _sectorId,
            name: 'Already local',
            sortOrder: 0,
          ),
        );

        await b.hydrator.ensureSharedWallLocal(_wallId);

        expect(
          b.remote.fetchCallCount,
          0,
          reason: 'a wall already present locally must short-circuit before '
              'ever calling the remote',
        );

        // The pre-existing row must be untouched (not overwritten by
        // anything, since the remote was never even consulted).
        final wall = await (b.db.select(
          b.db.walls,
        )..where((t) => t.id.equals(_wallId))).getSingle();
        expect(wall.name, 'Already local');
      },
    );
  });

  group('ensureSharedWallLocal: not found / not shared', () {
    test(
      'a null graph (wall not found, or exists but is not shared — anon RLS '
      'makes the two indistinguishable) is a silent no-op: nothing is '
      'written locally and nothing throws',
      () async {
        final b = makeBundle(graph: null);
        addTearDown(() => b.db.close());

        await expectLater(b.hydrator.ensureSharedWallLocal('does-not-exist'), completes);

        expect(await b.db.select(b.db.walls).get(), isEmpty);
        expect(b.remote.fetchCallCount, 1);
      },
    );
  });

  group('ensureSharedWallLocal: runs signed-out (anon), no uid gate', () {
    test(
      'SharedWallHydrator has no AuthRepository/session dependency at all — '
      'constructing and running it end to end never references a signed-in '
      'uid, proving the anon path cannot be accidentally uid-gated',
      () async {
        final b = makeBundle(
          graph: _buildGraph(),
          photoBytes: {sharedPhotoPath(_photoId, '.jpg'): List<int>.filled(4, 3)},
        );
        addTearDown(() => b.db.close());

        // SharedWallHydrator's constructor (see shared_wall_hydrator.dart)
        // takes only db/backupRepository/remote/photoFiles — no auth seam
        // exists to even wire a session into, signed-in or otherwise.
        final result = b.hydrator.ensureSharedWallLocal(_wallId);
        await expectLater(result, completes);

        final wall = await (b.db.select(
          b.db.walls,
        )..where((t) => t.id.equals(_wallId))).getSingleOrNull();
        expect(wall, isNotNull, reason: 'hydration succeeded with no session at all');
      },
    );
  });
}
