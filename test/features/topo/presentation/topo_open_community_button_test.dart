// Tests for the topo canvas's "open community page" shortcut
// (`topo-open-community`) — the navigation requested in "add a navigation
// shortcut from the topo to the feed version, so if one opens the topo they
// can easily navigate to the info rich feed version".
//
// The assertion that matters most: a PRIVATE, never-published topo has no
// `CommunityTopoDetailScreen` to open at all, so the button must be ABSENT
// there (a visible-but-dead button would be the actual bug) — and present
// for a topo that HAS been published (`visibility == 'shared'`, the real
// backing condition `community_repository.dart`'s `sharedTopos` query
// requires). See `wallVisibilityProvider`'s doc (library_providers.dart) and
// `_topTrailingActions`'s `topo-open-community` block
// (topo_canvas_screen.dart) for why this is read straight off the wall
// (unscoped by owner) rather than through `TopoRef.visibility`.

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

/// Creates a real in-memory DB + [ProviderContainer] + a persisted
/// Area/Sector/Wall, mirroring the harness pattern used throughout this
/// directory (e.g. `topo_canvas_edit_location_test.dart`'s `_seedWall`).
/// [shared] publishes the wall (`visibility = 'shared'`) via the same
/// `publishTopo` write path the Topos-home "Publish" menu item uses, when
/// `true`; otherwise the wall stays at its `'private'` default.
Future<({AppDatabase db, ProviderContainer container, String wallId})>
_seedWall({bool shared = false}) async {
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
  return (db: db, container: container, wallId: wall.id);
}

/// Wraps [screen] in a real (minimal) [GoRouter] so `topo-open-community`'s
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

void main() {
  group('topo-open-community', () {
    testWidgets(
      'ABSENT on a private (never-published) topo — no feed version exists '
      'to open, so this must never render as a dead button',
      (tester) async {
        final seeded = await _seedWall();
        addTearDown(seeded.db.close);
        addTearDown(seeded.container.dispose);

        await tester.pumpWidget(
          _wrap(seeded.container, TopoCanvasScreen(wallId: seeded.wallId)),
        );
        await tester.pumpAndSettle();

        expect(
          find.byKey(const Key('topo-open-community')),
          findsNothing,
          reason:
              'a private topo has no CommunityTopoDetailScreen to open — '
              'the shortcut must be absent, not merely disabled',
        );
      },
    );

    testWidgets(
      'PRESENT on a shared (published) topo, in view mode',
      (tester) async {
        final seeded = await _seedWall(shared: true);
        addTearDown(seeded.db.close);
        addTearDown(seeded.container.dispose);

        await tester.pumpWidget(
          _wrap(seeded.container, TopoCanvasScreen(wallId: seeded.wallId)),
        );
        await tester.pumpAndSettle();

        expect(
          seeded.container.read(drawControllerProvider(seeded.wallId)).mode,
          DrawMode.view,
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
      'PRESENT even in readOnly mode, on a shared topo — the shortcut is a '
      'non-mutating navigation, not an editing affordance',
      (tester) async {
        final seeded = await _seedWall(shared: true);
        addTearDown(seeded.db.close);
        addTearDown(seeded.container.dispose);

        await tester.pumpWidget(
          _wrap(
            seeded.container,
            TopoCanvasScreen(wallId: seeded.wallId, readOnly: true),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('topo-open-community')), findsOneWidget);
      },
    );

    testWidgets(
      'READ-ONLY canvas: exposes "More about this topo" EXACTLY ONCE, and it '
      'pushes the community detail route for THIS wall',
      (tester) async {
        // The read-only canvas is where this matters most: it is the surface
        // a community/nearby tap lands on, and ten of the sixteen community
        // features (comments, likes, ascents, grade consensus, verification,
        // hazards, history…) hang off the page this pushes.
        //
        // "exactly once" is the assertion with teeth. The affordance already
        // existed here (commit 772f78c, keyed `topo-open-community`, then
        // titled "See comments and ascents"); this only renames it to the
        // owner's own words. A SECOND labelled copy — e.g. the same item
        // added again in an overflow menu — would be a duplicate entry point
        // into one screen, which is worse than the discoverability problem it
        // would be trying to fix.
        final seeded = await _seedWall(shared: true);
        addTearDown(seeded.db.close);
        addTearDown(seeded.container.dispose);

        await tester.pumpWidget(
          _wrap(
            seeded.container,
            TopoCanvasScreen(wallId: seeded.wallId, readOnly: true),
          ),
        );
        await tester.pumpAndSettle();

        expect(
          find.byTooltip('More about this topo'),
          findsOneWidget,
          reason:
              'the read-only canvas must offer the community page under the '
              "owner's chosen wording — and only one of it",
        );
        expect(
          find.byKey(const Key('topo-open-community')),
          findsOneWidget,
          reason:
              'one keyed entry point, not two: nothing may duplicate the '
              'pre-existing shortcut',
        );

        await tester.tap(find.byTooltip('More about this topo'));
        await tester.pumpAndSettle();

        expect(
          find.text('community-topo-${seeded.wallId}'),
          findsOneWidget,
          reason:
              'it must push /community/topo/:wallId for THIS wall, from the '
              'read-only canvas too',
        );
      },
    );

    testWidgets(
      'ABSENT in draw mode even on a shared topo — stays out of the '
      'drawing-tools cluster, alongside the locate-on-map glyph it sits '
      'next to',
      (tester) async {
        final seeded = await _seedWall(shared: true);
        addTearDown(seeded.db.close);
        addTearDown(seeded.container.dispose);

        await tester.pumpWidget(
          _wrap(seeded.container, TopoCanvasScreen(wallId: seeded.wallId)),
        );
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('topo-open-community')), findsOneWidget);

        await tester.tap(find.byKey(const Key('topo-mode-toggle')));
        await tester.pumpAndSettle();
        expect(
          seeded.container.read(drawControllerProvider(seeded.wallId)).mode,
          DrawMode.draw,
        );

        expect(
          find.byKey(const Key('topo-open-community')),
          findsNothing,
          reason:
              'draw mode is the drawing-tools cluster — this "jump '
              'elsewhere" affordance must not compete with it',
        );
      },
    );

    testWidgets(
      'tapping it navigates to /community/topo/<the CORRECT wallId>',
      (tester) async {
        final seeded = await _seedWall(shared: true);
        addTearDown(seeded.db.close);
        addTearDown(seeded.container.dispose);

        await tester.pumpWidget(
          _wrap(seeded.container, TopoCanvasScreen(wallId: seeded.wallId)),
        );
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
  });
}
