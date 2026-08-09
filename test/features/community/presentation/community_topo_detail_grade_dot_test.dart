// The shared/feed hardness-signal dot: CommunityTopoDetailScreen's Routes
// list (`_buildRouteRow`) now carries the same grade-band-colored dot as the
// owner's own RouteLegend (route_legend.dart:207/244), via
// `colorForRoute(route, kRoutePalette)` — the exact same function, so a
// graded route gets its band color and an ungraded one falls back to its
// palette `colorIndex` color exactly as it does on the owner's own topo.

import 'package:masi/app/theme.dart';
import 'package:masi/core/db/app_database.dart';
import 'package:masi/core/db/database_provider.dart';
import 'package:masi/features/account/application/auth_providers.dart';
import 'package:masi/features/account/data/auth_repository.dart';
import 'package:masi/core/grades/grade_system.dart';
import 'package:masi/features/community/presentation/community_topo_detail_screen.dart';
import 'package:masi/features/library/application/library_providers.dart';
import 'package:masi/features/topo/data/route_repository.dart';
import 'package:masi/features/topo/domain/topo_route.dart';
import 'package:masi/features/topo/presentation/grade_colors.dart';
import 'package:masi/features/topo/presentation/route_palette.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';

/// Trimmed from `community_topo_detail_test.dart`'s identical private
/// `_FakeAuthRepository` (that one is library-private to its own file).
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

Widget _wrap(ProviderContainer container, Widget child) {
  return UncontrolledProviderScope(
    container: container,
    child: MaterialApp(theme: MasiTheme.light, home: child),
  );
}

void main() {
  /// Seeds a real in-memory DB with Area -> Sector -> Wall -> Photo
  /// (`'original'`) -> two routes: one graded '9a' (elite band, dbId
  /// returned as `eliteRouteDbId`) and one left entirely ungraded (dbId
  /// `ungradedRouteDbId`, colorIndex 3) — mirrors
  /// `community_topo_detail_test.dart`'s `seedWallWithRoute` harness.
  Future<
    ({
      AppDatabase db,
      ProviderContainer container,
      String wallId,
      String eliteRouteDbId,
      String ungradedRouteDbId,
    })
  >
  seedTwoRoutes(WidgetTester tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    final container = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWithValue(db),
        nowMsProvider.overrideWithValue(() => 1000),
        authRepositoryProvider.overrideWithValue(
          _FakeAuthRepository(
            const AuthSessionState.signedIn('climber@example.com'),
          ),
        ),
      ],
    );

    final crud = container.read(libraryCrudRepositoryProvider);
    final area = await crud.createArea('Area');
    final sector = await crud.createSector(area.id, 'Sector');
    final wall = await crud.createWall(sector.id, 'Wall');

    late String photoId;
    await tester.runAsync(() async {
      photoId = await crud.attachPhotoToWall(
        wall.id,
        XFile('/tmp/community-detail-grade-dot-test-photo.jpg'),
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
        gradeRaw: '9a',
        gradeSortKey: 25.0, // elite band
      ),
    );
    await routeRepo.upsertRoute(
      wall.id,
      photoId,
      const TopoRoute(
        id: 2,
        number: 2,
        points: [Offset(0.3, 0.3), Offset(0.4, 0.4)],
        colorIndex: 3,
      ),
    );
    final dbIds = await routeRepo.routeDbIdsByNumber(wall.id);

    return (
      db: db,
      container: container,
      wallId: wall.id,
      eliteRouteDbId: dbIds[1]!,
      ungradedRouteDbId: dbIds[2]!,
    );
  }

  testWidgets(
    'a graded route renders a community-route-grade-dot with its grade '
    "band's color",
    (tester) async {
      final seeded = await seedTwoRoutes(tester);
      addTearDown(seeded.db.close);
      addTearDown(seeded.container.dispose);

      await tester.pumpWidget(
        _wrap(
          seeded.container,
          CommunityTopoDetailScreen(
            wallId: seeded.wallId,
            debugInitialImageSize: const Size(1000, 2000),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final dotKey = Key(
        'community-route-grade-dot-${seeded.eliteRouteDbId}',
      );
      final dot = tester.widget<GradeBandDot>(
        find.byKey(dotKey, skipOffstage: false),
      );
      expect(dot.color, colorForGradeBand(GradeBand.elite));
    },
  );

  testWidgets(
    'an ungraded route still renders a dot, at its palette colorIndex '
    'color, and does not crash',
    (tester) async {
      final seeded = await seedTwoRoutes(tester);
      addTearDown(seeded.db.close);
      addTearDown(seeded.container.dispose);

      await tester.pumpWidget(
        _wrap(
          seeded.container,
          CommunityTopoDetailScreen(
            wallId: seeded.wallId,
            debugInitialImageSize: const Size(1000, 2000),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final dotKey = Key(
        'community-route-grade-dot-${seeded.ungradedRouteDbId}',
      );
      final dot = tester.widget<GradeBandDot>(
        find.byKey(dotKey, skipOffstage: false),
      );
      expect(dot.color, kRoutePalette[3]);
    },
  );

  testWidgets(
    'the graded and ungraded routes render DIFFERENT dot colors',
    (tester) async {
      final seeded = await seedTwoRoutes(tester);
      addTearDown(seeded.db.close);
      addTearDown(seeded.container.dispose);

      await tester.pumpWidget(
        _wrap(
          seeded.container,
          CommunityTopoDetailScreen(
            wallId: seeded.wallId,
            debugInitialImageSize: const Size(1000, 2000),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final eliteDot = tester.widget<GradeBandDot>(
        find.byKey(
          Key('community-route-grade-dot-${seeded.eliteRouteDbId}'),
          skipOffstage: false,
        ),
      );
      final ungradedDot = tester.widget<GradeBandDot>(
        find.byKey(
          Key('community-route-grade-dot-${seeded.ungradedRouteDbId}'),
          skipOffstage: false,
        ),
      );
      expect(eliteDot.color, isNot(ungradedDot.color));
    },
  );
}
