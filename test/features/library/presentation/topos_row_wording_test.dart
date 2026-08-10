// "Shared" used to mean three different things on one screen — the owner's own
// live topo, the Filters sheet's visibility segment, and somebody else's topo.
// Option B, chosen by the owner: rename only the COMMUNITY badge, so three
// distinct facts get three distinct words.
//
//   Published — my topo, live to others
//   Private   — my topo, not shared
//   Community — somebody else's topo (or their display name, once resolved)
//
// Plus the honest filter note: the facets can only be evaluated against own
// topos, so community rows drop out of the list entirely while any facet is set,
// and the list says so instead of quietly returning a mixed result.

import 'dart:async';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:masi/app/theme.dart';
import 'package:masi/core/db/app_database.dart';
import 'package:masi/core/db/database_provider.dart';
import 'package:masi/core/location/location_service.dart';
import 'package:masi/features/backup/application/backup_providers.dart';
import 'package:masi/features/backup/application/sync_orchestrator.dart';
import 'package:masi/features/backup/data/connectivity_service.dart';
import 'package:masi/features/community/application/community_providers.dart';
import 'package:masi/features/community/data/community_repository.dart';
import 'package:masi/features/library/application/library_providers.dart';
import 'package:masi/features/library/data/library_crud_repository.dart';
import 'package:masi/features/library/presentation/topos_screen.dart';

import '../../../support/async_drain.dart';

class _FakeSyncOrchestrator extends SyncOrchestrator {
  @override
  SyncOrchestratorState build() => const SyncOrchestratorState();

  @override
  Future<void> pullNow({bool throttled = false}) async {}
}

class _ReachableConnectivity implements ConnectivityService {
  @override
  Future<bool> isBackendReachable() async => true;

  @override
  Future<NetworkStatus> currentStatus() async => NetworkStatus.wifi;

  @override
  Stream<NetworkStatus> statusChanges() => const Stream.empty();
}

/// A [LocationService] fixed at the origin, so the proximity list can actually
/// merge community entries in (without a fix it degrades to own topos only —
/// see `sortedByProximityToposProvider`).
class _FakeLocationService implements LocationService {
  const _FakeLocationService();

  @override
  Future<DeviceLocation?> currentLocation() async =>
      (latitude: 0.0, longitude: 0.0);
}

/// Own topos: one published (`visibility: 'shared'`), one private.
const _ownTopos = [
  TopoRef(
    wallId: 'w-pub',
    name: 'My Published Wall',
    thumbnailPath: null,
    routeCount: 1,
    createdAt: 1000,
    visibility: 'shared',
    latitude: 0.001,
    longitude: 0.001,
    routeStars: [3],
  ),
  TopoRef(
    wallId: 'w-priv',
    name: 'My Private Wall',
    thumbnailPath: null,
    routeCount: 1,
    createdAt: 900,
    latitude: 0.002,
    longitude: 0.002,
    routeStars: [1],
  ),
];

const _communityTopos = [
  SharedTopo(
    wallId: 'w-foreign',
    name: 'Somebody Elses Boulder',
    routeCount: 2,
    likeCount: 0,
    commentCount: 0,
    latitude: 0.003,
    longitude: 0.003,
    ownerId: 'uid-stranger',
  ),
];

ProviderContainer _makeContainer({
  List<TopoRef> topos = _ownTopos,
  List<SharedTopo> shared = _communityTopos,
}) {
  final db = AppDatabase(NativeDatabase.memory());
  final container = ProviderContainer(
    overrides: [
      appDatabaseProvider.overrideWithValue(db),
      nowMsProvider.overrideWithValue(() => 1000),
      connectivityServiceProvider.overrideWithValue(_ReachableConnectivity()),
      syncOrchestratorProvider.overrideWith(_FakeSyncOrchestrator.new),
      locationServiceProvider.overrideWithValue(const _FakeLocationService()),
      toposProvider.overrideWith((ref) => Stream.value(topos)),
      sharedToposProvider.overrideWith((ref) => Stream.value(shared)),
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
      GoRoute(path: '/', builder: (context, state) => const ToposScreen()),
      GoRoute(
        path: '/walls/:wallId',
        builder: (context, state) => const SizedBox(),
      ),
      GoRoute(path: '/areas', builder: (context, state) => const SizedBox()),
      GoRoute(path: '/account', builder: (context, state) => const SizedBox()),
    ],
  );
  return UncontrolledProviderScope(
    container: container,
    child: MaterialApp.router(theme: MasiTheme.light, routerConfig: router),
  );
}

Future<void> _drain(WidgetTester tester) async {
  await drainAsync(tester, rounds: 6, settle: false);
  await tester.pumpAndSettle();
}

/// Seeds the local `profiles` mirror so `profileDisplayNameProvider` — a live
/// Drift watch, NOT a fetch — can resolve the stranger's name.
Future<void> _seedProfile(
  WidgetTester tester,
  AppDatabase db, {
  required String uid,
  required String displayName,
}) async {
  await tester.runAsync(() async {
    await db
        .into(db.profiles)
        .insert(
          ProfilesCompanion.insert(
            id: uid,
            createdAt: 1000,
            updatedAt: 1000,
            ownerId: Value(uid),
            displayName: Value(displayName),
          ),
        );
  });
}

Future<void> _openSheet(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('topos-filter-button')));
  await tester.pumpAndSettle();
}

void main() {
  group('three facts, three words', () {
    testWidgets(
      'an own PUBLISHED topo reads "Published" and an own unshared one reads '
      '"Private"',
      (tester) async {
        final container = _makeContainer(shared: const []);
        await tester.pumpWidget(_wrap(container));
        await _drain(tester);

        expect(
          find.descendant(
            of: find.byKey(const Key('topo-visibility-badge-w-pub')),
            matching: find.text('Published'),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: find.byKey(const Key('topo-visibility-badge-w-priv')),
            matching: find.text('Private'),
          ),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'a FOREIGN topo reads "Community" while the owner\'s name is unresolved '
      '— never "Shared", and never the raw uid',
      (tester) async {
        final container = _makeContainer();
        await tester.pumpWidget(_wrap(container));
        await _drain(tester);

        final badge = find.byKey(const Key('topo-shared-badge-w-foreign'));
        expect(badge, findsOneWidget);
        expect(
          find.descendant(of: badge, matching: find.text('Community')),
          findsOneWidget,
        );
        expect(
          find.descendant(of: badge, matching: find.text('Shared')),
          findsNothing,
        );
        expect(find.textContaining('uid-stranger'), findsNothing);
      },
    );

    testWidgets(
      'a FOREIGN topo reads the owner\'s DISPLAY NAME once the synced profile '
      'row is there (reusing the same live door every other author name uses '
      '— no extra fetch)',
      (tester) async {
        final container = _makeContainer();
        final db = container.read(appDatabaseProvider);
        await _seedProfile(
          tester,
          db,
          uid: 'uid-stranger',
          displayName: 'Lena Alp',
        );

        await tester.pumpWidget(_wrap(container));
        await _drain(tester);

        final badge = find.byKey(const Key('topo-shared-badge-w-foreign'));
        expect(
          find.descendant(of: badge, matching: find.text('Lena Alp')),
          findsOneWidget,
        );
        expect(
          find.descendant(of: badge, matching: find.text('Community')),
          findsNothing,
        );
      },
    );

    testWidgets(
      'a FOREIGN topo with NO ownerId at all still reads "Community" (the '
      'unresolvable case must not be able to render an empty badge)',
      (tester) async {
        final container = _makeContainer(
          shared: const [
            SharedTopo(
              wallId: 'w-anon',
              name: 'Unattributed Boulder',
              routeCount: 1,
              likeCount: 0,
              commentCount: 0,
              latitude: 0.004,
              longitude: 0.004,
            ),
          ],
        );
        await tester.pumpWidget(_wrap(container));
        await _drain(tester);

        expect(
          find.descendant(
            of: find.byKey(const Key('topo-shared-badge-w-anon')),
            matching: find.text('Community'),
          ),
          findsOneWidget,
        );
      },
    );
  });

  group('the honest filter note', () {
    testWidgets(
      'with NO facet active, community rows render as before and there is no '
      'scope note (no regression)',
      (tester) async {
        final container = _makeContainer();
        await tester.pumpWidget(_wrap(container));
        await _drain(tester);

        expect(
          find.byKey(const Key('topo-item-community-w-foreign')),
          findsOneWidget,
        );
        expect(find.byKey(const Key('topo-item-w-pub')), findsOneWidget);
        expect(find.byKey(const Key('topo-item-w-priv')), findsOneWidget);
        expect(find.byKey(const Key('topos-filter-scope-note')), findsNothing);
      },
    );

    testWidgets(
      'with a VISIBILITY facet active, no community row is rendered and the '
      'header says the filters cover own topos only',
      (tester) async {
        final container = _makeContainer();
        await tester.pumpWidget(_wrap(container));
        await _drain(tester);

        await _openSheet(tester);
        await tester.tap(
          find.byKey(const Key('topos-filter-visibility-shared')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('topos-filter-done')));
        await tester.pumpAndSettle();

        expect(
          find.byKey(const Key('topo-item-community-w-foreign')),
          findsNothing,
          reason:
              'the facets cannot be evaluated against a community entry, so '
              'showing it inside a filtered result makes the result a lie',
        );
        expect(find.byKey(const Key('topo-item-w-pub')), findsOneWidget);
        expect(find.byKey(const Key('topo-item-w-priv')), findsNothing);
        expect(
          find.byKey(const Key('topos-filter-scope-note')),
          findsOneWidget,
        );
        expect(
          find.text('Filters apply to your own topos only'),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'a RATING facet excludes community rows too — the rule is "any facet", '
      'not "the visibility facet"',
      (tester) async {
        final container = _makeContainer();
        await tester.pumpWidget(_wrap(container));
        await _drain(tester);

        await _openSheet(tester);
        await tester.tap(find.byKey(const Key('filter-minstars-2')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('topos-filter-done')));
        await tester.pumpAndSettle();

        expect(
          find.byKey(const Key('topo-item-community-w-foreign')),
          findsNothing,
        );
        expect(find.byKey(const Key('topo-item-w-pub')), findsOneWidget);
        expect(find.byKey(const Key('topo-item-w-priv')), findsNothing);
        expect(
          find.byKey(const Key('topos-filter-scope-note')),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'clearing the facets brings the community rows AND removes the note',
      (tester) async {
        final container = _makeContainer();
        await tester.pumpWidget(_wrap(container));
        await _drain(tester);

        await _openSheet(tester);
        await tester.tap(
          find.byKey(const Key('topos-filter-visibility-private')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('topos-filter-done')));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const Key('topo-item-community-w-foreign')),
          findsNothing,
        );

        await _openSheet(tester);
        await tester.tap(find.byKey(const Key('topos-filter-clear')));
        await tester.pumpAndSettle();

        expect(
          find.byKey(const Key('topo-item-community-w-foreign')),
          findsOneWidget,
        );
        expect(find.byKey(const Key('topos-filter-scope-note')), findsNothing);
      },
    );

    testWidgets(
      'a SEARCH query is not a facet: it still narrows community rows rather '
      'than excluding them, and adds no scope note',
      (tester) async {
        final container = _makeContainer();
        await tester.pumpWidget(_wrap(container));
        await _drain(tester);

        await tester.enterText(
          find.byKey(const Key('topos-search-field')),
          'Elses',
        );
        await _drain(tester);

        expect(
          find.byKey(const Key('topo-item-community-w-foreign')),
          findsOneWidget,
        );
        expect(find.byKey(const Key('topo-item-w-pub')), findsNothing);
        expect(find.byKey(const Key('topos-filter-scope-note')), findsNothing);
      },
    );
  });
}
