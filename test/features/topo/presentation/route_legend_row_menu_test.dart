// Every per-route action lives behind one `⋯` menu on the row (user request,
// 2026-08-12: "the route quick actions like hide and delete log ascent should
// be in a longpress menu like the 3dot menu of the topos").
//
// What the row carried before: a beta-video globe, a log-ascent tick, a hide
// eye and a delete bin — up to four targets in the right-hand third of a
// dense row, two of which (hide/delete) needed an explicit 44pt floor and a
// gutter between them precisely BECAUSE they were adjacent, one reversible
// and one destructive.
//
// The properties worth pinning, in rough order of how expensive getting them
// wrong would be:
//   * delete confirms before destroying;
//   * a read-only viewer is offered no owner actions, and gets no menu at all
//     when that leaves nothing to show;
//   * edit and log-ascent never appear together — they belong to opposite
//     modes, and the canvas is what decides which;
//   * long-press opens the same menu as the button.

import 'package:masi/app/theme.dart';
import 'package:masi/core/db/app_database.dart';
import 'package:masi/core/db/database_provider.dart';
import 'package:masi/features/library/application/library_providers.dart';
import 'package:masi/features/topo/application/draw_controller.dart';
import 'package:masi/features/topo/data/route_repository.dart';
import 'package:masi/features/topo/domain/topo_route.dart';
import 'package:masi/features/topo/presentation/route_legend.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';

const _testWallId = 'test-wall';

Future<ProviderContainer> _seedOneRoute(
  WidgetTester tester, {
  String? betaVideoUrl,
}) async {
  final db = AppDatabase(NativeDatabase.memory());
  addTearDown(db.close);
  final container = ProviderContainer(
    overrides: [
      appDatabaseProvider.overrideWithValue(db),
      nowMsProvider.overrideWithValue(() => 1000),
    ],
  );
  addTearDown(container.dispose);
  // FIX #6 (autoDispose pending-timer gotcha) — see route_legend_gap_test.dart.
  container.listen(drawControllerProvider(_testWallId), (_, _) {});

  final crud = container.read(libraryCrudRepositoryProvider);
  final area = await crud.createArea('Area');
  final sector = await crud.createSector(area.id, 'Sector');
  final wall = await crud.createWall(sector.id, 'Wall');
  late String photoId;
  await tester.runAsync(() async {
    photoId = await crud.attachPhotoToWall(
      wall.id,
      XFile('/tmp/row-menu-test.jpg'),
      400,
      300,
    );
  });
  await RouteRepository(db, nowMs: () => 1000).upsertRoute(
    wall.id,
    photoId,
    TopoRoute(
      id: 1,
      number: 1,
      points: const [Offset(0.1, 0.1), Offset(0.2, 0.2)],
      name: 'Balfal',
      betaVideoUrl: betaVideoUrl,
    ),
  );
  await container
      .read(drawControllerProvider(_testWallId).notifier)
      .loadForWall(wall.id, photoId);
  return container;
}

Future<void> _pumpLegend(
  WidgetTester tester,
  ProviderContainer container, {
  bool readOnly = false,
  void Function(int)? onEditRoute,
  void Function(int)? onLogAscent,
}) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: MasiTheme.light,
        home: Scaffold(
          body: RouteLegend(
            wallId: _testWallId,
            readOnly: readOnly,
            onEditRoute: onEditRoute,
            onLogAscent: onLogAscent,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('the row shows ONE trailing control — the menu — not a cluster', (
    tester,
  ) async {
    final container = await _seedOneRoute(tester);
    await _pumpLegend(tester, container);

    expect(find.byKey(const Key('topo-route-menu-1')), findsOneWidget);
    // None of the four old inline glyphs is on the row any more; they exist
    // only once the sheet is open.
    expect(find.byKey(const Key('topo-route-visibility-1')), findsNothing);
    expect(find.byKey(const Key('topo-route-delete-1')), findsNothing);
  });

  testWidgets('long-pressing the row opens the same menu as the button', (
    tester,
  ) async {
    final container = await _seedOneRoute(tester);
    await _pumpLegend(tester, container);

    await tester.longPress(find.byKey(const Key('topo-route-legend-item-1')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('topo-route-visibility-1')), findsOneWidget);
    expect(find.byKey(const Key('topo-route-delete-1')), findsOneWidget);
  });

  testWidgets(
    'Delete asks first, and abandoning the confirmation keeps the route',
    (tester) async {
      final container = await _seedOneRoute(tester);
      await _pumpLegend(tester, container);

      await tester.tap(find.byKey(const Key('topo-route-menu-1')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('topo-route-delete-1')));
      await tester.pumpAndSettle();

      // The route is still there — the tap opened a confirmation, it did not
      // delete. A menu row is one tap from destroying a drawn line, and there
      // is no undo.
      expect(
        container.read(drawControllerProvider(_testWallId)).routes,
        hasLength(1),
      );
      expect(
        find.byKey(const Key('topo-route-delete-confirm-1')),
        findsOneWidget,
      );

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(
        container.read(drawControllerProvider(_testWallId)).routes,
        hasLength(1),
        reason: 'backing out of the confirmation must keep the route',
      );

      // Confirming does delete it.
      await tester.tap(find.byKey(const Key('topo-route-menu-1')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('topo-route-delete-1')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('topo-route-delete-confirm-1')));
      await tester.pumpAndSettle();
      expect(
        container.read(drawControllerProvider(_testWallId)).routes,
        isEmpty,
      );
    },
  );

  testWidgets(
    'edit and log-ascent never appear together — they belong to opposite '
    'modes, and the canvas decides which by supplying one callback or the '
    'other',
    (tester) async {
      final container = await _seedOneRoute(tester);

      // Draw mode's shape: edit, no log-ascent.
      await _pumpLegend(tester, container, onEditRoute: (_) {});
      await tester.tap(find.byKey(const Key('topo-route-menu-1')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('topo-route-edit-1')), findsOneWidget);
      expect(find.byKey(const Key('topo-log-ascent-1')), findsNothing);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      // View mode's shape: log-ascent, no edit.
      await _pumpLegend(tester, container, onLogAscent: (_) {});
      await tester.tap(find.byKey(const Key('topo-route-menu-1')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('topo-log-ascent-1')), findsOneWidget);
      expect(find.byKey(const Key('topo-route-edit-1')), findsNothing);
    },
  );

  testWidgets(
    'a read-only viewer gets NO menu when the route has nothing to offer '
    'them — an empty sheet is worse than no button',
    (tester) async {
      final container = await _seedOneRoute(tester);
      await _pumpLegend(tester, container, readOnly: true);

      expect(find.byKey(const Key('topo-route-menu-1')), findsNothing);
    },
  );

  testWidgets(
    'a read-only viewer DOES get a menu when the route has a beta video — '
    'and it carries only that, never the owner\'s hide/delete',
    (tester) async {
      final container = await _seedOneRoute(
        tester,
        betaVideoUrl: 'https://example.com/beta',
      );
      await _pumpLegend(tester, container, readOnly: true);

      await tester.tap(find.byKey(const Key('topo-route-menu-1')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('route-beta-1')), findsOneWidget);
      expect(find.byKey(const Key('topo-route-visibility-1')), findsNothing);
      expect(find.byKey(const Key('topo-route-delete-1')), findsNothing);
    },
  );

  testWidgets('Hide toggles visibility and the label follows the state', (
    tester,
  ) async {
    final container = await _seedOneRoute(tester);
    await _pumpLegend(tester, container);

    await tester.tap(find.byKey(const Key('topo-route-menu-1')));
    await tester.pumpAndSettle();
    expect(find.text('Hide route'), findsOneWidget);
    await tester.tap(find.byKey(const Key('topo-route-visibility-1')));
    await tester.pumpAndSettle();

    expect(
      container.read(drawControllerProvider(_testWallId)).routes.single.visible,
      isFalse,
    );

    // Reopening offers the inverse, so the row can be brought back.
    await tester.tap(find.byKey(const Key('topo-route-menu-1')));
    await tester.pumpAndSettle();
    expect(find.text('Show route'), findsOneWidget);
  });
}
