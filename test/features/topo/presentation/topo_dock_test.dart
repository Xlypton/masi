import 'package:flutter/semantics.dart' show SemanticsAction;
import 'package:drift/native.dart';
import 'package:flutter/material.dart' hide Baseline;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:masi/app/theme.dart';
import 'package:masi/core/db/app_database.dart';
import 'package:masi/core/db/database_provider.dart';
import 'package:masi/features/topo/application/draw_controller.dart';
import 'package:masi/features/topo/data/photo_repository.dart';
import 'package:masi/features/topo/domain/face_layout/baseline.dart';
import 'package:masi/features/topo/domain/face_layout/face_layout_input.dart';
import 'package:masi/features/topo/domain/face_layout/layout_resolver.dart';
import 'package:masi/features/topo/domain/topo_route.dart';
import 'package:masi/features/topo/presentation/topo_canvas_screen.dart';

/// The bottom dock: ONE surface carrying the faces and the routes.
///
/// It replaced three floating panels that each reserved space for the next by
/// a hand-maintained constant. That scheme failed three times, most recently
/// by drawing the face minimap straight over the route list on a real phone —
/// `FacePager.reservedHeight` claimed 191pt for a widget that rendered 208.
///
/// So the assertions here are the two things a constant cannot promise: that
/// nothing in the bottom band overlaps anything else, and that the panel is
/// only as tall as what it actually draws. They run at PHONE width, because
/// crowding is a function of how much room there is — the same measurements on
/// the 800x600 test default pass on the broken layout.
void main() {
  const wallId = 'wall-1';

  List<PhotoRef> photos(int n) => [
    for (var i = 0; i < n; i++)
      PhotoRef(
        id: 'photo-$i',
        wallId: wallId,
        kind: 'original',
        localPath: '/tmp/photo-$i.jpg',
        width: 100,
        height: 200,
        sortOrder: i,
      ),
  ];

  LayoutResult ringLayout(int n) => resolveLayout(
    faces: [
      for (var i = 0; i < n; i++) FaceInput(id: 'photo-$i', captureOrder: i),
    ],
    baseline: Baseline(const [
      LayoutPoint(-6, -6),
      LayoutPoint(6, -6),
      LayoutPoint(6, 6),
      LayoutPoint(-6, 6),
    ], closed: true),
  );

  const route = TopoRoute(
    id: 1,
    number: 1,
    points: [Offset(0.1, 0.1), Offset(0.2, 0.2)],
  );

  Future<void> pumpDock(
    WidgetTester tester, {
    int faces = 4,
    List<TopoRoute> routes = const [route],
    DrawMode mode = DrawMode.view,
    LayoutResult? layout,
    Map<String, int> routeCounts = const {},
    VoidCallback? onOpenFaceMap,
  }) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final controller = TransformationController();
    addTearDown(controller.dispose);

    // An in-memory database, so a widget test never reaches for the app's real
    // one just because RouteLegend's controller wants a repository.
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [appDatabaseProvider.overrideWithValue(db)],
        child: MaterialApp(
          theme: MasiTheme.light,
          home: Scaffold(
            body: TopoCanvasBody(
              wallId: wallId,
              imagePath: '/nonexistent/topo.jpg',
              imageSize: const Size(400, 300),
              drawState: DrawState(mode: mode, routes: routes),
              transformationController: controller,
              facePhotos: photos(faces),
              faceLayout: layout ?? ringLayout(faces),
              faceRouteCounts: routeCounts,
              onSelectFace: (_) {},
              onOpenFaceMap: onOpenFaceMap ?? () {},
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  /// Opens the dock's body. Closed is the DEFAULT now — one line, so the photo
  /// keeps the screen — which is why every assertion about the route list has
  /// to ask for it first.
  /// Opens the dock's body the only way a thumb can now: an upward swipe on
  /// the lane. The count's chevron used to be a button and is not one any more
  /// (user request, 2026-09-02 — "don't need the little chevron on the routes
  /// component, only rely on the up or down swipe"), so every test that needs
  /// the list open goes through the gesture the user goes through.
  Future<void> openBody(WidgetTester tester) async {
    await tester.fling(
      find.byKey(const Key('topo-dock-lane')),
      const Offset(0, -120),
      1000,
    );
    await tester.pumpAndSettle();
  }

  testWidgets('the dock is ONE LINE until you ask for more', (tester) async {
    await pumpDock(tester);

    expect(find.byKey(const Key('topo-dock')), findsOneWidget);
    expect(
      find.byKey(const Key('face-rail')),
      findsOneWidget,
      reason: 'which face you are on is the one thing worth a permanent line',
    );
    expect(find.byKey(const Key('topo-dock-routes')), findsNothing);

    // A bar, not a panel: the photo is what the reader opened the screen for.
    // Measured at 95pt with four faces — the same band the row of 7px dots
    // occupied, because the dots carried a caption-height gap and their own
    // padding anyway. The pictures are free; what the reader got back is the
    // 153pt map card this dock no longer mounts.
    final dock = tester.getRect(find.byKey(const Key('topo-dock')));
    expect(
      dock.height,
      lessThan(104),
      reason: 'closed, the dock must not read as a panel',
    );
  });

  testWidgets('the faces and the routes are ONE panel, not two that have to '
      'clear each other', (tester) async {
    await pumpDock(tester);
    await openBody(tester);

    expect(find.byKey(const Key('topo-dock')), findsOneWidget);
    // The dots ride inside it, not in a panel of their own below it.
    final dock = tester.getRect(find.byKey(const Key('topo-dock')));
    final rail = tester.getRect(find.byKey(const Key('face-rail')));
    expect(
      dock.contains(rail.topLeft) && dock.contains(rail.bottomRight),
      isTrue,
      reason: 'the face lane must be a row of the dock, not a sibling of it',
    );

    // And the route list is in the same panel as the dots — the pairing the
    // old layout could not hold without a clearance constant.
    final legend = tester.getRect(find.byKey(const Key('topo-dock-routes')));
    expect(dock.contains(legend.topLeft), isTrue);
    expect(legend.top, greaterThanOrEqualTo(rail.bottom));
  });

  testWidgets('the map is a screen you ask for, not a card mounted above the '
      'route list', (tester) async {
    var opened = 0;
    await pumpDock(tester, onOpenFaceMap: () => opened++);
    await openBody(tester);

    // Nothing of the plan is mounted here at all any more. This is the 153pt
    // of permanently-mounted card that pushed the route list into the middle
    // of the screen — the dock's body is the routes and only the routes.
    expect(find.byKey(const Key('topo-dock-routes')), findsOneWidget);

    await tester.tap(find.byKey(const Key('face-rail-map')));
    await tester.pumpAndSettle();

    expect(opened, 1, reason: 'the plan tile opens the full-screen map');
    expect(
      find.byKey(const Key('topo-dock-routes')),
      findsOneWidget,
      reason: 'asking for the map must not put the route list away',
    );
    expect(
      find.byKey(const Key('face-rail')),
      findsOneWidget,
      reason: 'the lane is pinned — which face you are on never goes away',
    );
  });

  testWidgets('the plan tile works while the dock is CLOSED — the rail is '
      'pinned, so everything on it is reachable at one line', (tester) async {
    var opened = 0;
    await pumpDock(tester, onOpenFaceMap: () => opened++);

    expect(find.byKey(const Key('topo-dock-body')), findsNothing);
    await tester.tap(find.byKey(const Key('face-rail-map')));
    await tester.pumpAndSettle();

    expect(opened, 1);
    expect(
      find.byKey(const Key('topo-dock-body')),
      findsNothing,
      reason: 'opening a screen must not also expand the panel behind it',
    );
  });

  testWidgets('nothing in the bottom band overlaps anything else', (
    tester,
  ) async {
    await pumpDock(tester);
    await openBody(tester);

    final dock = tester.getRect(find.byKey(const Key('topo-dock')));
    // The dock is the only floating panel down here now, so the check that
    // matters is that the two things that used to be separate panels are
    // stacked inside it without touching.
    final rail = tester.getRect(find.byKey(const Key('face-rail')));
    final legend = tester.getRect(find.byKey(const Key('topo-dock-routes')));
    expect(rail.overlaps(legend), isFalse);

    // And it stays on screen: a panel taller than the viewport is the other
    // way this band has broken.
    expect(dock.top, greaterThanOrEqualTo(0));
    expect(dock.bottom, lessThanOrEqualTo(844));
  });

  testWidgets('collapsing leaves the face lane behind — navigation is not '
      'part of the route list', (tester) async {
    await pumpDock(tester);
    await openBody(tester);

    // Down closes, the mirror of the swipe that opened it.
    await tester.fling(
      find.byKey(const Key('topo-dock-lane')),
      const Offset(0, 120),
      1000,
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('topo-dock-routes')), findsNothing);
    expect(
      find.byKey(const Key('face-rail')),
      findsOneWidget,
      reason: 'putting the routes away must not take the faces with them',
    );
    expect(find.byKey(const Key('topo-dock')), findsOneWidget);
  });

  testWidgets(
    'the count carries no chevron and no tap target — but it still offers '
    'the action to a screen reader, which cannot perform a swipe',
    (tester) async {
      await pumpDock(tester);

      final toggle = find.byKey(const Key('topo-dock-routes-toggle'));
      expect(toggle, findsOneWidget, reason: 'the tally is still there');
      expect(
        find.descendant(of: toggle, matching: find.byType(GestureDetector)),
        findsNothing,
        reason: 'nothing up here answers a tap any more',
      );

      final handle = tester.getSemantics(toggle);
      expect(
        handle.getSemanticsData().hasAction(SemanticsAction.tap),
        isTrue,
        reason:
            'removing a control must not remove it from VoiceOver: the '
            'gesture that replaced it is one assistive technology cannot '
            'make',
      );
    },
  );

  testWidgets('a wall with routes but no faces keeps the plain floating '
      'panel it always had', (tester) async {
    await pumpDock(tester, faces: 1);

    expect(find.byKey(const Key('topo-dock')), findsNothing);
    expect(find.byKey(const Key('topo-route-legend-overlay')), findsOneWidget);
  });

  testWidgets('draw mode gets no face lane — walking round the rock '
      'mid-stroke is how you lose the stroke', (tester) async {
    await pumpDock(tester, mode: DrawMode.draw);

    expect(find.byKey(const Key('topo-dock')), findsNothing);
    expect(find.byKey(const Key('face-rail')), findsNothing);
  });

  testWidgets('a degenerate baseline offers no map button rather than an '
      'empty box', (tester) async {
    await pumpDock(
      tester,
      // `LayoutResult.empty` is the shape a wall has before its photos have
      // been read — a baseline with nothing in it. `resolveLayout` would
      // SYNTHESISE a line rather than hand one back degenerate, so this has to
      // be the empty result itself.
      layout: LayoutResult.empty,
    );

    expect(find.byKey(const Key('topo-dock')), findsOneWidget);
    expect(find.byKey(const Key('face-rail')), findsOneWidget);
    expect(find.byKey(const Key('face-rail-map')), findsNothing);
  });

  /// The rail is what the dock's width is for: it is the photos. Spelling the
  /// route count out as a phrase spent about a thumbnail's worth of a phone on
  /// saying '0 routes' — a fact the list says again the moment it opens.
  testWidgets('the route toggle spends a chevron and a numeral, not a phrase', (
    tester,
  ) async {
    await pumpDock(tester);

    expect(
      find.text('1 route'),
      findsNothing,
      reason: 'the phrase is what cost the rail its width',
    );
    expect(
      find.descendant(
        of: find.byKey(const Key('topo-dock-routes-toggle')),
        matching: find.text('1'),
      ),
      findsOneWidget,
      reason: 'the count still has to be there — just not spelled out',
    );

    final toggle = tester.getRect(
      find.byKey(const Key('topo-dock-routes-toggle')),
    );
    final rail = tester.getRect(find.byKey(const Key('face-rail')));
    expect(
      toggle.width,
      lessThan(56),
      reason:
          'a phrase-sized toggle is what pushed the third photo off the '
          'edge of a 390pt phone',
    );
    expect(
      rail.width,
      greaterThan(285),
      reason: 'and the width it gives up has to land on the photos',
    );
  });
}
