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
    await db.into(db.areas).insert(
      AreasCompanion.insert(
        id: 'area-1',
        createdAt: 1000,
        updatedAt: 1000,
        name: 'Area',
      ),
    );
    await db.into(db.sectors).insert(
      SectorsCompanion.insert(
        id: 'sector-1',
        createdAt: 1000,
        updatedAt: 1000,
        areaId: 'area-1',
        name: 'Sector',
        sortOrder: 0,
      ),
    );
    await db.into(db.walls).insert(
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
      await db.into(db.photos).insert(
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

    var wall = await (db.select(db.walls)..where((t) => t.id.equals(wallId)))
        .getSingle();
    expect(
      wall.baselineJson,
      isNull,
      reason: 'a half-tapped line is not a line yet — storing on every tap '
          'would put an unfinished rock through the sync engine',
    );

    await showActions(tester, const Key('layout-redraw-done'));
    await tester.tap(find.byKey(const Key('layout-redraw-done')));
    await tester.pumpAndSettle();

    wall = await (db.select(db.walls)..where((t) => t.id.equals(wallId)))
        .getSingle();
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
      reason: 'the taps never moved in y, so the stored line must not either '
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
      reason: 'lifting a finger used to commit the whole stroke, so a drag '
          'meant to fix one point finished the line instead',
    );

    await showActions(tester, const Key('layout-redraw-done'));
    await tester.tap(find.byKey(const Key('layout-redraw-done')));
    await tester.pumpAndSettle();

    final wall = await (db.select(db.walls)..where((t) => t.id.equals(wallId)))
        .getSingle();
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

    final wall = await (db.select(db.walls)..where((t) => t.id.equals(wallId)))
        .getSingle();
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
    Offset at(double turns) => centre +
        Offset(radius * math.cos(turns * 2 * math.pi),
            radius * math.sin(turns * 2 * math.pi));

    for (var i = 0; i < 5; i++) {
      await tester.tapAt(at(i / 5));
      await tester.pumpAndSettle();
    }
    // Back onto the first point. No button is pressed: closing IS finishing.
    await tester.tapAt(at(0));
    await tester.pumpAndSettle();

    final wall = await (db.select(db.walls)
          ..where((t) => t.id.equals(wallId)))
        .getSingle();
    final stored = Baseline.decode(wall.baselineJson)!;
    expect(stored.closed, isTrue);
    expect(
      stored.points.length,
      5,
      reason: 'the closing tap closes the ring, it does not add a sixth '
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

    final wall = await (db.select(db.walls)
          ..where((t) => t.id.equals(wallId)))
        .getSingle();
    expect(
      wall.baselineJson,
      isNotNull,
      reason: 'accepting is an edit — it stops the line being re-guessed, and '
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

    expect(
      find.byKey(const Key('layout-selected-placement')),
      findsOneWidget,
    );
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
      for (final element in finder.evaluate()) tester.getRect(find.byWidget(element.widget)),
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
          Baseline(const [
            LayoutPoint(0, 0),
            LayoutPoint(30, 0),
          ]).encode(),
        ),
      ),
    );

    await expectNoOverlappingThumbnails(tester, 'strip');
  });
}
