// The admin "delete this ascent" AppBar action on `AscentDetailScreen`
// (`lib/features/community/presentation/ascent_detail_screen.dart`) —
// visible ONLY to a signed-in admin, per `adminContentAction`
// (`lib/features/moderation/domain/admin_delete_policy.dart`). Mirrors
// `comment_row_admin_delete_test.dart`'s coverage of the identical gate on a
// different surface.
//
// Harness is copied VERBATIM from `ascent_detail_screen_test.dart`'s
// `seedSharedAscent`/`_FakeAuthRepository` (real in-memory DB, a real photo
// attach run under `tester.runAsync`, a graded/named Route, and a shared
// ascent logged by a different owner than the signed-in session) rather than
// invented fresh — only the `moderationRemoteProvider` override is added, to
// dial the admin answer per test.

import 'package:masi/app/theme.dart';
import 'package:masi/core/db/app_database.dart';
import 'package:masi/core/db/database_provider.dart';
import 'package:masi/features/account/application/auth_providers.dart';
import 'package:masi/features/account/data/auth_repository.dart';
import 'package:masi/features/community/presentation/ascent_detail_screen.dart';
import 'package:masi/features/library/application/library_providers.dart';
import 'package:masi/features/logbook/data/ascents_repository.dart';
import 'package:masi/features/moderation/application/moderation_providers.dart';
import 'package:masi/features/moderation/data/moderation_remote.dart';
import 'package:masi/features/topo/data/route_repository.dart';
import 'package:masi/features/topo/domain/topo_route.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';

/// Minimal in-memory [AuthRepository] test double: a FIXED signed-in session
/// — copied from `ascent_detail_screen_test.dart`'s identical private
/// `_FakeAuthRepository`, which is private to its own file.
class _FakeAuthRepository implements AuthRepository {
  _FakeAuthRepository(this._session);

  final AuthSessionState _session;

  @override
  AuthSessionState get currentSession => _session;

  @override
  Stream<AuthSessionState> authStateChanges() => Stream.value(_session);

  @override
  Future<void> sendMagicLink(String email) async {}

  @override
  Future<void> signInWithGoogle() async {}

  @override
  Future<void> verifyEmailOtp(String email, String code) async {}

  @override
  Future<void> signOut() async {}
}

/// [ModerationRemote] whose `isAdmin()` answer is dialled in per test.
/// Nothing else here is ever exercised by these tests — only the AppBar
/// action's visibility is under test, not the delete flow itself (that's
/// covered by `admin_delete_service_test.dart` and
/// `comment_row_admin_delete_test.dart`'s tap-flow assertions on the
/// identical gate).
class _FakeModerationRemote implements ModerationRemote {
  _FakeModerationRemote({required this.admin});

  final bool admin;

  @override
  Future<bool> isAdmin() async => admin;

  @override
  Future<List<Map<String, dynamic>>> fetchWallModeration(
    Set<String> wallIds,
  ) async => const [];
  @override
  Future<List<Map<String, dynamic>>> fetchQueue({int limit = 50}) async =>
      const [];
  @override
  Future<String> reviewTopo({
    required String wallId,
    required bool approve,
    String? reason,
  }) async => approve ? 'published' : 'rejected';
  @override
  Future<void> removeTopo({required String wallId, String? reason}) async {}
  @override
  Future<List<Map<String, dynamic>>> fetchAbandoned({
    int inactiveDays = 90,
    int limit = 50,
  }) async => const [];
  @override
  Future<List<String>> publishedPhotoObjects(String wallId) async => const [];
  @override
  Future<Map<String, dynamic>?> deletionRequestFor(String wallId) async => null;
  @override
  Future<String> requestDeletion(String wallId, {String? reason}) async => '';
  @override
  Future<List<Map<String, dynamic>>> fetchDeletionRequests({
    int limit = 50,
  }) async => const [];
  @override
  Future<String> reviewDeletion({
    required String requestId,
    required bool approve,
    String? note,
  }) async => approve ? 'approved' : 'rejected';
  @override
  Future<List<Map<String, dynamic>>> fetchMaterialChanges({
    int limit = 50,
  }) async => const [];
  @override
  Future<void> resolveMaterialChange(String noticeId) async {}
  @override
  Future<int> removePublishedPhotoObjects(List<String> objectPaths) async => 0;
  @override
  Future<int?> requestWithdrawal(String wallId) async => null;
  @override
  Future<String> cancelWithdrawal(String wallId) async => 'published';
  @override
  Future<int?> adminDeleteTopo({required String wallId, String? reason}) async =>
      null;
  @override
  Future<int?> adminRestoreTopo({
    required String wallId,
    String? reason,
  }) async => null;
  @override
  Future<int?> adminDeleteAscent({
    required String ascentId,
    String? reason,
  }) async => null;
  @override
  Future<int?> adminDeleteComment({
    required String commentId,
    String? reason,
  }) async => null;
}

void main() {
  /// Seeds a real in-memory DB with Area -> Sector -> Wall -> Photo
  /// (`'original'`) -> one graded, named Route, then a SHARED ascent logged
  /// against it by a DIFFERENT owner ('uid-alex') than the signed-in test
  /// session ('uid-me') — copied verbatim from
  /// `ascent_detail_screen_test.dart`'s identical helper, with one addition:
  /// [admin] wires `moderationRemoteProvider` so the AppBar action's
  /// visibility can be dialled per test.
  Future<
    ({
      AppDatabase db,
      ProviderContainer container,
      String ascentId,
      String wallId,
    })
  >
  seedSharedAscent(WidgetTester tester, {required bool admin}) async {
    final db = AppDatabase(NativeDatabase.memory());
    final container = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWithValue(db),
        nowMsProvider.overrideWithValue(() => 1000),
        authRepositoryProvider.overrideWithValue(
          _FakeAuthRepository(
            const AuthSessionState.signedIn('me@example.com', uid: 'uid-me'),
          ),
        ),
        moderationRemoteProvider.overrideWithValue(
          _FakeModerationRemote(admin: admin),
        ),
      ],
    );

    final crud = container.read(libraryCrudRepositoryProvider);
    final area = await crud.createArea('Area');
    final sector = await crud.createSector(area.id, 'Sector');
    final wall = await crud.createWall(sector.id, 'Wall');

    // attachPhotoToWall copies a real file (PhotoFiles.importPhoto) — real
    // I/O hangs under flutter_test's fake-async unless run inside
    // `tester.runAsync` (mirrors the source suite's identical guard).
    late String photoId;
    await tester.runAsync(() async {
      photoId = await crud.attachPhotoToWall(
        wall.id,
        XFile('/tmp/ascent-detail-admin-test-photo.jpg'),
        1000,
        2000,
      );
    });

    final routeRepo = RouteRepository(db, nowMs: () => 1000);
    await routeRepo.upsertRoute(
      wall.id,
      photoId,
      const TopoRoute(
        id: 1,
        number: 1,
        points: [Offset(0.1, 0.1), Offset(0.2, 0.2)],
        name: 'Sunny Arete',
        gradeRaw: '7a',
      ),
    );
    final dbIds = await routeRepo.routeDbIdsByNumber(wall.id);

    // Own AscentsRepository instance (not the app-wired provider) so
    // ownerId is stamped as 'uid-alex' regardless of who this container's
    // authRepositoryProvider is signed in as.
    final ascentsRepo = AscentsRepository(
      db,
      nowMs: () => 1000,
      currentUid: () => 'uid-alex',
    );
    final ascent = await ascentsRepo.logAscent(
      routeId: dbIds[1]!,
      wallId: wall.id,
      climbedAt: DateTime.utc(2026, 7, 1),
      style: AscentStyle.redpoint,
      shared: true,
      notes: 'Great send, sunny day.',
      gradeOpinion: 'Soft for 7a',
      authorName: 'Alex',
    );

    await db
        .into(db.profiles)
        .insert(
          ProfilesCompanion.insert(
            id: 'uid-alex',
            createdAt: 1000,
            updatedAt: 1000,
            displayName: const Value('Alex Climber'),
          ),
        );

    return (
      db: db,
      container: container,
      ascentId: ascent.id,
      wallId: wall.id,
    );
  }

  Widget wrap(ProviderContainer container, Widget child) {
    return UncontrolledProviderScope(
      container: container,
      child: MaterialApp(theme: MasiTheme.light, home: child),
    );
  }

  testWidgets('an admin sees the moderator-tools action on an ascent', (
    tester,
  ) async {
    final seeded = await seedSharedAscent(tester, admin: true);
    addTearDown(seeded.db.close);
    addTearDown(seeded.container.dispose);

    await tester.pumpWidget(
      wrap(seeded.container, AscentDetailScreen(ascentId: seeded.ascentId)),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('ascent-detail-admin-more')),
      findsOneWidget,
    );
  });

  testWidgets(
    'SECURITY: a signed-in NON-admin sees no moderator-tools action, even '
    'though the ascent itself still renders normally',
    (tester) async {
      final seeded = await seedSharedAscent(tester, admin: false);
      addTearDown(seeded.db.close);
      addTearDown(seeded.container.dispose);

      await tester.pumpWidget(
        wrap(seeded.container, AscentDetailScreen(ascentId: seeded.ascentId)),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('ascent-detail-admin-more')),
        findsNothing,
      );
      // The screen itself is unaffected by the admin gate.
      expect(find.text('Sunny Arete'), findsOneWidget);
    },
  );
}
