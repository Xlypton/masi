import 'package:masi/app/theme.dart';
import 'package:masi/core/db/app_database.dart';
import 'package:masi/core/db/database_provider.dart';
import 'package:masi/features/account/application/auth_providers.dart';
import 'package:masi/features/account/data/auth_repository.dart';
import 'package:masi/features/community/application/comments_providers.dart';
import 'package:masi/features/community/presentation/ascent_detail_screen.dart';
import 'package:masi/features/library/application/library_providers.dart';
import 'package:masi/features/logbook/data/ascents_repository.dart';
import 'package:masi/features/topo/data/route_repository.dart';
import 'package:masi/features/topo/domain/topo_route.dart';
import 'package:masi/shared/presentation/masi_icon.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';

/// Minimal in-memory [AuthRepository] test double: a FIXED signed-in
/// session (no live emit tracking needed by this suite) — trimmed from
/// `community_topo_detail_test.dart`'s identical private
/// `_FakeAuthRepository`, which this suite doesn't import directly since
/// that class is private to its own file.
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

void main() {
  /// Seeds a real in-memory DB with Area -> Sector -> Wall -> Photo
  /// (`'original'`) -> one graded, named Route, then a SHARED ascent logged
  /// against it by a DIFFERENT owner ('uid-alex') than the signed-in test
  /// session ('uid-me') — proving `profileDisplayNameProvider` resolution
  /// is independent of whoever is currently signed in, mirroring how
  /// `community_screen_test.dart`'s `_FeedRow` name-resolution tests are
  /// structured. Also seeds a `profiles` row for 'uid-alex' so its display
  /// name resolves instead of falling back to "Unknown climber".
  Future<
    ({
      AppDatabase db,
      ProviderContainer container,
      String ascentId,
      String wallId,
    })
  >
  seedSharedAscent(WidgetTester tester) async {
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
      ],
    );

    final crud = container.read(libraryCrudRepositoryProvider);
    final area = await crud.createArea('Area');
    final sector = await crud.createSector(area.id, 'Sector');
    final wall = await crud.createWall(sector.id, 'Wall');

    // attachPhotoToWall copies a real file (PhotoFiles.importPhoto) — real
    // I/O hangs under flutter_test's fake-async unless run inside
    // `tester.runAsync` (mirrors community_topo_detail_test.dart's identical
    // guard).
    late String photoId;
    await tester.runAsync(() async {
      photoId = await crud.attachPhotoToWall(
        wall.id,
        XFile('/tmp/ascent-detail-test-photo.jpg'),
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

  testWidgets(
    'renders the resolved climber name, route/grade, wall, and notes',
    (tester) async {
      final seeded = await seedSharedAscent(tester);
      addTearDown(seeded.db.close);
      addTearDown(seeded.container.dispose);

      await tester.pumpWidget(
        wrap(
          seeded.container,
          AscentDetailScreen(ascentId: seeded.ascentId),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(Key('ascent-detail-${seeded.ascentId}')), findsOneWidget);
      expect(find.text('Alex Climber'), findsOneWidget);
      expect(find.text('Sunny Arete'), findsOneWidget);
      expect(find.text('7a'), findsOneWidget);
      expect(find.text('Wall'), findsOneWidget);
      expect(find.textContaining('Redpoint'), findsOneWidget);
      expect(find.text('Great send, sunny day.'), findsOneWidget);
      expect(find.textContaining('Soft for 7a'), findsOneWidget);
    },
  );

  testWidgets('the not-found state renders for an unknown ascentId', (
    tester,
  ) async {
    final seeded = await seedSharedAscent(tester);
    addTearDown(seeded.db.close);
    addTearDown(seeded.container.dispose);

    await tester.pumpWidget(
      wrap(
        seeded.container,
        const AscentDetailScreen(ascentId: 'does-not-exist'),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('ascent-detail-not-found')),
      findsOneWidget,
    );
    expect(find.text('Alex Climber'), findsNothing);
  });

  testWidgets('tapping the like button toggles state and updates the count', (
    tester,
  ) async {
    final seeded = await seedSharedAscent(tester);
    addTearDown(seeded.db.close);
    addTearDown(seeded.container.dispose);

    await tester.pumpWidget(
      wrap(seeded.container, AscentDetailScreen(ascentId: seeded.ascentId)),
    );
    await tester.pumpAndSettle();

    String likeCountText() => tester
        .widget<Text>(find.byKey(const Key('ascent-detail-like-count')))
        .data!;

    Finder heartIcon(String name) => find.byWidgetPredicate(
      (widget) => widget is MasiIcon && widget.name == name,
    );

    expect(likeCountText(), '0');
    expect(heartIcon('heart'), findsOneWidget);
    expect(heartIcon('heart_fill'), findsNothing);

    await tester.tap(find.byKey(const Key('ascent-detail-like-button')));
    await tester.pumpAndSettle();

    expect(likeCountText(), '1');
    expect(heartIcon('heart_fill'), findsOneWidget);
    expect(heartIcon('heart'), findsNothing);

    await tester.tap(find.byKey(const Key('ascent-detail-like-button')));
    await tester.pumpAndSettle();

    expect(likeCountText(), '0');
    expect(heartIcon('heart'), findsOneWidget);
    expect(heartIcon('heart_fill'), findsNothing);
  });

  testWidgets(
    'submitting a comment appends an ascent-detail-comment-<id> row and '
    'clears the empty state',
    (tester) async {
      final seeded = await seedSharedAscent(tester);
      addTearDown(seeded.db.close);
      addTearDown(seeded.container.dispose);

      await tester.pumpWidget(
        wrap(
          seeded.container,
          AscentDetailScreen(ascentId: seeded.ascentId),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('ascent-detail-comments-empty')),
        findsOneWidget,
      );

      await tester.enterText(
        find.byKey(const Key('ascent-detail-comment-field')),
        'Nice send!',
      );
      // The submit IconButton is disabled/enabled off a
      // ValueListenableBuilder watching the controller directly — enterText
      // fires that listener synchronously but the rebuilt (now-enabled)
      // IconButton instance isn't in the element tree until a frame is
      // pumped (mirrors community_topo_detail_test.dart's identical
      // comment).
      await tester.pump();
      await tester.tap(find.byKey(const Key('ascent-detail-comment-submit')));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('ascent-detail-comments-empty')),
        findsNothing,
      );

      final commentsRepo = seeded.container.read(commentsRepositoryProvider);
      final comments = await commentsRepo.commentsForAscent(seeded.ascentId);
      expect(comments, hasLength(1));
      expect(comments.single.body, 'Nice send!');
      // Derived from the signed-in fake session's profile
      // (myDisplayNameProvider) — no profile row was seeded for 'uid-me',
      // so this resolves to null (no author name) rather than a stale
      // fallback.
      expect(
        find.byKey(Key('ascent-detail-comment-${comments.single.id}')),
        findsOneWidget,
      );
      expect(find.text('Nice send!'), findsOneWidget);
    },
  );
}
