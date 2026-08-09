// The shared/feed hardness-signal dot on AscentDetailScreen: a
// `GradeBandDot` beside `ascent-detail-grade-label`, colored via
// `colorForGradeBand(entry.gradeBand)` — same band colors as the owner's own
// RouteLegend. Harness mirrors ascent_detail_screen_test.dart's
// `seedSharedAscent` (duplicated locally since that helper is file-private).

import 'package:masi/app/theme.dart';
import 'package:masi/core/db/app_database.dart';
import 'package:masi/core/db/database_provider.dart';
import 'package:masi/core/grades/grade_system.dart';
import 'package:masi/features/account/application/auth_providers.dart';
import 'package:masi/features/account/data/auth_repository.dart';
import 'package:masi/features/community/presentation/ascent_detail_screen.dart';
import 'package:masi/features/library/application/library_providers.dart';
import 'package:masi/features/logbook/data/ascents_repository.dart';
import 'package:masi/features/topo/data/route_repository.dart';
import 'package:masi/features/topo/domain/topo_route.dart';
import 'package:masi/features/topo/presentation/grade_colors.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';

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

Future<
  ({AppDatabase db, ProviderContainer container, String ascentId})
>
_seedSharedAscent(
  WidgetTester tester, {
  required String gradeRaw,
  required double gradeSortKey,
}) async {
  tester.view.physicalSize = const Size(400, 1200);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

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

  late String photoId;
  await tester.runAsync(() async {
    photoId = await crud.attachPhotoToWall(
      wall.id,
      XFile('/tmp/ascent-detail-grade-dot-test-photo.jpg'),
      1000,
      2000,
    );
  });

  final routeRepo = RouteRepository(db, nowMs: () => 1000);
  await routeRepo.upsertRoute(
    wall.id,
    photoId,
    TopoRoute(
      id: 1,
      number: 1,
      points: const [Offset(0.1, 0.1), Offset(0.2, 0.2)],
      name: 'Sunny Arete',
      gradeRaw: gradeRaw,
      gradeSortKey: gradeSortKey,
    ),
  );
  final dbIds = await routeRepo.routeDbIdsByNumber(wall.id);

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
  );

  return (db: db, container: container, ascentId: ascent.id);
}

Widget _wrap(ProviderContainer container, Widget child) {
  return UncontrolledProviderScope(
    container: container,
    child: MaterialApp(theme: MasiTheme.light, home: child),
  );
}

void main() {
  testWidgets(
    "a graded ascent renders ascent-detail-grade-dot with its grade band's "
    'color, and the grade text stays legible',
    (tester) async {
      final seeded = await _seedSharedAscent(
        tester,
        gradeRaw: '6a+',
        gradeSortKey: 8.0,
      );
      addTearDown(seeded.db.close);
      addTearDown(seeded.container.dispose);

      await tester.pumpWidget(
        _wrap(
          seeded.container,
          AscentDetailScreen(ascentId: seeded.ascentId),
        ),
      );
      await tester.pumpAndSettle();

      final dot = tester.widget<GradeBandDot>(
        find.byKey(const Key('ascent-detail-grade-dot'), skipOffstage: false),
      );
      // French '6a+' -> sort key 8.0 -> advanced band (see
      // grade_system.dart's `_advancedMax` doc: indices 8..12).
      expect(dot.color, colorForGradeBand(GradeBand.advanced));
      expect(
        find.text('6a+', skipOffstage: false),
        findsOneWidget,
        reason: 'the dot is an addition, not a replacement for the text',
      );
    },
  );

  // Two separate `testWidgets` (rather than one pumping two screens in
  // sequence): re-pumping a second full `AscentDetailScreen` tree over the
  // first inside one test leaves a pending timer behind (unrelated to the
  // dot itself) that trips flutter_test's post-test invariant check.
  Future<Color> dotColorFor(
    WidgetTester tester, {
    required String gradeRaw,
    required double gradeSortKey,
  }) async {
    final seeded = await _seedSharedAscent(
      tester,
      gradeRaw: gradeRaw,
      gradeSortKey: gradeSortKey,
    );
    addTearDown(seeded.db.close);
    addTearDown(seeded.container.dispose);

    await tester.pumpWidget(
      _wrap(seeded.container, AscentDetailScreen(ascentId: seeded.ascentId)),
    );
    await tester.pumpAndSettle();

    return tester
        .widget<GradeBandDot>(
          find.byKey(const Key('ascent-detail-grade-dot'), skipOffstage: false),
        )
        .color;
  }

  testWidgets(
    'a beginner-band ascent and an elite-band ascent render DIFFERENT dot '
    'colors',
    (tester) async {
      final beginnerColor = await dotColorFor(
        tester,
        gradeRaw: '4a',
        gradeSortKey: 1.0,
      );
      expect(beginnerColor, colorForGradeBand(GradeBand.beginner));
    },
  );

  testWidgets(
    'an elite-band ascent renders a color different from the beginner band',
    (tester) async {
      final eliteColor = await dotColorFor(
        tester,
        gradeRaw: '9a',
        gradeSortKey: 25.0,
      );
      expect(eliteColor, colorForGradeBand(GradeBand.elite));
      expect(eliteColor, isNot(colorForGradeBand(GradeBand.beginner)));
    },
  );
}
