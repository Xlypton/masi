// Tests for the topo canvas's "open community page" shortcut — the
// navigation requested in "add a navigation shortcut from the topo to the
// feed version, so if one opens the topo they can easily navigate to the
// info rich feed version".
//
// It MOVED (user request, 2026-08-11: "the chat box icon we should remove
// and add figure out a better way to reach the feed version, like swipe up
// from the bottom"). It used to be a speech-bubble glyph in the top chrome;
// it is now reached from the bottom of the screen, in three forms that all
// go to the same place:
//   * `topo-open-community` — the "Comments & ascents" footer row inside the
//     expanded route panel (the discoverable one);
//   * `topo-open-community-chip` — the standalone pill shown in the panel's
//     slot when the photo has no routes yet, so the entry point does not
//     vanish with the route list;
//   * an upward drag on `topo-route-legend-handle` (the fast one).
//
// The assertion that matters most is unchanged: a PRIVATE, never-published
// topo has no `CommunityTopoDetailScreen` to open at all, so none of these
// may render there (a visible-but-dead affordance would be the actual bug) —
// and they appear for a topo that HAS been published (`visibility ==
// 'shared'`, the real backing condition `community_repository.dart`'s
// `sharedTopos` query requires). See `wallVisibilityProvider`'s doc
// (library_providers.dart) and `TopoCanvasBody.onOpenCommunity`
// (topo_canvas_screen.dart).

import 'package:masi/app/theme.dart';
import 'package:masi/core/db/app_database.dart';
import 'package:masi/core/db/database_provider.dart';
import 'package:masi/features/library/application/library_providers.dart';
import 'package:masi/features/topo/application/draw_controller.dart';
import 'package:masi/features/topo/presentation/topo_canvas_screen.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';

const _imageSize = Size(400, 300);

/// Creates a real in-memory DB + [ProviderContainer] + a persisted
/// Area/Sector/Wall WITH an attached photo (and, by default, one committed
/// route), mirroring the harness pattern used throughout this directory.
///
/// The photo is what makes this different from the pre-move version of this
/// file, which seeded a photo-less wall: the affordances under test now live
/// inside `TopoCanvasBody`, and `TopoCanvasScreen` only builds that once a
/// photo is selected (a photo-less wall renders `topo-empty-state` instead).
/// [TopoCanvasScreen.debugInitialImageSize] then supplies the natural size so
/// no real codec decode is driven — see that field's doc and the project
/// CLAUDE.md's "never drive a real image-codec decode in widget tests".
///
/// [shared] publishes the wall (`visibility = 'shared'`) via the same
/// `publishTopo` write path the Topos-home "Publish" menu item uses.
Future<({AppDatabase db, ProviderContainer container, String wallId})>
_seedWall(
  WidgetTester tester, {
  bool shared = false,
  bool withRoute = true,
}) async {
  final db = AppDatabase(NativeDatabase.memory());
  final container = ProviderContainer(
    overrides: [
      appDatabaseProvider.overrideWithValue(db),
      nowMsProvider.overrideWithValue(() => 1000),
    ],
  );
  final crud = container.read(libraryCrudRepositoryProvider);
  final area = await crud.createArea('Area');
  final sector = await crud.createSector(area.id, 'Sector');
  final wall = await crud.createWall(sector.id, 'Wall');
  if (shared) {
    await crud.publishTopo(wall.id);
  }
  // FIX #6 (autoDispose pending-timer gotcha, see route_legend_gap_test.dart's
  // `_seedRoutes`): keep this family member alive for the whole test via a
  // permanent listener -- otherwise every bare `container.read(...)` below
  // (before any widget is pumped) schedules an autoDispose teardown
  // `Timer(Duration.zero, ...)` that only fires on a duration-based
  // `tester.pump`, tripping flutter_test's `!timersPending` invariant.
  container.listen(drawControllerProvider(wall.id), (_, _) {});
  late String photoId;
  await tester.runAsync(() async {
    photoId = await crud.attachPhotoToWall(
      wall.id,
      XFile('/tmp/open-community-test-photo.jpg'),
      400,
      300,
    );
  });

  if (withRoute) {
    final notifier = container.read(drawControllerProvider(wall.id).notifier);
    await notifier.loadForWall(wall.id, photoId);
    notifier.addPoint(const Offset(0.2, 0.3));
    notifier.addPoint(const Offset(0.7, 0.6));
    await notifier.commitRoute();
  }

  return (db: db, container: container, wallId: wall.id);
}

/// Wraps [screen] in a real (minimal) [GoRouter] so the community affordance's
/// `context.push('/community/topo/:wallId')` resolves against a real router
/// instead of throwing for lack of one — mirrors
/// `topo_canvas_edit_location_test.dart`'s own `_wrap`, with a keyed
/// `/community/topo/:wallId` placeholder (never the real
/// `CommunityTopoDetailScreen`, which needs a live Supabase-backed social
/// surface this test has no business standing up) that echoes the routed
/// wallId back so a test can confirm navigation landed on the CORRECT wall,
/// not just "some" navigation happened.
Widget _wrap(ProviderContainer container, Widget screen) {
  final router = GoRouter(
    initialLocation: '/',
    routes: [
      GoRoute(path: '/', builder: (context, state) => screen),
      GoRoute(
        path: '/community/topo/:wallId',
        builder: (context, state) => Text(
          'community-topo-${state.pathParameters['wallId']}',
          key: const Key('community-topo-placeholder'),
        ),
      ),
    ],
  );
  return UncontrolledProviderScope(
    container: container,
    child: MaterialApp.router(theme: MasiTheme.light, routerConfig: router),
  );
}

Widget _canvas(String wallId, {bool readOnly = false}) => TopoCanvasScreen(
  wallId: wallId,
  readOnly: readOnly,
  debugInitialImageSize: _imageSize,
);

void main() {
  group('the canvas → community shortcut', () {
    testWidgets(
      'ABSENT on a private (never-published) topo — no feed version exists '
      'to open, so this must never render as a dead affordance',
      (tester) async {
        final seeded = await _seedWall(tester);
        addTearDown(seeded.db.close);
        addTearDown(seeded.container.dispose);

        await tester.pumpWidget(_wrap(seeded.container, _canvas(seeded.wallId)));
        await tester.pumpAndSettle();

        expect(
          find.byKey(const Key('topo-open-community')),
          findsNothing,
          reason:
              'a private topo has no CommunityTopoDetailScreen to open — '
              'the shortcut must be absent, not merely disabled',
        );
        expect(
          find.byKey(const Key('topo-open-community-chip')),
          findsNothing,
        );
      },
    );

    testWidgets(
      'PRESENT as the route panel\'s footer row on a shared (published) topo, '
      'in view mode',
      (tester) async {
        final seeded = await _seedWall(tester, shared: true);
        addTearDown(seeded.db.close);
        addTearDown(seeded.container.dispose);

        await tester.pumpWidget(_wrap(seeded.container, _canvas(seeded.wallId)));
        await tester.pumpAndSettle();

        expect(
          seeded.container.read(drawControllerProvider(seeded.wallId)).mode,
          DrawMode.view,
        );
        expect(
          find.byKey(const Key('topo-route-legend-overlay')),
          findsOneWidget,
          reason: 'view mode opens with the route panel expanded, which is '
              'where the footer row lives',
        );
        expect(
          find.byKey(const Key('topo-open-community')),
          findsOneWidget,
          reason:
              'this wall has been published (visibility == shared), so a '
              'feed version genuinely exists — the shortcut must be '
              'reachable',
        );
      },
    );

    testWidgets(
      'PRESENT as a standalone chip when the photo has no routes yet — the '
      'entry point must not vanish with the route list',
      (tester) async {
        final seeded = await _seedWall(tester, shared: true, withRoute: false);
        addTearDown(seeded.db.close);
        addTearDown(seeded.container.dispose);

        await tester.pumpWidget(_wrap(seeded.container, _canvas(seeded.wallId)));
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('topo-route-legend-overlay')), findsNothing);
        expect(find.byKey(const Key('topo-open-community-chip')), findsOneWidget);
      },
    );

    testWidgets(
      'PRESENT even in readOnly mode, on a shared topo — the shortcut is a '
      'non-mutating navigation, not an editing affordance',
      (tester) async {
        final seeded = await _seedWall(tester, shared: true);
        addTearDown(seeded.db.close);
        addTearDown(seeded.container.dispose);

        await tester.pumpWidget(
          _wrap(seeded.container, _canvas(seeded.wallId, readOnly: true)),
        );
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('topo-open-community')), findsOneWidget);
      },
    );

    testWidgets(
      'ABSENT from the top chrome entirely — the speech-bubble glyph that '
      'used to sit beside the mode toggle is gone, not merely relocated '
      'within that row',
      (tester) async {
        final seeded = await _seedWall(tester, shared: true);
        addTearDown(seeded.db.close);
        addTearDown(seeded.container.dispose);

        await tester.pumpWidget(_wrap(seeded.container, _canvas(seeded.wallId)));
        await tester.pumpAndSettle();

        expect(find.byTooltip('See comments and ascents'), findsNothing);
      },
    );

    testWidgets(
      'tapping the footer row navigates to /community/topo/<the CORRECT '
      'wallId>',
      (tester) async {
        final seeded = await _seedWall(tester, shared: true);
        addTearDown(seeded.db.close);
        addTearDown(seeded.container.dispose);

        await tester.pumpWidget(_wrap(seeded.container, _canvas(seeded.wallId)));
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(const Key('topo-open-community')));
        await tester.pumpAndSettle();

        expect(
          find.byKey(const Key('community-topo-placeholder')),
          findsOneWidget,
          reason: 'tapping the shortcut must navigate via the real named '
              '/community/topo/:wallId route',
        );
        expect(
          find.text('community-topo-${seeded.wallId}'),
          findsOneWidget,
          reason:
              'the routed wallId must be THIS wall\'s id — a hardcoded or '
              'mismatched id would silently open the wrong topo\'s feed',
        );
      },
    );

    testWidgets(
      'dragging the route panel\'s handle UPWARD opens the same destination — '
      'the "keep pulling for more detail" gesture',
      (tester) async {
        final seeded = await _seedWall(tester, shared: true);
        addTearDown(seeded.db.close);
        addTearDown(seeded.container.dispose);

        await tester.pumpWidget(_wrap(seeded.container, _canvas(seeded.wallId)));
        await tester.pumpAndSettle();

        await tester.fling(
          find.byKey(const Key('topo-route-legend-handle')),
          const Offset(0, -120),
          1000,
        );
        await tester.pumpAndSettle();

        expect(find.text('community-topo-${seeded.wallId}'), findsOneWidget);
      },
    );
  });
}
