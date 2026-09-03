import 'dart:async';

import 'package:masi/app/theme.dart';
import 'package:masi/core/db/app_database.dart';
import 'package:masi/core/db/database_provider.dart';
import 'package:masi/core/location/location_service.dart';
import 'package:masi/features/backup/application/backup_providers.dart';
import 'package:masi/features/backup/data/connectivity_service.dart';
import 'package:masi/features/community/application/comments_providers.dart';
import 'package:masi/features/community/application/community_providers.dart';
import 'package:masi/features/community/application/likes_providers.dart';
import 'package:masi/features/community/data/community_repository.dart';
import 'package:masi/features/community/data/likes_repository.dart';
import 'package:masi/features/community/presentation/ascent_detail_screen.dart';
import 'package:masi/features/community/presentation/community_feed_screen.dart';
import 'package:masi/features/community/presentation/community_map_screen.dart';
import 'package:masi/features/library/application/library_providers.dart';
import 'package:masi/features/logbook/application/ascents_providers.dart';
import 'package:masi/features/logbook/data/ascents_repository.dart';
import 'package:masi/features/topo/data/route_repository.dart';
import 'package:masi/features/topo/domain/topo_route.dart';
import 'package:masi/shared/presentation/masi_icon.dart';
import 'package:masi/shared/presentation/masi_loading_indicator.dart';
import 'package:masi/shared/presentation/masi_skeleton.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';

import '../../../support/async_drain.dart';
import '../../../support/fake_basemap.dart';

/// The Community feature's adoption of the shared loading system
/// (`MasiAsyncView` / `MasiSkeleton*` / `MasiLoadingIndicator` /
/// `PendingIconButton`). Kept as its own file rather than folded into the
/// already-huge `community_screen_test.dart`, mirroring
/// `community_pull_refresh_test.dart`'s stated rationale.
///
/// Every test here drives the clock EXPLICITLY. A tree with a revealed
/// skeleton or spinner never settles (`MasiShimmer`'s sweep and the spinner's
/// rotation repeat forever), so `pumpAndSettle()` is not usable in this file —
/// see `MasiSkeleton`'s and `MasiLoadingGate`'s docs.

/// A [ConnectivityService] that always answers "reachable" — unconditional in
/// every container below, so the real `SystemConnectivityService` never issues
/// a genuine `http.get` from a widget test (see `community_screen_test.dart`'s
/// identical double).
class _ScriptedConnectivity implements ConnectivityService {
  @override
  Future<bool> isBackendReachable() async => true;

  @override
  Future<NetworkStatus> currentStatus() async => NetworkStatus.wifi;

  @override
  Stream<NetworkStatus> statusChanges() => const Stream.empty();
}

/// A [LocationService] whose fix is held open by [gate] — the point being that
/// a real cold GPS fix takes SECONDS, which is exactly the wait the map's
/// find-me control used to render nothing at all for.
class _GatedLocationService implements LocationService {
  _GatedLocationService(this.gate);

  final Completer<DeviceLocation?> gate;
  int calls = 0;

  @override
  Future<DeviceLocation?> currentLocation() {
    calls++;
    return gate.future;
  }
}

/// A [TileProvider] that never touches the network — the Map tab must never
/// perform real tile I/O from a widget test (CLAUDE.md).
/// A [LikesRepository] whose ascent toggle is held open by [gate], so a test
/// can observe the screen WHILE the write is in flight — which is the whole
/// question for an optimistic update.
int _fixedNow() => 1000;

class _GatedLikesRepository extends LikesRepository {
  _GatedLikesRepository(super.db, {required this.gate})
    : super(nowMs: _fixedNow);

  final Completer<void> gate;

  @override
  Future<bool> toggleAscentLike(String ascentId) async {
    await gate.future;
    return super.toggleAscentLike(ascentId);
  }
}

void main() {
  Widget wrap(ProviderContainer container, Widget child) {
    return UncontrolledProviderScope(
      container: container,
      child: MaterialApp(theme: MasiTheme.light, home: child),
    );
  }

  ProviderContainer makeContainer({
    Stream<List<SharedTopo>>? sharedTopos,
    Stream<List<SharedAscentEntry>>? sharedAscents,
    LocationService? locationService,
    AppDatabase? database,
  }) {
    final db = database ?? AppDatabase(NativeDatabase.memory());
    final container = ProviderContainer(
      overrides: [
      ...fakeBasemapOverrides(),
        appDatabaseProvider.overrideWithValue(db),
        nowMsProvider.overrideWithValue(() => 1000),
        connectivityServiceProvider.overrideWithValue(_ScriptedConnectivity()),
        if (sharedTopos != null)
          sharedToposProvider.overrideWith((ref) => sharedTopos),
        if (sharedAscents != null)
          sharedAscentsProvider.overrideWith((ref) => sharedAscents),
        if (locationService != null)
          locationServiceProvider.overrideWithValue(locationService),
      ],
    );
    if (database == null) addTearDown(db.close);
    addTearDown(container.dispose);
    return container;
  }

  group('CommunityFeedScreen: the first load is shaped, not a spinner', () {
    testWidgets(
      'nothing is painted inside the reveal delay, and the feed-card skeleton '
      '(never a CircularProgressIndicator) appears past it',
      (tester) async {
        // Deliberately never-emitting: this test is about what the screen shows
        // while it genuinely does not know yet.
        final topos = StreamController<List<SharedTopo>>();
        final ascents = StreamController<List<SharedAscentEntry>>();
        addTearDown(topos.close);
        addTearDown(ascents.close);

        await tester.pumpWidget(
          wrap(
            makeContainer(
              sharedTopos: topos.stream,
              sharedAscents: ascents.stream,
            ),
            const CommunityFeedScreen(),
          ),
        );

        // Inside MasiMotion.loadingRevealDelay (180 ms): the anti-flash window.
        await tester.pump(const Duration(milliseconds: 100));
        expect(find.byKey(MasiSkeletonList.listKey), findsNothing);
        expect(find.byType(CircularProgressIndicator), findsNothing);

        // Past it: the shaped placeholder.
        await tester.pump(const Duration(milliseconds: 120));
        expect(find.byKey(MasiSkeletonList.listKey), findsOneWidget);
        expect(find.byType(MasiSkeletonFeedCard), findsWidgets);
        // The bare spinner this screen used to show is gone for good.
        expect(find.byType(CircularProgressIndicator), findsNothing);
      },
    );

    testWidgets(
      "the skeleton's search-row slot is exactly as tall as the real search "
      'row, so the feed does not jump when the first page lands',
      (tester) async {
        // 1. The real row, measured.
        await tester.pumpWidget(
          wrap(
            makeContainer(
              sharedTopos: Stream.value(const <SharedTopo>[]),
              sharedAscents: Stream.value(const <SharedAscentEntry>[]),
            ),
            const CommunityFeedScreen(),
          ),
        );
        await drainAsync(tester, settle: false);
        final realHeight = tester
            .getSize(find.byKey(const Key('community-search-field')))
            .height;
        expect(realHeight, greaterThan(0));

        // 2. The skeleton's stand-in for it.
        final topos = StreamController<List<SharedTopo>>();
        final ascents = StreamController<List<SharedAscentEntry>>();
        addTearDown(topos.close);
        addTearDown(ascents.close);
        await tester.pumpWidget(
          wrap(
            makeContainer(
              sharedTopos: topos.stream,
              sharedAscents: ascents.stream,
            ),
            const CommunityFeedScreen(),
          ),
        );
        await tester.pump(const Duration(milliseconds: 220));
        final skeletonHeight = tester
            .getSize(find.byKey(const Key('community-feed-skeleton-search')))
            .height;

        expect(
          skeletonHeight,
          realHeight,
          reason:
              'a skeleton whose geometry does not match the content it '
              'precedes makes the screen jump on arrival, which is worse '
              'than a spinner',
        );
      },
    );
  });

  group('CommunityMapScreen: the map controls report their own work', () {
    testWidgets(
      'find-me shows the pending cue ON the control while the fix is in '
      'flight, and a second tap does not start a second fix',
      (tester) async {
        final gate = Completer<DeviceLocation?>();
        final location = _GatedLocationService(gate);

        await tester.pumpWidget(
          wrap(
            makeContainer(
              sharedTopos: Stream.value(const <SharedTopo>[]),
              locationService: location,
            ),
            const CommunityMapScreen(),
          ),
        );
        await drainAsync(tester, settle: false);

        // `myLocationProvider` reads the same service at mount for the "you are
        // here" marker; count from here so this asserts about the BUTTON.
        final callsBeforeTap = location.calls;

        await tester.tap(find.byKey(const Key('community-map-find-me')));
        await tester.pump();
        expect(location.calls, callsBeforeTap + 1);

        // Past the reveal delay: the cue is up.
        await tester.pump(const Duration(milliseconds: 220));
        expect(find.byKey(MasiLoadingIndicator.spinnerKey), findsOneWidget);

        // The impatient second tap is swallowed rather than starting a second
        // GPS fix.
        await tester.tap(find.byKey(const Key('community-map-find-me')));
        await tester.pump();
        expect(location.calls, callsBeforeTap + 1);

        gate.complete(null);
        await tester.pump();
        // Held for MasiMotion.loadingMinVisible, then gone — no strobe.
        await tester.pump(const Duration(milliseconds: 500));
        expect(find.byKey(MasiLoadingIndicator.spinnerKey), findsNothing);
      },
    );
  });

  group('AscentDetailScreen: an optimistic like and a single-shot post', () {
    /// Seeds Area -> Sector -> Wall -> Photo -> Route -> one SHARED ascent and
    /// returns its id. Trimmed from `ascent_detail_screen_test.dart`'s
    /// `seedSharedAscent` (private to that file).
    Future<({AppDatabase db, ProviderContainer container, String ascentId})>
    seedSharedAscent(WidgetTester tester, {Completer<void>? likeGate}) async {
      // Taller than flutter_test's default 800x600: the screen now leads with
      // a large square of route art (`AscentRouteArtHeader`) and a `ListView`
      // never builds a child it never lays out, so the comment composer would
      // be absent from the tree rather than merely below the fold. Mirrors
      // `ascent_detail_screen_test.dart`'s identical guard.
      tester.view.physicalSize = const Size(400, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final container = ProviderContainer(
        overrides: [
      ...fakeBasemapOverrides(),
          appDatabaseProvider.overrideWithValue(db),
          nowMsProvider.overrideWithValue(() => 1000),
          connectivityServiceProvider.overrideWithValue(_ScriptedConnectivity()),
          if (likeGate != null)
            likesRepositoryProvider.overrideWithValue(
              _GatedLikesRepository(db, gate: likeGate),
            ),
        ],
      );
      addTearDown(container.dispose);

      final crud = container.read(libraryCrudRepositoryProvider);
      final area = await crud.createArea('Area');
      final sector = await crud.createSector(area.id, 'Sector');
      final wall = await crud.createWall(sector.id, 'Wall');
      // Real file I/O — must run outside the fake clock.
      late String photoId;
      await tester.runAsync(() async {
        photoId = await crud.attachPhotoToWall(
          wall.id,
          XFile('/tmp/community-loading-test-photo.jpg'),
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

    Finder heartIcon(String name) => find.byWidgetPredicate(
      (widget) => widget is MasiIcon && widget.name == name,
    );

    testWidgets(
      'the heart fills on the very next frame after the tap — while the write '
      'is still in flight — and shows no spinner',
      (tester) async {
        final likeGate = Completer<void>();
        final seeded = await seedSharedAscent(tester, likeGate: likeGate);

        await tester.pumpWidget(
          wrap(
            seeded.container,
            AscentDetailScreen(ascentId: seeded.ascentId),
          ),
        );
        await drainAsync(tester, settle: false);
        expect(heartIcon('heart'), findsOneWidget);

        await tester.tap(find.byKey(const Key('ascent-detail-like-button')));
        // ONE frame, no clock advance: the flip cannot have waited on the write,
        // which is still gated below.
        await tester.pump();
        expect(heartIcon('heart_fill'), findsOneWidget);
        expect(heartIcon('heart'), findsNothing);
        expect(likeGate.isCompleted, isFalse);

        // And it is instant feedback, not a spinner: a like that spins reads as
        // broken. Pump well past the reveal delay to prove none appears.
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.byKey(MasiLoadingIndicator.spinnerKey), findsNothing);
        expect(heartIcon('heart_fill'), findsOneWidget);

        likeGate.complete();
        await drainAsync(tester, settle: false);
        // Still liked once the provider has caught up — the override handed
        // over cleanly rather than flickering back.
        expect(heartIcon('heart_fill'), findsOneWidget);
      },
    );

    testWidgets('a double-tapped Post writes ONE comment, not two', (
      tester,
    ) async {
      final seeded = await seedSharedAscent(tester);

      await tester.pumpWidget(
        wrap(seeded.container, AscentDetailScreen(ascentId: seeded.ascentId)),
      );
      await drainAsync(tester, settle: false);

      await tester.enterText(
        find.byKey(const Key('ascent-detail-comment-field')),
        'Nice send!',
      );
      // The submit button is rebuilt (enabled) off the controller — it needs a
      // frame before it can be usefully tapped.
      await tester.pump();

      final submit = find.byKey(const Key('ascent-detail-comment-submit'));
      await tester.tap(submit);
      // The impatient second tap, before any frame lets the button repaint
      // itself disabled — exactly the case the in-flight guard exists for.
      await tester.tap(submit);
      await drainAsync(tester, settle: false);

      final comments = await tester.runAsync(
        () => seeded.container
            .read(commentsRepositoryProvider)
            .commentsForAscent(seeded.ascentId),
      );
      expect(comments, hasLength(1));
    });
  });
}
