// "This is climb 3, drawn here."
//
// The data model has carried a climb's second face since v16 — a `route_lines`
// row holding this photo's drawing of a climb whose home is another one — and
// nothing in the UI could ever ask for it. The only route that could claim a
// drawn line was one already visible on THIS photo, and a climb drawn on
// another face is by definition not visible here. So the two readings of a
// fresh line, "a new climb" and "the one I already logged, from over here",
// collapsed into the first.
//
// What is pinned here is the affordance and its scope: it appears exactly when
// the question can arise, and never otherwise.

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:masi/app/theme.dart';
import 'package:masi/core/db/app_database.dart';
import 'package:masi/core/db/database_provider.dart';
import 'package:masi/features/library/application/library_providers.dart';
import 'package:masi/features/topo/application/draw_controller.dart';
import 'package:masi/features/topo/domain/topo_route.dart';
import 'package:masi/features/topo/presentation/topo_canvas_screen.dart';

void main() {
  Future<({AppDatabase db, ProviderContainer container, String wallId})>
  seedWall() async {
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
    return (db: db, container: container, wallId: wall.id);
  }

  Future<void> seedPhoto(AppDatabase db, String wallId, String photoId) => db
      .into(db.photos)
      .insert(
        PhotosCompanion.insert(
          id: photoId,
          createdAt: 1000,
          updatedAt: 1000,
          wallId: wallId,
          localPath: '/tmp/$photoId.jpg',
          // Deliberately not 'original': the screen must not reach for a real
          // image decode, which cannot be driven under fake time.
          kind: 'other',
          width: 100,
          height: 100,
        ),
      );

  Future<void> pumpCanvas(
    WidgetTester tester,
    ProviderContainer container,
    String wallId,
  ) async {
    // Phone-shaped, always: this control carries a WORD in a cluster of
    // glyphs, and whether the five of them fit is a question only a real
    // phone width can answer.
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: MasiTheme.light,
          home: TopoCanvasScreen(wallId: wallId),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('the line can be given to a climb that lives on another face, '
      'and it keeps that climb\'s number, name and grade', (tester) async {
    final seeded = await seedWall();
    addTearDown(seeded.db.close);
    addTearDown(seeded.container.dispose);
    await seedPhoto(seeded.db, seeded.wallId, 'photo-1');
    await seedPhoto(seeded.db, seeded.wallId, 'photo-2');

    // Climb 1 exists, drawn on the FIRST face.
    await seeded.container
        .read(routeRepositoryProvider)
        .upsertRoute(
          seeded.wallId,
          'photo-1',
          const TopoRoute(
            id: 1,
            number: 1,
            points: [Offset(0.1, 0.1), Offset(0.2, 0.9)],
            name: 'Arete',
            gradeRaw: '6a',
          ),
        );

    final notifier = seeded.container.read(
      drawControllerProvider(seeded.wallId).notifier,
    );
    await pumpCanvas(tester, seeded.container, seeded.wallId);
    // AFTER the first frame: the screen binds its own photo on mount, and a
    // binding made before that is replaced by it.
    await notifier.loadForWall(seeded.wallId, 'photo-2');
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('topo-mode-toggle')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('topo-link-climb-button')),
      findsNothing,
      reason: 'there is no line yet, so there is nothing to say this about',
    );

    notifier.addPoint(const Offset(0.5, 0.1));
    notifier.addPoint(const Offset(0.6, 0.9));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('topo-link-climb-button')),
      findsOneWidget,
      reason:
          'a line, and a climb on the wall that is not on this face — and '
          'it has to appear on the frame the line becomes one, not on the '
          'next unrelated rebuild',
    );
    expect(
      find.text('Same climb, seen from here'),
      findsOneWidget,
      reason:
          'a bare glyph for a thing no app has done before says nothing '
          '— this one was asked for again after it shipped',
    );

    await tester.tap(find.byKey(const Key('topo-link-climb-button')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('topo-link-climb-1')),
      findsOneWidget,
      reason: 'the climb is named by its own number, not by a list position',
    );

    await tester.tap(find.byKey(const Key('topo-link-climb-1')));
    await tester.pumpAndSettle();

    final state = seeded.container.read(drawControllerProvider(seeded.wallId));
    expect(state.currentPoints, isEmpty, reason: 'the draft was consumed');
    expect(state.routes, hasLength(1));
    expect(state.routes.single.number, 1);
    expect(state.routes.single.name, 'Arete');
    expect(state.routes.single.gradeRaw, '6a');
    expect(state.mode, DrawMode.view, reason: 'the line is saved and named');

    final climbs = await (seeded.db.select(
      seeded.db.routes,
    )..where((t) => t.deletedAt.isNull())).get();
    expect(climbs, hasLength(1), reason: 'no second climb was invented');
    expect(climbs.single.photoId, 'photo-1', reason: 'its home is unchanged');

    final lines = await seeded.db.select(seeded.db.routeLines).get();
    expect(lines, hasLength(1));
    expect(lines.single.photoId, 'photo-2');

    expect(find.byKey(const Key('topo-link-climb-saved')), findsOneWidget);
  });

  testWidgets('a wall whose every climb is already on this face offers '
      'nothing to link to', (tester) async {
    final seeded = await seedWall();
    addTearDown(seeded.db.close);
    addTearDown(seeded.container.dispose);
    await seedPhoto(seeded.db, seeded.wallId, 'photo-1');

    await seeded.container
        .read(routeRepositoryProvider)
        .upsertRoute(
          seeded.wallId,
          'photo-1',
          const TopoRoute(
            id: 1,
            number: 1,
            points: [Offset(0.1, 0.1), Offset(0.2, 0.9)],
            name: 'Arete',
          ),
        );

    final notifier = seeded.container.read(
      drawControllerProvider(seeded.wallId).notifier,
    );
    await pumpCanvas(tester, seeded.container, seeded.wallId);
    await notifier.loadForWall(seeded.wallId, 'photo-1');
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('topo-mode-toggle')));
    await tester.pumpAndSettle();
    notifier.addPoint(const Offset(0.5, 0.1));
    notifier.addPoint(const Offset(0.6, 0.9));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('topo-link-climb-button')),
      findsNothing,
      reason:
          'the only climb here is already on this photo, and a second '
          'line for one photo is a write the database refuses',
    );
    expect(
      find.byKey(const Key('topo-commit-button')),
      findsOneWidget,
      reason: 'the ordinary save is still there — this line is a new climb',
    );
  });

  /// Twice now the control above the tools has gone unfound, so the SAVE asks
  /// as well — on a rock that has climbs on its other photos, which is the
  /// only place the question means anything.
  testWidgets('saving a line on a face of a rock that has climbs elsewhere '
      'asks which it is, once', (tester) async {
    final seeded = await seedWall();
    addTearDown(seeded.db.close);
    addTearDown(seeded.container.dispose);
    await seedPhoto(seeded.db, seeded.wallId, 'photo-1');
    await seedPhoto(seeded.db, seeded.wallId, 'photo-2');

    await seeded.container
        .read(routeRepositoryProvider)
        .upsertRoute(
          seeded.wallId,
          'photo-1',
          const TopoRoute(
            id: 1,
            number: 1,
            points: [Offset(0.1, 0.1), Offset(0.2, 0.9)],
            name: 'Arete',
            gradeRaw: '6a',
          ),
        );

    final notifier = seeded.container.read(
      drawControllerProvider(seeded.wallId).notifier,
    );
    await pumpCanvas(tester, seeded.container, seeded.wallId);
    await notifier.loadForWall(seeded.wallId, 'photo-2');
    await tester.pumpAndSettle();

    Future<void> drawLine() async {
      if (seeded.container.read(drawControllerProvider(seeded.wallId)).mode !=
          DrawMode.draw) {
        await tester.tap(find.byKey(const Key('topo-mode-toggle')));
        await tester.pumpAndSettle();
      }
      notifier.addPoint(const Offset(0.5, 0.1));
      notifier.addPoint(const Offset(0.6, 0.9));
      await tester.pumpAndSettle();
    }

    await drawLine();
    // Pumped by hand, not settled: the ✓ is a pending button whose future is
    // this very save, so while the sheet is open its spinner is animating and
    // `pumpAndSettle` waits for a frame that cannot come until the question
    // is answered.
    await tester.tap(find.byKey(const Key('topo-commit-button')));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 120));
    }

    expect(
      find.byKey(const Key('topo-new-or-existing-same')),
      findsOneWidget,
      reason:
          'the save is the one moment every contributor reaches, so it '
          'is where the question has to be asked',
    );

    // "A new climb" saves as one, and does not ask again for this photo.
    await tester.tap(find.byKey(const Key('topo-new-or-existing-new')));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 120));
    }
    expect(
      find.byKey(const Key('topo-new-or-existing-same')),
      findsNothing,
      reason: 'the answer was given',
    );
    expect(
      seeded.container.read(drawControllerProvider(seeded.wallId)).routes,
      hasLength(1),
      reason: 'a new climb on this face',
    );

    // Close the metadata sheet the new climb opened. Popped rather than
    // tapped: it is scroll-controlled, so on a phone it fills the screen and
    // has neither a scrim to tap nor its own buttons above the fold.
    tester.state<NavigatorState>(find.byType(Navigator).first).pop();
    await tester.pumpAndSettle();
    await drawLine();
    await tester.tap(find.byKey(const Key('topo-commit-button')));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 120));
    }

    expect(
      find.byKey(const Key('topo-new-or-existing-same')),
      findsNothing,
      reason:
          'somebody drawing ten new lines on the second face is asked '
          'once, not ten times',
    );
  });
}
