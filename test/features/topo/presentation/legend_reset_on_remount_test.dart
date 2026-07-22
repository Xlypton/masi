// Regression test for the "stale collapsed legend leaks across walls" bug.
//
// `legendExpandedProvider` (route_legend.dart) is an app-lifetime global,
// exactly like `drawControllerProvider`. The ONLY reset previously was the
// transition-gated `ref.listen<DrawMode>(...)` in
// `_TopoCanvasScreenState.build()`, which calls `setForMode` only when
// `DrawState.mode` actually CHANGES. That leaks stale state:
//
//   1. Wall A opens in view mode (legend expanded, the default). The user
//      manually collapses it via the header chevron (or, here,
//      `legendExpandedProvider.notifier.toggle()`), leaving it collapsed
//      while STILL in view mode — no mode transition occurs.
//   2. The user navigates to wall B. `_TopoCanvasScreenState.initState`
//      unconditionally calls `_resetToViewMode()`, which forces
//      `DrawState.mode` back to `DrawMode.view` — but it was ALREADY view,
//      so `ref.listen`'s `.select((s) => s.mode)` sees no change and never
//      fires `setForMode`. The legend wrongly stays collapsed on the fresh
//      wall.
//
// The fix makes `_resetToViewMode()` itself unconditionally call
// `legendExpandedProvider.notifier.setForMode(DrawMode.view)`, mirroring how
// it unconditionally re-asserts `DrawMode.view` — so a fresh mount always
// restores the expanded default regardless of whether mode actually
// transitioned.
//
// This test drives the REAL `TopoCanvasScreen` (not the `TopoCanvasBody`
// harness), because the bug lives in `_TopoCanvasScreenState.initState` /
// `_resetToViewMode`, which only runs on the real screen. Seeding mirrors
// `legend_expand_collapse_test.dart`'s `_seedWallWithPhotoAndRoute` and
// `topo_canvas_zoom_overlay_test.dart` (real in-memory DB + Area/Sector/Wall
// + a committed route via `DrawController`).
import 'package:masi/app/theme.dart';
import 'package:masi/core/db/app_database.dart';
import 'package:masi/core/db/database_provider.dart';
import 'package:masi/features/library/application/library_providers.dart';
import 'package:masi/features/topo/application/draw_controller.dart';
import 'package:masi/features/topo/presentation/route_legend.dart';
import 'package:masi/features/topo/presentation/topo_canvas_screen.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';

const _overlayKey = Key('topo-route-legend-overlay');
const _chipKey = Key('topo-route-legend-chip');

/// Creates a real in-memory DB + ProviderContainer + a persisted
/// Area/Sector/Wall, attaches a photo, and commits one route via
/// [DrawController] — mirrors
/// `legend_expand_collapse_test.dart:_seedWallWithPhotoAndRoute`.
Future<({AppDatabase db, ProviderContainer container, String wallId})>
_seedWallWithPhotoAndRoute(WidgetTester tester) async {
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
  late String photoId;
  await tester.runAsync(() async {
    photoId = await crud.attachPhotoToWall(
      wall.id,
      XFile('/tmp/legend-reset-on-remount-photo.jpg'),
      400,
      300,
    );
  });

  final notifier = container.read(drawControllerProvider(wall.id).notifier);
  await notifier.loadForWall(wall.id, photoId);
  notifier.addPoint(const Offset(0.1, 0.1));
  notifier.addPoint(const Offset(0.2, 0.2));
  await notifier.commitRoute();

  return (db: db, container: container, wallId: wall.id);
}

void main() {
  testWidgets(
    'a manual collapse left over in view mode does not survive a fresh '
    'screen remount with no draw-mode transition (_resetToViewMode must '
    'unconditionally restore the expanded default)',
    (tester) async {
      final seeded = await _seedWallWithPhotoAndRoute(tester);
      addTearDown(seeded.db.close);
      addTearDown(seeded.container.dispose);

      Widget buildScreen(Key key) => UncontrolledProviderScope(
        container: seeded.container,
        child: MaterialApp(
          theme: MasiTheme.light,
          home: TopoCanvasScreen(
            key: key,
            wallId: seeded.wallId,
            debugInitialImageSize: const Size(400, 300),
          ),
        ),
      );

      // --- Fresh mount #1: sanity — view mode, expanded by default. ---
      await tester.pumpWidget(buildScreen(const Key('screen-1')));
      await tester.pumpAndSettle();

      expect(
        seeded.container.read(drawControllerProvider(seeded.wallId)).mode,
        DrawMode.view,
        reason: 'sanity: the real screen opens in view mode',
      );
      expect(
        find.byKey(_overlayKey),
        findsOneWidget,
        reason: 'sanity: fresh mount + view mode must show the expanded card',
      );
      expect(find.byKey(_chipKey), findsNothing);

      // --- Simulate the stale manual collapse, entirely within view mode. ---
      // No draw-mode transition happens here — this is the scenario the
      // transition-gated `ref.listen` cannot see.
      seeded.container.read(legendExpandedProvider(seeded.wallId).notifier).toggle();
      await tester.pump();

      expect(
        seeded.container.read(drawControllerProvider(seeded.wallId)).mode,
        DrawMode.view,
        reason:
            'sanity: still view mode — the collapse was a manual toggle, '
            'not a mode change',
      );
      expect(
        find.byKey(_chipKey),
        findsOneWidget,
        reason: 'manual toggle collapses the legend to the chip',
      );
      expect(find.byKey(_overlayKey), findsNothing);

      // --- Remount a fresh screen instance with NO mode transition. ---
      // A distinct Key forces Flutter to dispose the old State and create a
      // brand-new one (rather than reusing it via didUpdateWidget), just
      // like navigating from wall A to wall B does in the real app —
      // running `initState`/`_resetToViewMode()` again while
      // `DrawState.mode` is ALREADY `DrawMode.view` (unchanged), which is
      // exactly the case the old transition-gated listener missed.
      await tester.pumpWidget(buildScreen(const Key('screen-2')));
      await tester.pumpAndSettle();

      expect(
        seeded.container.read(drawControllerProvider(seeded.wallId)).mode,
        DrawMode.view,
        reason:
            'sanity: mode never transitioned away from view, so the '
            'ref.listen in build() alone could not have fired',
      );
      expect(
        find.byKey(_overlayKey),
        findsOneWidget,
        reason:
            '_resetToViewMode() must unconditionally restore the expanded '
            'legend default on every fresh mount, not just on an actual '
            'draw-mode transition — otherwise the stale manual collapse '
            'from the previous wall leaks into this fresh one',
      );
      expect(
        find.byKey(_chipKey),
        findsNothing,
        reason: 'the collapsed chip must not survive a fresh remount',
      );
    },
  );
}
