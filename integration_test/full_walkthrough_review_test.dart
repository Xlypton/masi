// Full visual-review walkthrough: seeds a rich library (2 Areas x 1 Sector x
// 2 Walls each, a photo+multi-route wall exercising all 5 SymbolType glyphs,
// one published + several private topos, two walls with Budapest-area GPS
// coordinates, and two logged ascents), then drives the app through every
// major screen — Topos home, search, filters, topo canvas (view + draw),
// route metadata sheet, Community feed + map, community topo detail,
// Logbook, Areas (Organize), and the Set-location picker — taking a
// screenshot at each stop. Every deep step is wrapped in its own try/catch
// so one failure doesn't abort the rest of the walkthrough; failures are
// logged via `debugPrint` and also surfaced as a synthetic
// `binding.takeScreenshot('FAILED-<step>')`-free text log at the end (the
// test itself always passes as long as SOME screenshots were taken, since
// this file's only job is visual review, not assertions).
//
// Same DB-file seeding seam as `boulder_marker_review_test.dart` /
// `map_review_test.dart`: a real AppDatabase opened directly on the app's
// real `climbtopo.sqlite` file, seeded via the real repositories, and closed
// BEFORE `app.main()` opens its own connection to the same file.
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'package:climbtopo/core/db/app_database.dart';
import 'package:climbtopo/core/grades/grade_system.dart';
import 'package:climbtopo/features/library/data/library_crud_repository.dart';
import 'package:climbtopo/features/logbook/data/ascents_repository.dart';
import 'package:climbtopo/features/topo/data/route_repository.dart';
import 'package:climbtopo/features/topo/domain/topo_route.dart';
import 'package:climbtopo/main.dart' as app;

/// Generates a real, decodable PNG (gradient + grid) for a seeded wall's
/// photo — same recipe `boulder_marker_review_test.dart`/`map_review_test
/// .dart` use, reused here so every seeded wall has a real image rather than
/// a fake/empty file (which the topo canvas's image decode would reject).
Future<Uint8List> _wallImage({required Color accent}) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  const size = Size(1200, 1600);
  final rect = Rect.fromLTWH(0, 0, size.width, size.height);
  canvas.drawRect(
    rect,
    Paint()
      ..shader = ui.Gradient.linear(rect.topLeft, rect.bottomRight, [
        const Color(0xFF1B5E20),
        accent,
        const Color(0xFFB71C1C),
      ], const [0.0, 0.5, 1.0]),
  );
  final gridPaint = Paint()
    ..color = Colors.white.withValues(alpha: 0.5)
    ..strokeWidth = 3;
  for (var x = 0; x < size.width; x += 100) {
    canvas.drawLine(Offset(x.toDouble(), 0), Offset(x.toDouble(), size.height), gridPaint);
  }
  for (var y = 0; y < size.height; y += 100) {
    canvas.drawLine(Offset(0, y.toDouble()), Offset(size.width, y.toDouble()), gridPaint);
  }
  final picture = recorder.endRecording();
  final image = await picture.toImage(1200, 1600);
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  return bytes!.buffer.asUint8List();
}

/// Seeds the full review library directly into the app's real sqlite file,
/// returning the id the walkthrough needs to navigate deterministically
/// (the one wall with a photo, routes, publish state, and coordinates).
class _SeedResult {
  _SeedResult({required this.sunnyFaceWallId});

  final String sunnyFaceWallId;
}

Future<_SeedResult> _seed(String Function(String name) imagePathFor) async {
  final docsDir = await getApplicationDocumentsDirectory();
  final dbFile = File(p.join(docsDir.path, 'climbtopo.sqlite'));
  if (await dbFile.exists()) await dbFile.delete();

  final seedDb = AppDatabase(NativeDatabase(dbFile));
  try {
    int nowMs() => DateTime.now().millisecondsSinceEpoch;
    final libraryRepo = LibraryCrudRepository(seedDb, nowMs: nowMs);
    final routeRepo = RouteRepository(seedDb, nowMs: nowMs);
    final ascentsRepo = AscentsRepository(seedDb, nowMs: nowMs);

    // -----------------------------------------------------------------
    // Area 1: Danube Boulders > Riverside > {Sunny Face, Shady Corner}
    // -----------------------------------------------------------------
    final danube = await libraryRepo.createArea('Danube Boulders');
    final riverside = await libraryRepo.createSector(danube.id, 'Riverside');

    final sunnyFace = await libraryRepo.createWall(riverside.id, 'Sunny Face');
    final sunnyImagePath = imagePathFor('sunny_face');
    await File(
      sunnyImagePath,
    ).writeAsBytes(await _wallImage(accent: const Color(0xFFF9A825)), flush: true);
    final sunnyPhotoId = await libraryRepo.attachPhotoToWall(
      sunnyFace.id,
      XFile(sunnyImagePath),
      1200,
      1600,
    );

    // Route 1: anchor + bolt + crux, named + graded (French).
    final route1 = TopoRoute(
      id: 1,
      number: 1,
      points: const [
        Offset(0.28, 0.92),
        Offset(0.32, 0.7),
        Offset(0.4, 0.5),
        Offset(0.45, 0.28),
        Offset(0.5, 0.1),
      ],
      symbols: const [
        TopoSymbol(type: SymbolType.anchor, position: Offset(0.28, 0.92)),
        TopoSymbol(type: SymbolType.bolt, position: Offset(0.4, 0.5)),
        TopoSymbol(type: SymbolType.crux, position: Offset(0.45, 0.28)),
      ],
      colorIndex: routeColorIndexFor(1),
      name: 'Le Toit',
      gradeSystem: GradeSystem.french,
      gradeRaw: '6a+',
      gradeSortKey: gradeSortKey(GradeSystem.french, '6a+'),
      style: 'sport',
    );
    await routeRepo.upsertRoute(sunnyFace.id, sunnyPhotoId, route1);

    // Route 2: top + disabledHold, named + graded (UIAA).
    final route2 = TopoRoute(
      id: 2,
      number: 2,
      points: const [
        Offset(0.62, 0.9),
        Offset(0.66, 0.65),
        Offset(0.7, 0.4),
        Offset(0.75, 0.15),
      ],
      symbols: const [
        TopoSymbol(type: SymbolType.disabledHold, position: Offset(0.66, 0.65)),
        TopoSymbol(type: SymbolType.top, position: Offset(0.75, 0.15)),
      ],
      colorIndex: routeColorIndexFor(2),
      name: 'The High Line',
      gradeSystem: GradeSystem.uiaa,
      gradeRaw: 'VII-',
      gradeSortKey: gradeSortKey(GradeSystem.uiaa, 'VII-'),
      style: 'trad',
    );
    await routeRepo.upsertRoute(sunnyFace.id, sunnyPhotoId, route2);

    await libraryRepo.publishTopo(sunnyFace.id);
    await libraryRepo.setWallCoordinates(sunnyFace.id, 47.4979, 19.0402);

    final shadyCorner = await libraryRepo.createWall(riverside.id, 'Shady Corner');
    final shadyImagePath = imagePathFor('shady_corner');
    await File(
      shadyImagePath,
    ).writeAsBytes(await _wallImage(accent: const Color(0xFF29B6F6)), flush: true);
    await libraryRepo.attachPhotoToWall(shadyCorner.id, XFile(shadyImagePath), 1200, 1600);
    await libraryRepo.setWallCoordinates(shadyCorner.id, 47.5316, 19.0290);
    // left private (default visibility).

    // -----------------------------------------------------------------
    // Area 2: Buda Hills > Highlands > {Crimper Wall, Slab Wall}
    // -----------------------------------------------------------------
    final budaHills = await libraryRepo.createArea('Buda Hills');
    final highlands = await libraryRepo.createSector(budaHills.id, 'Highlands');

    final crimperWall = await libraryRepo.createWall(highlands.id, 'Crimper Wall');
    final crimperImagePath = imagePathFor('crimper_wall');
    await File(
      crimperImagePath,
    ).writeAsBytes(await _wallImage(accent: const Color(0xFFAB47BC)), flush: true);
    await libraryRepo.attachPhotoToWall(crimperWall.id, XFile(crimperImagePath), 1200, 1600);
    // private, no coordinates.

    final slabWall = await libraryRepo.createWall(highlands.id, 'Slab Wall');
    final slabImagePath = imagePathFor('slab_wall');
    await File(
      slabImagePath,
    ).writeAsBytes(await _wallImage(accent: const Color(0xFF66BB6A)), flush: true);
    await libraryRepo.attachPhotoToWall(slabWall.id, XFile(slabImagePath), 1200, 1600);
    // private, no coordinates.

    // -----------------------------------------------------------------
    // Logbook: log 2 ascents against Sunny Face's two routes.
    // -----------------------------------------------------------------
    final dbIds = await routeRepo.routeDbIdsByNumber(sunnyFace.id);
    await ascentsRepo.logAscent(
      routeId: dbIds[1]!,
      wallId: sunnyFace.id,
      climbedAt: DateTime.now().subtract(const Duration(days: 3)),
      style: AscentStyle.redpoint,
      notes: 'Sent it on the second try.',
    );
    await ascentsRepo.logAscent(
      routeId: dbIds[2]!,
      wallId: sunnyFace.id,
      climbedAt: DateTime.now().subtract(const Duration(days: 1)),
      style: AscentStyle.onsight,
    );

    return _SeedResult(sunnyFaceWallId: sunnyFace.id);
  } finally {
    // Close BEFORE app.main() opens its own connection to the same file.
    await seedDb.close();
  }
}

/// Pops the current screen via its own in-app back affordance -- the
/// canvas/detail's `topo-back-button` chevron if present, otherwise the
/// platform's default AppBar back button (tooltip 'Back') -- rather than a
/// raw `Navigator.pop`, which fights go_router's own declarative page
/// stack. Returns whether a back control was found and tapped.
Future<bool> _goBack(WidgetTester tester) async {
  final canvasBack = find.byKey(const Key('topo-back-button'));
  if (tester.any(canvasBack)) {
    await tester.tap(canvasBack);
    await tester.pumpAndSettle(const Duration(seconds: 2));
    return true;
  }
  final appBarBack = find.byTooltip('Back');
  if (tester.any(appBarBack)) {
    await tester.tap(appBarBack.first);
    await tester.pumpAndSettle(const Duration(seconds: 2));
    return true;
  }
  return false;
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('full walkthrough: every major screen, screenshotted', (tester) async {
    final docsDir = await getApplicationDocumentsDirectory();
    final seed = await _seed(
      (name) => p.join(docsDir.path, 'walkthrough_$name.png'),
    );

    final failures = <String>[];
    Future<void> step(String label, Future<void> Function() body) async {
      try {
        await body();
        debugPrint('WALKTHROUGH OK: $label');
      } catch (e, st) {
        failures.add('$label: $e');
        debugPrint('WALKTHROUGH FAILED: $label -> $e\n$st');
      }
    }

    app.main();
    await tester.pumpAndSettle(const Duration(seconds: 2));

    // ------------------------------------------------------------------
    // 00. Topos home.
    // ------------------------------------------------------------------
    await step('00-home-topos', () async {
      await tester.pumpAndSettle(const Duration(seconds: 1));
      await binding.takeScreenshot('00-home-topos');
    });

    // ------------------------------------------------------------------
    // 01. Search field active with "b".
    // ------------------------------------------------------------------
    await step('01-home-search-active', () async {
      final searchField = find.byKey(const Key('topos-search-field'));
      expect(tester.any(searchField), isTrue, reason: 'topos-search-field not found');
      await tester.tap(searchField);
      await tester.pumpAndSettle();
      await tester.enterText(searchField, 'b');
      await tester.pumpAndSettle(const Duration(seconds: 1));
      await binding.takeScreenshot('01-home-search-active');
      // Clear so subsequent steps see the full list again.
      await tester.enterText(searchField, '');
      await tester.pumpAndSettle(const Duration(seconds: 1));
    });

    // ------------------------------------------------------------------
    // 02. Filters sheet.
    // ------------------------------------------------------------------
    await step('02-topos-filter-sheet', () async {
      final filterButton = find.byKey(const Key('topos-filter-button'));
      expect(tester.any(filterButton), isTrue, reason: 'topos-filter-button not found');
      await tester.tap(filterButton);
      await tester.pumpAndSettle(const Duration(seconds: 1));
      await binding.takeScreenshot('02-topos-filter-sheet');
      // Dismiss the modal bottom sheet by tapping its scrim, well above
      // where the sheet's own content sits (it slides up from the bottom) --
      // avoids touching 'Clear' (which would reset the filter state).
      await tester.tapAt(const Offset(200, 80));
      await tester.pumpAndSettle(const Duration(seconds: 1));
    });

    // ------------------------------------------------------------------
    // 03/04/05. Topo canvas: view mode, draw mode, metadata sheet.
    // ------------------------------------------------------------------
    await step('03-topo-canvas-view + 04-draw + 05-metadata', () async {
      final topoItem = find.byKey(Key('topo-item-${seed.sunnyFaceWallId}'));
      expect(tester.any(topoItem), isTrue, reason: 'seeded topo-item not found on home');
      await tester.tap(topoItem);
      await tester.pumpAndSettle(const Duration(seconds: 2));
      await binding.takeScreenshot('03-topo-canvas-view');

      final modeToggle = find.byKey(const Key('topo-mode-toggle'));
      if (tester.any(modeToggle)) {
        await tester.tap(modeToggle);
        await tester.pumpAndSettle(const Duration(seconds: 1));
        await binding.takeScreenshot('04-topo-canvas-draw');

        // Draw mode starts with the route legend collapsed to a chip (see
        // `topo_canvas_screen.dart`'s `_LegendChip` doc: "shown instead of
        // the full card while DrawMode.draw is active") -- expand it first
        // so the per-route `topo-route-legend-item-<id>` rows are reachable.
        final legendChip = find.byKey(const Key('topo-route-legend-chip'));
        if (tester.any(legendChip)) {
          await tester.tap(legendChip);
          await tester.pumpAndSettle(const Duration(seconds: 1));
        }

        final legendItem = find.byKey(Key('topo-route-legend-item-${route1LocalId()}'));
        if (tester.any(legendItem)) {
          await tester.tap(legendItem);
          await tester.pumpAndSettle(const Duration(seconds: 1));
          final metaButton = find.byKey(const Key('topo-edit-metadata-button'));
          if (tester.any(metaButton)) {
            await tester.tap(metaButton);
            await tester.pumpAndSettle(const Duration(seconds: 1));
            await binding.takeScreenshot('05-route-metadata-sheet');
            final cancel = find.byKey(const Key('topo-meta-cancel'));
            if (tester.any(cancel)) {
              await tester.tap(cancel);
              await tester.pumpAndSettle(const Duration(seconds: 1));
            }
          }
        }
      }

      // Back to home via the canvas's own back chevron (never a raw
      // Navigator.pop -- this route is a declarative go_router page, and
      // the in-app back button is the correct way to pop it).
      final backButton = find.byKey(const Key('topo-back-button'));
      if (tester.any(backButton)) {
        await tester.tap(backButton);
        await tester.pumpAndSettle(const Duration(seconds: 2));
      }
    });

    // ------------------------------------------------------------------
    // 06/07. Community feed + map.
    // ------------------------------------------------------------------
    await step('06-community-feed + 07-community-map', () async {
      // Map is now a separate, permanent bottom-nav tab (`nav-tab-map`)
      // rather than a compass button on the Topos home AppBar -- Feed is
      // likewise its own permanent tab (`nav-tab-feed`) rather than an
      // in-screen toggle.
      final mapTab = find.byKey(const Key('nav-tab-map'));
      expect(tester.any(mapTab), isTrue, reason: 'nav-tab-map not found');
      await tester.tap(mapTab);
      await tester.pumpAndSettle(const Duration(seconds: 1));
      // flutter_map's tile fade-in never settles -- pump fixed durations.
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));
      await binding.takeScreenshot('07-community-map');

      final feedTab = find.byKey(const Key('nav-tab-feed'));
      if (tester.any(feedTab)) {
        await tester.tap(feedTab);
        await tester.pumpAndSettle(const Duration(seconds: 1));
        await binding.takeScreenshot('06-community-feed');
      }
    });

    // ------------------------------------------------------------------
    // 08. Community topo detail (from the feed).
    // ------------------------------------------------------------------
    await step('08-community-topo-detail', () async {
      // Already on the Feed tab from the previous step -- no toggle needed.
      final feedRow = find.byKey(Key('community-topo-row-${seed.sunnyFaceWallId}'));
      expect(tester.any(feedRow), isTrue, reason: 'seeded community feed row not found');
      await tester.tap(feedRow);
      await tester.pumpAndSettle(const Duration(seconds: 2));
      await tester.pumpAndSettle(const Duration(milliseconds: 600));
      await tester.pump(const Duration(seconds: 1));
      await binding.takeScreenshot('08-community-topo-detail');

      // The embedded read-only canvas's own back chevron doubles as this
      // screen's back navigation (see CommunityTopoDetailScreen's doc).
      await _goBack(tester);
    });

    // Return to Topos home explicitly (in case the previous step left us on
    // the Feed/Map bottom-nav branch rather than Topos). The persistent
    // bottom nav means switching "back" to Topos is a `nav-tab-topos` tap,
    // not a back-navigation pop (an `IndexedStack` branch has nothing left
    // to pop once its own pushed routes are gone) -- fall back to the old
    // pop-based retry loop only if that tab key is ever missing.
    await step('back-to-home', () async {
      final toposTab = find.byKey(const Key('nav-tab-topos'));
      if (tester.any(toposTab)) {
        await tester.tap(toposTab);
        await tester.pumpAndSettle(const Duration(seconds: 1));
        return;
      }
      var attempts = 0;
      // `topos-filter-button` only exists on the Topos home screen, so use
      // it (rather than the removed compass button) to detect we're back
      // home.
      while (!tester.any(find.byKey(const Key('topos-filter-button'))) && attempts < 5) {
        final popped = await _goBack(tester);
        if (!popped) break;
        attempts++;
      }
    });

    // ------------------------------------------------------------------
    // 09. Logbook.
    // ------------------------------------------------------------------
    await step('09-logbook', () async {
      // Logbook's entry point moved off the Topos home AppBar onto the
      // Feed screen's own AppBar (`feed-logbook-button`) -- go there first.
      final feedTab = find.byKey(const Key('nav-tab-feed'));
      expect(tester.any(feedTab), isTrue, reason: 'nav-tab-feed not found');
      await tester.tap(feedTab);
      await tester.pumpAndSettle(const Duration(seconds: 1));

      final logbookButton = find.byKey(const Key('feed-logbook-button'));
      expect(tester.any(logbookButton), isTrue, reason: 'feed-logbook-button not found');
      await tester.tap(logbookButton);
      await tester.pumpAndSettle(const Duration(seconds: 2));
      await tester.pumpAndSettle(const Duration(milliseconds: 600));
      await tester.pump(const Duration(seconds: 1));
      await binding.takeScreenshot('09-logbook');

      await _goBack(tester);
    });

    // ------------------------------------------------------------------
    // 10. Organize > Areas.
    // ------------------------------------------------------------------
    await step('10-areas', () async {
      final organizeButton = find.byKey(const Key('topos-organize'));
      expect(tester.any(organizeButton), isTrue, reason: 'topos-organize not found');
      await tester.tap(organizeButton);
      await tester.pumpAndSettle(const Duration(seconds: 2));
      await tester.pumpAndSettle(const Duration(milliseconds: 600));
      await tester.pump(const Duration(seconds: 1));
      await binding.takeScreenshot('10-areas');

      await _goBack(tester);
    });

    // ------------------------------------------------------------------
    // 11. Set-location picker (from a topo's overflow menu).
    // ------------------------------------------------------------------
    await step('11-set-location', () async {
      final menuButton = find.byKey(Key('topo-menu-${seed.sunnyFaceWallId}'));
      expect(tester.any(menuButton), isTrue, reason: 'seeded topo-menu not found');
      await tester.tap(menuButton);
      await tester.pumpAndSettle(const Duration(seconds: 1));

      final setLocationItem = find.byKey(Key('topo-set-location-${seed.sunnyFaceWallId}'));
      expect(tester.any(setLocationItem), isTrue, reason: 'topo-set-location item not found');
      await tester.tap(setLocationItem);
      await tester.pumpAndSettle(const Duration(seconds: 2));
      await binding.takeScreenshot('11-set-location');

      final cancel = find.byKey(const Key('set-location-cancel'));
      if (tester.any(cancel)) {
        await tester.tap(cancel);
        await tester.pumpAndSettle(const Duration(seconds: 1));
      }
    });

    debugPrint(
      failures.isEmpty
          ? 'WALKTHROUGH: all steps succeeded'
          : 'WALKTHROUGH: ${failures.length} step(s) failed:\n${failures.join('\n')}',
    );
  });
}

/// Route 1's stable local id, as assigned by [RouteRepository.loadRoutes]
/// (sequential `1..n` in `number` order — see that method's doc). Route 1
/// was seeded first with `number: 1`, so it is always local id `1` once
/// [DrawController.loadForWall] reloads it inside the running app.
int route1LocalId() => 1;
