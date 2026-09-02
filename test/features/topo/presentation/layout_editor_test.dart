import 'dart:math' as math;

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart' hide Baseline;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:masi/app/theme.dart';
import 'package:masi/core/db/app_database.dart';
import 'package:masi/core/db/database_provider.dart';
import 'package:masi/features/topo/domain/face_layout/baseline.dart';
import 'package:masi/features/topo/domain/face_layout/baseline_set.dart';
import 'package:masi/features/topo/presentation/layout_editor_screen.dart';

/// The layout editor. What is worth pinning here is the contract the design
/// states in words: a guessed line says so and can be accepted, and accepting
/// it is a real edit rather than a dismissal.
void main() {
  late AppDatabase db;

  setUp(() => db = AppDatabase(NativeDatabase.memory()));
  tearDown(() => db.close());

  const wallId = 'wall-1';

  Future<void> seed({int photos = 3, bool withGps = false}) async {
    await db
        .into(db.areas)
        .insert(
          AreasCompanion.insert(
            id: 'area-1',
            createdAt: 1000,
            updatedAt: 1000,
            name: 'Area',
          ),
        );
    await db
        .into(db.sectors)
        .insert(
          SectorsCompanion.insert(
            id: 'sector-1',
            createdAt: 1000,
            updatedAt: 1000,
            areaId: 'area-1',
            name: 'Sector',
            sortOrder: 0,
          ),
        );
    await db
        .into(db.walls)
        .insert(
          WallsCompanion.insert(
            id: wallId,
            createdAt: 1000,
            updatedAt: 1000,
            sectorId: 'sector-1',
            name: 'Kirchl Wall',
            sortOrder: 0,
          ),
        );
    for (var i = 0; i < photos; i++) {
      await db
          .into(db.photos)
          .insert(
            PhotosCompanion.insert(
              id: 'photo-$i',
              createdAt: 1000 + i,
              updatedAt: 1000 + i,
              wallId: wallId,
              localPath: '/tmp/photo-$i.jpg',
              kind: 'original',
              width: 100,
              height: 200,
              sortOrder: Value(i),
              captureLatitude: Value(withGps ? 47.0 + i * 0.0005 : null),
              captureLongitude: Value(withGps ? 12.0 + i * 0.0005 : null),
              captureAccuracyMeters: Value(withGps ? 4 : null),
            ),
          );
    }
  }

  ProviderContainer makeContainer() => ProviderContainer(
    overrides: [
      appDatabaseProvider.overrideWithValue(db),
      nowMsProvider.overrideWithValue(() => 1000),
    ],
  );

  /// Scrolls the editor down to its action row.
  ///
  /// `ensureVisible` is not enough any more: the plan is now a share of the
  /// screen rather than a fixed 240px, so on the 800x600 test surface the
  /// buttons sit past the end of what the ListView has BUILT, and a finder
  /// for an unbuilt child finds nothing at all.
  Future<void> showActions(WidgetTester tester, Key key) async {
    await tester.scrollUntilVisible(
      find.byKey(key),
      120,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
  }

  /// Enters redraw mode. Redrawing hides everything below the plan, so the
  /// list springs back and the canvas is fully on screen for the taps that
  /// follow.
  Future<void> startRedraw(WidgetTester tester) async {
    await showActions(tester, const Key('layout-redraw'));
    await tester.tap(find.byKey(const Key('layout-redraw')));
    await tester.pumpAndSettle();
  }

  Widget wrap(ProviderContainer container) => UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      theme: MasiTheme.light,
      home: const LayoutEditorScreen(wallId: wallId),
    ),
  );

  /// A line is TAPPED out here, exactly as a route is drawn on a topo — the
  /// gesture every climber using this app already knows. It used to be a
  /// freehand drag, which was both a second gesture for the same job and
  /// uncorrectable: one wobble and the only recourse was to start the rock
  /// again.
  ///
  /// The older bug this still pins: the plane fit was derived from the DRAFT,
  /// so every new point grew the draft's bounds, rescaled the mapping, and
  /// moved where the earlier points had landed. Points tapped along one
  /// horizontal came out as a curve accelerating away from the first.
  testWidgets('tapped points record the line that was tapped, and nothing is '
      'stored until Finish', (tester) async {
    await seed();
    final container = makeContainer();
    addTearDown(container.dispose);

    await tester.pumpWidget(wrap(container));
    await tester.pumpAndSettle();

    await startRedraw(tester);

    expect(
      find.byKey(const Key('layout-redraw-hint')),
      findsOneWidget,
      reason: 'redrawing must say what to do — it is a blank box otherwise',
    );

    // Four taps along one horizontal, dead level.
    final canvas = tester.getRect(find.byKey(const Key('layout-canvas')));
    final y = canvas.center.dy;
    for (var i = 0; i < 4; i++) {
      await tester.tapAt(Offset(canvas.left + 40 + i * 60, y));
      await tester.pumpAndSettle();
    }

    var wall = await (db.select(
      db.walls,
    )..where((t) => t.id.equals(wallId))).getSingle();
    expect(
      wall.baselineJson,
      isNull,
      reason:
          'a half-tapped line is not a line yet — storing on every tap '
          'would put an unfinished rock through the sync engine',
    );

    await showActions(tester, const Key('layout-redraw-done'));
    await tester.tap(find.byKey(const Key('layout-redraw-done')));
    await tester.pumpAndSettle();

    wall = await (db.select(
      db.walls,
    )..where((t) => t.id.equals(wallId))).getSingle();
    final stored = Baseline.decode(wall.baselineJson);
    expect(stored, isNotNull);
    expect(
      stored!.closed,
      isFalse,
      reason: 'a line finished away from its start is a wall, not a boulder',
    );
    expect(
      stored.points.length,
      4,
      reason: 'every tap is a decision — nothing may drop one',
    );

    final bounds = stored.bounds;
    expect(
      bounds.maxY - bounds.minY,
      lessThan(0.5),
      reason:
          'the taps never moved in y, so the stored line must not either '
          '— any thickness here is the mapping shifting mid-stroke',
    );
    expect(
      bounds.maxX - bounds.minX,
      greaterThan(1),
      reason: 'and it must still have the length that was drawn',
    );
  });

  testWidgets('a placed point can be dragged, and dragging one does NOT end '
      'the line', (tester) async {
    await seed();
    final container = makeContainer();
    addTearDown(container.dispose);

    await tester.pumpWidget(wrap(container));
    await tester.pumpAndSettle();
    await startRedraw(tester);

    final canvas = tester.getRect(find.byKey(const Key('layout-canvas')));
    final y = canvas.center.dy;
    final first = Offset(canvas.left + 40, y);
    await tester.tapAt(first);
    await tester.pumpAndSettle();
    await tester.tapAt(Offset(canvas.left + 120, y));
    await tester.pumpAndSettle();

    // Drag the FIRST point straight down.
    await tester.dragFrom(first, const Offset(0, 40));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('layout-redraw-hint')),
      findsOneWidget,
      reason:
          'lifting a finger used to commit the whole stroke, so a drag '
          'meant to fix one point finished the line instead',
    );

    await showActions(tester, const Key('layout-redraw-done'));
    await tester.tap(find.byKey(const Key('layout-redraw-done')));
    await tester.pumpAndSettle();

    final wall = await (db.select(
      db.walls,
    )..where((t) => t.id.equals(wallId))).getSingle();
    final stored = Baseline.decode(wall.baselineJson)!;
    expect(stored.points.length, 2);
    expect(
      (stored.points.first.y - stored.points.last.y).abs(),
      greaterThan(0.5),
      reason: 'the dragged point has to have actually moved off the line',
    );
  });

  testWidgets('Undo takes back the last point', (tester) async {
    await seed();
    final container = makeContainer();
    addTearDown(container.dispose);

    await tester.pumpWidget(wrap(container));
    await tester.pumpAndSettle();
    await startRedraw(tester);

    final undo = find.byKey(const Key('layout-redraw-undo'));
    expect(
      tester.widget<ButtonStyleButton>(undo).onPressed,
      isNull,
      reason: 'there is nothing to take back before the first tap',
    );

    final canvas = tester.getRect(find.byKey(const Key('layout-canvas')));
    final y = canvas.center.dy;
    for (var i = 0; i < 3; i++) {
      await tester.tapAt(Offset(canvas.left + 40 + i * 60, y));
      await tester.pumpAndSettle();
    }

    await showActions(tester, const Key('layout-redraw-undo'));
    await tester.tap(undo);
    await tester.pumpAndSettle();

    await showActions(tester, const Key('layout-redraw-done'));
    await tester.tap(find.byKey(const Key('layout-redraw-done')));
    await tester.pumpAndSettle();

    final wall = await (db.select(
      db.walls,
    )..where((t) => t.id.equals(wallId))).getSingle();
    expect(Baseline.decode(wall.baselineJson)!.points.length, 2);
  });

  testWidgets('tapping the first point again closes the ring — and that is '
      'the only way this app is told something is a boulder', (tester) async {
    await seed();
    final container = makeContainer();
    addTearDown(container.dispose);

    await tester.pumpWidget(wrap(container));
    await tester.pumpAndSettle();
    await startRedraw(tester);

    final canvas = tester.getRect(find.byKey(const Key('layout-canvas')));
    final centre = canvas.center;
    const radius = 60.0;
    Offset at(double turns) =>
        centre +
        Offset(
          radius * math.cos(turns * 2 * math.pi),
          radius * math.sin(turns * 2 * math.pi),
        );

    for (var i = 0; i < 5; i++) {
      await tester.tapAt(at(i / 5));
      await tester.pumpAndSettle();
    }
    // Back onto the first point. No button is pressed: closing IS finishing.
    await tester.tapAt(at(0));
    await tester.pumpAndSettle();

    final wall = await (db.select(
      db.walls,
    )..where((t) => t.id.equals(wallId))).getSingle();
    final stored = Baseline.decode(wall.baselineJson)!;
    expect(stored.closed, isTrue);
    expect(
      stored.points.length,
      5,
      reason:
          'the closing tap closes the ring, it does not add a sixth '
          'point on top of the first',
    );
    expect(
      find.byKey(const Key('layout-redraw-hint')),
      findsNothing,
      reason: 'closing the ring finishes the stroke',
    );
  });

  testWidgets('a guessed line says so, and the notice can be dismissed '
      'without blocking anything', (tester) async {
    await seed();
    final container = makeContainer();
    addTearDown(container.dispose);

    await tester.pumpWidget(wrap(container));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('layout-confidence-banner')), findsOneWidget);
    expect(find.byKey(const Key('layout-canvas')), findsOneWidget);

    await tester.tap(find.byKey(const Key('layout-banner-dismiss')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('layout-confidence-banner')), findsNothing);
    expect(
      find.byKey(const Key('layout-canvas')),
      findsOneWidget,
      reason: 'dismissing a hint must never take the editor with it',
    );
  });

  testWidgets('Accept promotes the guess to an authored line, and the notice '
      'goes with it', (tester) async {
    await seed(withGps: true);
    final container = makeContainer();
    addTearDown(container.dispose);

    await tester.pumpWidget(wrap(container));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('layout-confidence-banner')), findsOneWidget);

    // The editor is a scrolling column; on the default test surface the
    // action row sits below the fold.
    await showActions(tester, const Key('layout-accept'));
    await tester.tap(find.byKey(const Key('layout-accept')));
    await tester.pumpAndSettle();

    final wall = await (db.select(
      db.walls,
    )..where((t) => t.id.equals(wallId))).getSingle();
    expect(
      wall.baselineJson,
      isNotNull,
      reason:
          'accepting is an edit — it stops the line being re-guessed, and '
          'silently changing, the next time a photo is added',
    );
    expect(Baseline.decode(wall.baselineJson), isNotNull);
    expect(wall.dirty, isTrue, reason: 'the stroke has to reach the cloud');

    // Once authored, the line is no longer a guess.
    expect(find.byKey(const Key('layout-confidence-banner')), findsNothing);
  });

  testWidgets('a wall with no photos explains itself instead of rendering an '
      'empty canvas', (tester) async {
    await seed(photos: 0);
    final container = makeContainer();
    addTearDown(container.dispose);

    await tester.pumpWidget(wrap(container));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('layout-canvas')), findsNothing);
    expect(find.textContaining('Add a photo'), findsOneWidget);
  });

  testWidgets('the capture-order rail lists every face and selecting one '
      'reports how it was placed', (tester) async {
    await seed();
    final container = makeContainer();
    addTearDown(container.dispose);

    await tester.pumpWidget(wrap(container));
    await tester.pumpAndSettle();

    for (var i = 0; i < 3; i++) {
      expect(find.byKey(Key('layout-order-photo-$i')), findsOneWidget);
    }

    await tester.tap(find.byKey(const Key('layout-order-photo-1')));
    await tester.pumpAndSettle();

    // Below the fold on the test surface, like the action row — see
    // [showActions] for why a finder alone is not enough here.
    await showActions(tester, const Key('layout-selected-placement'));
    expect(find.byKey(const Key('layout-selected-placement')), findsOneWidget);
    expect(find.text('Placed in capture order'), findsOneWidget);
    expect(
      find.byKey(const Key('layout-unpin')),
      findsNothing,
      reason: 'nothing has been dragged, so there is no pin to remove',
    );
  });

  /// The pile-up the user photographed: four faces of a boulder, every
  /// thumbnail stacked on top of the others in the middle of the ring. Two
  /// separate defects made it — a normal sign that pointed inward on a
  /// counter-clockwise stroke, and no collision handling at all — so the
  /// assertion here is the visible outcome rather than either mechanism.
  Future<void> expectNoOverlappingThumbnails(
    WidgetTester tester,
    String label,
  ) async {
    // PHONE width, and not the 800x600 test default. The pile-up is a
    // function of how much canvas the thumbnails have to spread across, so
    // asserting it on a desktop-sized surface passes on the broken code —
    // which is exactly how this shipped.
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final container = makeContainer();
    addTearDown(container.dispose);
    await tester.pumpWidget(wrap(container));
    await tester.pumpAndSettle();

    final finder = find.byWidgetPredicate(
      (w) =>
          w is Container &&
          w.key is ValueKey<String> &&
          (w.key! as ValueKey<String>).value.startsWith('layout-face-') &&
          !(w.key! as ValueKey<String>).value.contains('pinned'),
    );
    final rects = [
      for (final element in finder.evaluate())
        tester.getRect(find.byWidget(element.widget)),
    ];
    expect(rects, isNotEmpty, reason: '$label rendered no thumbnails');

    for (var i = 0; i < rects.length; i++) {
      for (var j = i + 1; j < rects.length; j++) {
        expect(
          rects[i].overlaps(rects[j]),
          isFalse,
          reason: '$label: ${rects[i]} overlaps ${rects[j]}',
        );
      }
    }
  }

  testWidgets('no two thumbnails overlap on a ring', (tester) async {
    await seed(photos: 4);
    await (db.update(db.walls)..where((w) => w.id.equals(wallId))).write(
      WallsCompanion(
        // Counter-clockwise on purpose: this is the winding whose left normal
        // points into the ring, which is what sent all four to the centre.
        baselineJson: Value(
          Baseline(const [
            LayoutPoint(-6, -6),
            LayoutPoint(6, -6),
            LayoutPoint(6, 6),
            LayoutPoint(-6, 6),
          ], closed: true).encode(),
        ),
      ),
    );

    await expectNoOverlappingThumbnails(tester, 'ring');
  });

  testWidgets('no two thumbnails overlap on a crowded strip', (tester) async {
    // Seven photos on a strip: more than fit in one row at phone width, so
    // the arrangement has to stagger them rather than push sideways.
    await seed(photos: 7);
    await (db.update(db.walls)..where((w) => w.id.equals(wallId))).write(
      WallsCompanion(
        baselineJson: Value(
          Baseline(const [LayoutPoint(0, 0), LayoutPoint(30, 0)]).encode(),
        ),
      ),
    );

    await expectNoOverlappingThumbnails(tester, 'strip');
  });

  /// Long-press a face — on the plan or in the capture-order rail — and the
  /// photo opens full size. Checking WHICH slab a 64x48 tile is used to mean
  /// leaving the editor for the face and coming back, which loses the
  /// arrangement you were in the middle of correcting.
  testWidgets('long-pressing a face opens the photo, from the plan and from '
      'the capture-order rail', (tester) async {
    await seed(photos: 3);
    final container = makeContainer();
    addTearDown(container.dispose);

    await tester.pumpWidget(wrap(container));
    await tester.pumpAndSettle();

    // On the plan. The faces are drawn inside an IgnorePointer, so this is
    // resolved by the canvas's own long-press recognizer against the
    // arrangement — the reason it is worth a test at all.
    final face = tester.getRect(find.byKey(const Key('layout-face-photo-1')));
    await tester.longPressAt(face.center);
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('photo-preview')), findsOneWidget);
    // Scoped to the preview: the editor's own selected-face card names the
    // same photo, and this is an assertion about the preview.
    expect(
      find.descendant(
        of: find.byKey(const Key('photo-preview')),
        matching: find.text('Photo 2'),
      ),
      findsOneWidget,
    );

    await tester.tapAt(const Offset(8, 8));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('photo-preview')), findsNothing);

    // And from the rail.
    await tester.longPress(find.byKey(const Key('layout-order-photo-2')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('photo-preview')), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const Key('photo-preview')),
        matching: find.text('Photo 3'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('a face\'s frame is painted OVER its photo', (tester) async {
    await seed(photos: 3);
    final container = makeContainer();
    addTearDown(container.dispose);

    await tester.pumpWidget(wrap(container));
    await tester.pumpAndSettle();

    final tile = tester.widget<Container>(
      find.byKey(const Key('layout-face-photo-0')),
    );
    expect(
      (tile.foregroundDecoration! as BoxDecoration).border,
      isNotNull,
      reason:
          'a background frame is painted before the child, and the '
          'clipped photo then eats its rounded corners',
    );
    expect((tile.decoration! as BoxDecoration).border, isNull);
  });

  /// Holding a photo to look at it is not placing it. The canvas takes the
  /// pointer back when the gesture arena rejects its pan, so a long-press
  /// runs a whole drag — and a drag that ends where it began used to write a
  /// pin: a sync-dirty row and a face that reports "you placed this one"
  /// from a gesture that placed nothing.
  testWidgets('a press that never moves places nothing', (tester) async {
    await seed(photos: 3);
    final container = makeContainer();
    addTearDown(container.dispose);

    await tester.pumpWidget(wrap(container));
    await tester.pumpAndSettle();

    final face = tester.getRect(find.byKey(const Key('layout-face-photo-1')));
    await tester.longPressAt(face.center);
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(8, 8));
    await tester.pumpAndSettle();

    final photo = await (db.select(
      db.photos,
    )..where((p) => p.id.equals('photo-1'))).getSingle();
    expect(
      photo.layoutPinnedT,
      isNull,
      reason: 'nothing moved, so nothing may be pinned',
    );
  });

  /// A crag bay is often not one rock. Before this the contributor either
  /// drew one line around two boulders — claiming the gap between them is
  /// climbable rock — or left the guess alone.
  testWidgets('Add another rock APPENDS a second stroke instead of replacing '
      'the first, and the first survives it', (tester) async {
    await seed(photos: 3);
    final container = makeContainer();
    addTearDown(container.dispose);

    await tester.pumpWidget(wrap(container));
    await tester.pumpAndSettle();

    // Draw the first rock, so there is something an append could destroy.
    await startRedraw(tester);
    var canvas = tester.getRect(find.byKey(const Key('layout-canvas')));
    for (var i = 0; i < 4; i++) {
      await tester.tapAt(
        Offset(
          canvas.left + 40 + (i % 2) * 60,
          canvas.top + 40 + (i ~/ 2) * 50,
        ),
      );
      await tester.pumpAndSettle();
    }
    await showActions(tester, const Key('layout-redraw-done'));
    await tester.tap(find.byKey(const Key('layout-redraw-done')));
    await tester.pumpAndSettle();

    var stored = BaselineSet.decode(
      (await (db.select(
        db.walls,
      )..where((t) => t.id.equals(wallId))).getSingle()).baselineJson,
    );
    expect(stored!.length, 1);
    final firstRock = stored.strokes.first.points.length;

    // Now a second one, somewhere else on the canvas.
    await showActions(tester, const Key('layout-add-rock'));
    await tester.tap(find.byKey(const Key('layout-add-rock')));
    await tester.pumpAndSettle();

    canvas = tester.getRect(find.byKey(const Key('layout-canvas')));
    for (var i = 0; i < 3; i++) {
      await tester.tapAt(
        Offset(
          canvas.right - 90 + (i % 2) * 50,
          canvas.bottom - 90 + (i ~/ 2) * 40,
        ),
      );
      await tester.pumpAndSettle();
    }
    await showActions(tester, const Key('layout-redraw-done'));
    await tester.tap(find.byKey(const Key('layout-redraw-done')));
    await tester.pumpAndSettle();

    stored = BaselineSet.decode(
      (await (db.select(
        db.walls,
      )..where((t) => t.id.equals(wallId))).getSingle()).baselineJson,
    );
    expect(
      stored!.length,
      2,
      reason: 'adding a rock must not replace the drawing',
    );
    expect(
      stored.strokes.first.points.length,
      firstRock,
      reason:
          'and the rock that was already there must come through '
          'untouched',
    );
  });

  testWidgets('a wall with one rock still stores the LEGACY shape, so an '
      'older build can read the row it syncs', (tester) async {
    await seed(photos: 3);
    final container = makeContainer();
    addTearDown(container.dispose);

    await tester.pumpWidget(wrap(container));
    await tester.pumpAndSettle();

    await startRedraw(tester);
    final canvas = tester.getRect(find.byKey(const Key('layout-canvas')));
    for (var i = 0; i < 3; i++) {
      await tester.tapAt(Offset(canvas.left + 40 + i * 50, canvas.center.dy));
      await tester.pumpAndSettle();
    }
    await showActions(tester, const Key('layout-redraw-done'));
    await tester.tap(find.byKey(const Key('layout-redraw-done')));
    await tester.pumpAndSettle();

    final json = (await (db.select(
      db.walls,
    )..where((t) => t.id.equals(wallId))).getSingle()).baselineJson;
    expect(
      Baseline.decode(json),
      isNotNull,
      reason:
          'the single-rock row must still parse as a plain baseline — '
          'the column syncs, and older builds read it',
    );
  });

  /// The complaint this pins: 'I can draw a new line but I can't edit or
  /// delete the old one.' Every one of those repairs existed — reshape by
  /// handle, redraw, remove — and not one of them could be reached without
  /// first guessing that the drawing was tappable, and then finding a text
  /// button at the bottom of a scrolling page.
  testWidgets('a rock can be picked out, EDITED on its own, and removed — '
      'and the other rock survives all three', (tester) async {
    await seed(photos: 3);
    final container = makeContainer();
    addTearDown(container.dispose);

    await tester.pumpWidget(wrap(container));
    await tester.pumpAndSettle();

    Future<void> drawStroke(Key start, List<Offset> at) async {
      await showActions(tester, start);
      await tester.tap(find.byKey(start));
      await tester.pumpAndSettle();
      final canvas = tester.getRect(find.byKey(const Key('layout-canvas')));
      for (final point in at) {
        await tester.tapAt(canvas.topLeft + point);
        await tester.pumpAndSettle();
      }
      await showActions(tester, const Key('layout-redraw-done'));
      await tester.tap(find.byKey(const Key('layout-redraw-done')));
      await tester.pumpAndSettle();
    }

    Future<BaselineSet> stored() async => BaselineSet.decode(
      (await (db.select(
        db.walls,
      )..where((t) => t.id.equals(wallId))).getSingle()).baselineJson,
    )!;

    await drawStroke(const Key('layout-redraw'), const [
      Offset(40, 40),
      Offset(110, 40),
      Offset(110, 100),
      Offset(40, 100),
    ]);
    await drawStroke(const Key('layout-add-rock'), const [
      Offset(230, 190),
      Offset(300, 190),
      Offset(300, 240),
    ]);

    var set = await stored();
    expect(set.length, 2);
    final firstRock = set.strokes.first.points.length;

    // Picked out by name, not by guessing that the drawing is touchable.
    await showActions(tester, const Key('layout-rock-chip-1'));
    await tester.tap(find.byKey(const Key('layout-rock-chip-1')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('layout-rock-card')),
      findsOneWidget,
      reason: 'picking a rock out has to produce somewhere to act on it',
    );
    expect(find.text('Rock 2'), findsWidgets);

    // Edit ONE rock. It reopens as its own points — editing is a mode, and
    // this is the only door into it — and finishing writes back only that
    // rock. The button at the bottom of the page replaces the whole drawing,
    // which on a two-boulder crag costs the rock that was fine to fix the
    // one that was not.
    final secondRock = set.strokes[1].points.length;
    await showActions(tester, const Key('layout-redraw-rock'));
    await tester.tap(find.byKey(const Key('layout-redraw-rock')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('layout-redraw-done')),
      findsOneWidget,
      reason: 'Edit has to put the canvas in the drawing mode',
    );

    // One more point on the end, so the write is observable.
    var canvas = tester.getRect(find.byKey(const Key('layout-canvas')));
    await tester.tapAt(canvas.topLeft + const Offset(240, 250));
    await tester.pumpAndSettle();
    await showActions(tester, const Key('layout-redraw-done'));
    await tester.tap(find.byKey(const Key('layout-redraw-done')));
    await tester.pumpAndSettle();

    set = await stored();
    expect(set.length, 2, reason: 'editing one rock must not drop the other');
    expect(
      set.strokes.first.points.length,
      firstRock,
      reason: 'and must leave it exactly as it was',
    );
    expect(
      set.strokes[1].points.length,
      secondRock + 1,
      reason:
          'Edit reopens the rock AS ITS POINTS — starting from an empty '
          'canvas would make every correction a retrace',
    );

    // And removed.
    await showActions(tester, const Key('layout-rock-chip-1'));
    await tester.tap(find.byKey(const Key('layout-rock-chip-1')));
    await tester.pumpAndSettle();
    await showActions(tester, const Key('layout-remove-rock'));
    await tester.tap(find.byKey(const Key('layout-remove-rock')));
    await tester.pumpAndSettle();

    set = await stored();
    expect(set.length, 1, reason: 'remove has to actually remove one');
    expect(
      set.strokes.first.points.length,
      firstRock,
      reason: 'and it has to be the one that was picked out',
    );
  });

  testWidgets('removing the last rock hands back the automatic line rather '
      'than a blank editor', (tester) async {
    await seed(photos: 1);
    final container = makeContainer();
    addTearDown(container.dispose);

    await tester.pumpWidget(wrap(container));
    await tester.pumpAndSettle();

    await startRedraw(tester);
    var canvas = tester.getRect(find.byKey(const Key('layout-canvas')));
    for (var i = 0; i < 3; i++) {
      await tester.tapAt(Offset(canvas.left + 40 + i * 90, canvas.top + 60));
      await tester.pumpAndSettle();
    }
    await showActions(tester, const Key('layout-redraw-done'));
    await tester.tap(find.byKey(const Key('layout-redraw-done')));
    await tester.pumpAndSettle();

    // On a one-rock wall there are no chips — the drawing IS the line — so
    // this is the path that has to work: touch the line itself.
    canvas = tester.getRect(find.byKey(const Key('layout-canvas')));
    await tester.tapAt(Offset(canvas.left + 30, canvas.center.dy));
    await tester.pumpAndSettle();
    await showActions(tester, const Key('layout-remove-rock'));
    await tester.tap(find.byKey(const Key('layout-remove-rock')));
    await tester.pumpAndSettle();

    final json = (await (db.select(
      db.walls,
    )..where((t) => t.id.equals(wallId))).getSingle()).baselineJson;
    expect(
      json,
      isNull,
      reason:
          'no drawing is the same state as never having drawn — the '
          'engine synthesises a guess again rather than leaving a blank page',
    );
    expect(
      find.byKey(const Key('layout-canvas')),
      findsOneWidget,
      reason: 'and the editor still has a line to show',
    );
  });

  testWidgets('a picked-out rock that stops existing stops being picked out', (
    tester,
  ) async {
    await seed(photos: 2);
    final container = makeContainer();
    addTearDown(container.dispose);

    await tester.pumpWidget(wrap(container));
    await tester.pumpAndSettle();

    Future<void> drawStroke(Key start, List<Offset> at) async {
      await showActions(tester, start);
      await tester.tap(find.byKey(start));
      await tester.pumpAndSettle();
      final canvas = tester.getRect(find.byKey(const Key('layout-canvas')));
      for (final point in at) {
        await tester.tapAt(canvas.topLeft + point);
        await tester.pumpAndSettle();
      }
      await showActions(tester, const Key('layout-redraw-done'));
      await tester.tap(find.byKey(const Key('layout-redraw-done')));
      await tester.pumpAndSettle();
    }

    await drawStroke(const Key('layout-redraw'), const [
      Offset(40, 40),
      Offset(120, 40),
      Offset(120, 100),
    ]);
    await drawStroke(const Key('layout-add-rock'), const [
      Offset(240, 190),
      Offset(310, 190),
      Offset(310, 250),
    ]);

    await showActions(tester, const Key('layout-rock-chip-1'));
    await tester.tap(find.byKey(const Key('layout-rock-chip-1')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('layout-rock-card')), findsOneWidget);

    // Back to the automatic line: rock 2 no longer exists.
    await showActions(tester, const Key('layout-reset'));
    await tester.tap(find.byKey(const Key('layout-reset')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('layout-rock-card')),
      findsNothing,
      reason:
          'a card acting on a rock that is gone would redraw or remove '
          'something nobody pointed at — an out-of-range redraw falls through '
          'to replacing the WHOLE drawing',
    );
  });

  /// "Don't allow the edit of the lines but only in the redraw mode."
  ///
  /// The plan used to carry a grab handle on every point of every settled
  /// rock, and reading it means touching it — sliding a photo along the line,
  /// tapping a rock to pick it out. So the drawing reshaped under the fingers
  /// of somebody who had not said they were editing anything, and there was
  /// no state on screen that told the two apart. The other half of this
  /// contract — that points ARE draggable once you are drawing — is pinned by
  /// 'a placed point can be dragged'.
  testWidgets('no drag anywhere on the plan reshapes a settled rock', (
    tester,
  ) async {
    await seed(photos: 2);
    final container = makeContainer();
    addTearDown(container.dispose);

    await tester.pumpWidget(wrap(container));
    await tester.pumpAndSettle();

    await startRedraw(tester);
    var canvas = tester.getRect(find.byKey(const Key('layout-canvas')));
    for (final at in const [
      Offset(40, 40),
      Offset(140, 40),
      Offset(140, 120),
      Offset(40, 120),
    ]) {
      await tester.tapAt(canvas.topLeft + at);
      await tester.pumpAndSettle();
    }
    await showActions(tester, const Key('layout-redraw-done'));
    await tester.tap(find.byKey(const Key('layout-redraw-done')));
    await tester.pumpAndSettle();

    Future<String?> storedJson() async => (await (db.select(
      db.walls,
    )..where((t) => t.id.equals(wallId))).getSingle()).baselineJson;

    final before = await storedJson();
    expect(before, isNotNull);

    // Drag across the whole plan, in a grid, so this cannot pass by missing
    // the line: wherever a handle used to be, a drag from there now moves
    // nothing.
    canvas = tester.getRect(find.byKey(const Key('layout-canvas')));
    for (var x = 0.15; x < 0.9; x += 0.15) {
      for (var y = 0.15; y < 0.9; y += 0.2) {
        final from = Offset(
          canvas.left + canvas.width * x,
          canvas.top + canvas.height * y,
        );
        await tester.dragFrom(from, const Offset(26, 18));
        await tester.pumpAndSettle();
      }
    }

    expect(
      await storedJson(),
      before,
      reason: 'the rock changed shape without anybody entering an edit',
    );
  });

  testWidgets('the plan can be pinched open', (tester) async {
    await seed(photos: 2);
    final container = makeContainer();
    addTearDown(container.dispose);

    await tester.pumpWidget(wrap(container));
    await tester.pumpAndSettle();

    final before = tester.getRect(find.byKey(const Key('layout-canvas')));
    final centre = before.center;

    // Two fingers, apart. A crag bay drawn to fit a phone puts a boulder in a
    // thumb's width, and the line is the thing this screen is for.
    final left = await tester.startGesture(centre - const Offset(24, 0));
    final right = await tester.startGesture(centre + const Offset(24, 0));
    await tester.pump();
    for (var step = 0; step < 6; step++) {
      await left.moveBy(const Offset(-12, 0));
      await right.moveBy(const Offset(12, 0));
      await tester.pump();
    }
    await left.up();
    await right.up();
    await tester.pumpAndSettle();

    final after = tester.getRect(find.byKey(const Key('layout-canvas')));
    expect(
      after.width,
      greaterThan(before.width * 1.2),
      reason: 'the plan did not magnify — the pinch never reached a viewer',
    );
  });
}
