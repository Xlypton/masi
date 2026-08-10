import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:masi/app/theme.dart';
import 'package:masi/core/db/app_database.dart';
import 'package:masi/core/db/database_provider.dart';
import 'package:masi/core/grades/grade_system.dart';
import 'package:masi/core/location/location_service.dart';
import 'package:masi/features/community/application/community_providers.dart';
import 'package:masi/features/community/data/community_repository.dart';
import 'package:masi/features/library/application/library_providers.dart';
import 'package:masi/features/library/presentation/topos_screen.dart';
import 'package:masi/features/moderation/application/moderation_providers.dart';

import '../../../support/async_drain.dart';

/// A nearby COMMUNITY row (somebody else's shared topo) in the Topos-home
/// list used to render as a bare title + "Shared" badge + distance: no
/// grade-band dots, no route count, and — for an admin — no way to act on it.
///
/// Both gaps were reported from a real screenshot, and both were rendering
/// gaps rather than data ones: `SharedTopo` already carries `routeCount` and
/// `routeGradeKeys` (the sync pull imports foreign `routes` rows and
/// `watchSharedTopos` counts them from the LOCAL table), and
/// `AdminDeleteService` already existed — it was simply never reachable from
/// this screen, which was the one surface where a nearby offending topo is
/// most likely to be noticed.
void main() {
  const wallId = 'wall-community';

  /// One nearby community topo with routes in two DISTINCT grade bands, so a
  /// regression to a single fixed colour is detectable rather than merely
  /// "some dot rendered".
  ///
  /// `4.0`/`8.0` are sort keys, not grades; what matters is only that
  /// [bandForSortKey] puts them in different [GradeBand]s, which the test
  /// asserts rather than assumes.
  const twoBandTopo = SharedTopo(
    wallId: wallId,
    name: 'Community Boulder',
    routeCount: 2,
    likeCount: 0,
    commentCount: 0,
    latitude: 0.02,
    longitude: 0.02,
    routeGradeKeys: [4.0, 8.0],
  );

  Future<ProviderContainer> pumpList(
    WidgetTester tester, {
    required bool isAdmin,
    SharedTopo topo = twoBandTopo,
  }) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final container = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWithValue(db),
        nowMsProvider.overrideWithValue(() => 1000),
        locationServiceProvider.overrideWithValue(
          const _FakeLocationService((latitude: 0.0, longitude: 0.0)),
        ),
        toposProvider.overrideWith((ref) => Stream.value(const [])),
        sharedToposProvider.overrideWith((ref) => Stream.value([topo])),
        isAdminProvider.overrideWith((ref) async => isAdmin),
      ],
    );
    addTearDown(container.dispose);

    final router = GoRouter(
      initialLocation: '/',
      routes: [
        GoRoute(path: '/', builder: (context, state) => const ToposScreen()),
        GoRoute(
          path: '/walls/:wallId',
          builder: (context, state) => const SizedBox(),
        ),
      ],
    );

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(
          theme: MasiTheme.light,
          routerConfig: router,
        ),
      ),
    );
    await drainAsync(tester, rounds: 6, settle: false);
    await tester.pumpAndSettle();
    return container;
  }

  group('a nearby community row carries the same hardness signal as an own row', () {
    testWidgets(
      'renders one grade-band dot per distinct band, plus the route count',
      (tester) async {
        await pumpList(tester, isAdmin: false);

        expect(find.byKey(const Key('topo-item-community-$wallId')), findsOneWidget);

        // The bands are derived the same way the widget derives them, so this
        // asserts the RENDERED dots match the data rather than restating a
        // hard-coded pair.
        final bands = gradeBandsFor(twoBandTopo.routeGradeKeys);
        expect(
          bands.length,
          2,
          reason: 'fixture must span two bands for the colour test below',
        );
        for (final band in bands) {
          expect(
            find.byKey(Key('topo-grade-dot-$wallId-${band.name}')),
            findsOneWidget,
            reason: 'missing the dot for ${band.name}',
          );
        }
        expect(find.text('2 routes'), findsOneWidget);
      },
    );

    testWidgets('two different bands are drawn in DIFFERENT colours', (
      tester,
    ) async {
      await pumpList(tester, isAdmin: false);

      final bands = gradeBandsFor(twoBandTopo.routeGradeKeys);
      final colours = <Color?>[];
      for (final band in bands) {
        final container = tester.widget<Container>(
          find.byKey(Key('topo-grade-dot-$wallId-${band.name}')),
        );
        colours.add((container.decoration as BoxDecoration).color);
      }

      expect(colours.whereType<Color>().length, 2);
      expect(
        colours[0],
        isNot(colours[1]),
        reason:
            'a fixed colour for every band would make the dots decoration '
            'rather than a hardness signal',
      );
    });

    testWidgets('a community topo with no graded routes renders no dots and does not crash', (
      tester,
    ) async {
      await pumpList(
        tester,
        isAdmin: false,
        topo: const SharedTopo(
          wallId: wallId,
          name: 'Ungraded Boulder',
          routeCount: 0,
          likeCount: 0,
          commentCount: 0,
          latitude: 0.02,
          longitude: 0.02,
        ),
      );

      expect(find.byKey(const Key('topo-item-community-$wallId')), findsOneWidget);
      for (final band in GradeBand.values) {
        expect(
          find.byKey(Key('topo-grade-dot-$wallId-${band.name}')),
          findsNothing,
        );
      }
      // Matches the own row, which always states the count even at zero.
      expect(find.text('0 routes'), findsOneWidget);
    });
  });

  group('the moderator menu on a community row is admin-only', () {
    testWidgets('a NON-admin sees no menu — a community topo is not theirs to act on', (
      tester,
    ) async {
      await pumpList(tester, isAdmin: false);

      expect(find.byKey(const Key('topo-item-community-$wallId')), findsOneWidget);
      expect(find.byKey(const Key('community-row-menu-$wallId')), findsNothing);
    });

    testWidgets('an ADMIN sees the menu, and it offers the takedown behind a confirm', (
      tester,
    ) async {
      await pumpList(tester, isAdmin: true);

      final menu = find.byKey(const Key('community-row-menu-$wallId'));
      expect(menu, findsOneWidget);

      await tester.tap(menu);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('community-row-admin-delete-$wallId')),
        findsOneWidget,
      );

      await tester.tap(
        find.byKey(const Key('community-row-admin-delete-$wallId')),
      );
      await tester.pumpAndSettle();

      // Destructive work never happens on the first tap: the confirm is the
      // second gate, and until it is answered nothing has been called.
      expect(
        find.byKey(const Key('community-row-admin-delete-confirm-$wallId')),
        findsOneWidget,
      );
    });
  });
}

class _FakeLocationService implements LocationService {
  const _FakeLocationService(this.result);

  final DeviceLocation? result;

  @override
  Future<DeviceLocation?> currentLocation() async => result;
}
