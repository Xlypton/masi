// The shared/feed hardness-signal dot on CommunityFeedScreen's
// `_AscentFeedRow`: a `GradeBandDot` beside the grade text, colored via
// `colorForGradeBand(entry.gradeBand)` — same band colors as the owner's own
// RouteLegend, added purely as a rendering addition (the text stays exactly
// as legible as before).
//
// Harness mirrors community_feed_union_test.dart's `_seedRoute`/`logAscent`
// pattern (duplicated locally since those helpers are file-private there).

import 'package:masi/app/theme.dart';
import 'package:masi/core/db/app_database.dart';
import 'package:masi/core/db/database_provider.dart';
import 'package:masi/core/grades/grade_system.dart';
import 'package:masi/features/account/application/auth_providers.dart';
import 'package:masi/features/community/presentation/community_feed_screen.dart';
import 'package:masi/features/logbook/application/ascents_providers.dart';
import 'package:masi/features/logbook/data/ascents_repository.dart';
import 'package:masi/features/topo/presentation/grade_colors.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import '../../../support/async_drain.dart';

ProviderContainer _makeContainer({required String currentUid}) {
  final db = AppDatabase(NativeDatabase.memory());
  final container = ProviderContainer(
    overrides: [
      appDatabaseProvider.overrideWithValue(db),
      nowMsProvider.overrideWithValue(() => 1000),
      currentUidProvider.overrideWithValue(() => currentUid),
    ],
  );
  addTearDown(db.close);
  addTearDown(container.dispose);
  return container;
}

Widget _wrap(ProviderContainer container) {
  final router = GoRouter(
    initialLocation: '/',
    routes: [
      GoRoute(
        path: '/',
        builder: (context, state) => const CommunityFeedScreen(),
      ),
      GoRoute(
        path: '/community/ascent/:ascentId',
        builder: (context, state) => const SizedBox.shrink(),
      ),
      GoRoute(
        path: '/logbook',
        builder: (context, state) => const SizedBox.shrink(),
      ),
    ],
  );
  return UncontrolledProviderScope(
    container: container,
    child: MaterialApp.router(theme: MasiTheme.light, routerConfig: router),
  );
}

Future<void> _drain(WidgetTester tester) => drainAsync(tester, rounds: 6, settle: false);

Future<void> _seedArea(AppDatabase db, {required String id}) {
  return db.into(db.areas).insert(
    AreasCompanion.insert(id: id, createdAt: 1000, updatedAt: 1000, name: 'Area $id'),
  );
}

Future<void> _seedSector(AppDatabase db, {required String id, required String areaId}) {
  return db.into(db.sectors).insert(
    SectorsCompanion.insert(
      id: id,
      createdAt: 1000,
      updatedAt: 1000,
      areaId: areaId,
      name: 'Sector $id',
      sortOrder: 0,
    ),
  );
}

Future<void> _seedWall(AppDatabase db, {required String id, required String sectorId}) {
  return db.into(db.walls).insert(
    WallsCompanion.insert(
      id: id,
      createdAt: 1000,
      updatedAt: 1000,
      sectorId: sectorId,
      name: 'Wall $id',
      sortOrder: 0,
    ),
  );
}

Future<String> _seedPhoto(AppDatabase db, {required String id, required String wallId}) {
  return db
      .into(db.photos)
      .insert(
        PhotosCompanion.insert(
          id: id,
          createdAt: 1000,
          updatedAt: 1000,
          wallId: wallId,
          localPath: '/tmp/$id.jpg',
          kind: 'original',
          width: 100,
          height: 100,
        ),
      )
      .then((_) => id);
}

Future<String> _seedRoute(
  AppDatabase db, {
  required String id,
  required String wallId,
  required String photoId,
  required int number,
  String? gradeRaw,
  double? gradeSortKey,
}) {
  return db
      .into(db.routes)
      .insert(
        RoutesCompanion.insert(
          id: id,
          createdAt: 1000,
          updatedAt: 1000,
          wallId: wallId,
          photoId: photoId,
          number: number,
          colorIndex: 0,
          pointsJson: '[]',
          symbolsJson: '[]',
          sortOrder: 0,
          gradeRaw: Value(gradeRaw),
          gradeSortKey: Value(gradeSortKey),
        ),
      )
      .then((_) => id);
}

/// Seeds one wall + one graded route + one shared ascent against it, logged
/// by [climberUid]. [gradeRaw]/[gradeSortKey] control the route's grade (and
/// hence its `SharedAscentEntry.gradeBand`); pass both null for an ungraded
/// route (no grade text, no dot — the row's existing `gradeLabel != null`
/// gate already covers that case unchanged).
Future<String> _seedAscent(
  ProviderContainer container, {
  required String climberUid,
  required String wallId,
  required String routeId,
  String? gradeRaw,
  double? gradeSortKey,
}) async {
  final db = container.read(appDatabaseProvider);
  await _seedArea(db, id: 'area-$wallId');
  await _seedSector(db, id: 'sector-$wallId', areaId: 'area-$wallId');
  await _seedWall(db, id: wallId, sectorId: 'sector-$wallId');
  final photoId = await _seedPhoto(db, id: 'photo-$wallId', wallId: wallId);
  await _seedRoute(
    db,
    id: routeId,
    wallId: wallId,
    photoId: photoId,
    number: 1,
    gradeRaw: gradeRaw,
    gradeSortKey: gradeSortKey,
  );

  final ascent = await container.read(ascentsRepositoryProvider).logAscent(
    routeId: routeId,
    wallId: wallId,
    climbedAt: DateTime.utc(2026, 7, 1),
    style: AscentStyle.redpoint,
    shared: true,
  );
  return ascent.id;
}

void main() {
  testWidgets(
    'a graded shared-ascent row renders a community-ascent-row-<id>-grade-dot '
    "with its grade band's color, beside the still-legible grade text",
    (tester) async {
      final container = _makeContainer(currentUid: 'climber-1');
      final ascentId = await _seedAscent(
        container,
        climberUid: 'climber-1',
        wallId: 'wall-hard',
        routeId: 'route-hard',
        gradeRaw: '7a',
        gradeSortKey: 13.0, // hard band
      );

      await tester.pumpWidget(_wrap(container));
      await _drain(tester);

      final dot = tester.widget<GradeBandDot>(
        find.byKey(Key('community-ascent-row-$ascentId-grade-dot')),
      );
      expect(dot.color, colorForGradeBand(GradeBand.hard));
      // The grade text itself is untouched — the dot is an addition, not a
      // replacement.
      expect(find.text('7a'), findsOneWidget);
    },
  );

  testWidgets(
    'two shared-ascent rows in different grade bands render DIFFERENT dot '
    'colors',
    (tester) async {
      final container = _makeContainer(currentUid: 'climber-1');
      final beginnerAscentId = await _seedAscent(
        container,
        climberUid: 'climber-1',
        wallId: 'wall-beginner',
        routeId: 'route-beginner',
        gradeRaw: '4a',
        gradeSortKey: 1.0, // beginner band
      );
      final eliteAscentId = await _seedAscent(
        container,
        climberUid: 'climber-1',
        wallId: 'wall-elite',
        routeId: 'route-elite',
        gradeRaw: '9a',
        gradeSortKey: 25.0, // elite band
      );

      await tester.pumpWidget(_wrap(container));
      await _drain(tester);

      final beginnerDot = tester.widget<GradeBandDot>(
        find.byKey(Key('community-ascent-row-$beginnerAscentId-grade-dot')),
      );
      final eliteDot = tester.widget<GradeBandDot>(
        find.byKey(Key('community-ascent-row-$eliteAscentId-grade-dot')),
      );
      expect(beginnerDot.color, isNot(eliteDot.color));
    },
  );

  testWidgets(
    'an ungraded shared ascent renders no grade text and no dot, and does '
    'not crash',
    (tester) async {
      final container = _makeContainer(currentUid: 'climber-1');
      final ascentId = await _seedAscent(
        container,
        climberUid: 'climber-1',
        wallId: 'wall-ungraded',
        routeId: 'route-ungraded',
      );

      await tester.pumpWidget(_wrap(container));
      await _drain(tester);

      expect(
        find.byKey(Key('community-ascent-row-$ascentId')),
        findsOneWidget,
      );
      expect(
        find.byKey(Key('community-ascent-row-$ascentId-grade-dot')),
        findsNothing,
      );
    },
  );
}
