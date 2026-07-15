// Visual review flow for the Community MAP's "my position" marker
// (`community-map-my-location`, see community_screen.dart's `_MapView`)
// alongside the existing topo pin markers.
//
// `app.main()` builds its own `ProviderContainer` internally (see
// `lib/main.dart`) and exposes no override seam, so — unlike
// `map_review_test.dart`, which drives `app.main()` directly — this flow
// reimplements main()'s boot sequence by hand (Supabase.initialize, the
// photoFilesProvider docs-path warm, then `runApp`'s equivalent via
// `tester.pumpWidget`) so it can inject a `ProviderContainer` with
// `locationServiceProvider` overridden to a fake returning a FIXED Budapest
// position. That's what makes the "you are here" marker deterministic:
// there is no real GPS in the simulator, and `myLocationProvider` (see
// community_providers.dart) resolves to `null` (no marker) whenever the
// underlying `LocationService.currentLocation()` can't produce a fix.
//
// DB seeding mirrors `map_review_test.dart` exactly (same 3 Budapest-area
// crags, same real-decodable-PNG-plus-direct-repo-writes seam, seed
// connection closed before this flow opens its own) — duplicated here
// rather than imported since the original's seeding helpers are private
// top-level functions in that file.
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:climbtopo/app/app.dart';
import 'package:climbtopo/core/config/supabase_config.dart';
import 'package:climbtopo/core/db/app_database.dart';
import 'package:climbtopo/core/db/database_provider.dart';
import 'package:climbtopo/core/location/location_service.dart';
import 'package:climbtopo/features/library/data/library_crud_repository.dart';

/// A fixed, always-succeeding [LocationService] fake — no platform channel,
/// no permission prompts, no simulated-CoreLocation flakiness. Returns a
/// position a few km from the seeded crags' centroid so it lands inside the
/// map's default-zoom viewport (flutter_map culls off-screen markers).
class _FixedLocationService implements LocationService {
  const _FixedLocationService(this._location);

  final DeviceLocation _location;

  @override
  Future<DeviceLocation?> currentLocation() async => _location;
}

/// Same gradient/grid/shapes recipe as `map_review_test.dart`'s
/// `_generateWallImage`.
Future<Uint8List> _generateWallImage({
  required int width,
  required int height,
  required Color accent,
}) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  final size = Size(width.toDouble(), height.toDouble());
  final rect = Rect.fromLTWH(0, 0, size.width, size.height);

  final gradient = ui.Gradient.linear(
    rect.topLeft,
    rect.bottomRight,
    [const Color(0xFF1B5E20), accent, const Color(0xFFB71C1C)],
    const [0.0, 0.5, 1.0],
  );
  canvas.drawRect(rect, Paint()..shader = gradient);

  final gridPaint = Paint()
    ..color = Colors.white.withValues(alpha: 0.6)
    ..strokeWidth = 3;
  for (var x = 0; x < width; x += 100) {
    canvas.drawLine(
      Offset(x.toDouble(), 0),
      Offset(x.toDouble(), size.height),
      gridPaint,
    );
  }
  for (var y = 0; y < height; y += 100) {
    canvas.drawLine(
      Offset(0, y.toDouble()),
      Offset(size.width, y.toDouble()),
      gridPaint,
    );
  }

  final picture = recorder.endRecording();
  final image = await picture.toImage(width, height);
  final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
  return byteData!.buffer.asUint8List();
}

/// Same three crags as `map_review_test.dart`.
const List<(String name, double lat, double lng, Color accent)> _mapCrags = [
  ('Map Loc Crag Danube', 47.4979, 19.0402, Color(0xFFF9A825)),
  ('Map Loc Crag Buda Hills', 47.5316, 19.0290, Color(0xFF29B6F6)),
  ('Map Loc Crag Gellert', 47.4813, 19.0530, Color(0xFFAB47BC)),
];

/// A fixed "my position" a little south-west of the crags' centroid but
/// still well within the default zoom-11 viewport around it.
const DeviceLocation _myFixedLocation = (latitude: 47.505, longitude: 19.040);

/// Seeds the three [_mapCrags] directly into the app's real sqlite file,
/// deleting any existing file first. Identical approach to
/// `map_review_test.dart`'s `_seedMapReviewTopos`.
Future<List<String>> _seedMapLocationReviewTopos(
  String Function(String name) imagePathFor,
) async {
  final docsDir = await getApplicationDocumentsDirectory();
  final dbFile = File(p.join(docsDir.path, 'climbtopo.sqlite'));
  if (await dbFile.exists()) {
    await dbFile.delete();
  }

  final seedDb = AppDatabase(NativeDatabase(dbFile));
  final wallIds = <String>[];
  try {
    int nowMs() => DateTime.now().millisecondsSinceEpoch;
    final repo = LibraryCrudRepository(seedDb, nowMs: nowMs);

    for (final (name, lat, lng, accent) in _mapCrags) {
      final wallId = await repo.createTopo(name);

      final imagePath = imagePathFor(name);
      final pngBytes = await _generateWallImage(
        width: 1200,
        height: 1600,
        accent: accent,
      );
      await File(imagePath).writeAsBytes(pngBytes, flush: true);
      await repo.attachPhotoToWall(wallId, imagePath, 1200, 1600);

      await repo.publishTopo(wallId);
      await repo.setWallCoordinates(wallId, lat, lng);

      wallIds.add(wallId);
    }

    return wallIds;
  } finally {
    // Close BEFORE this flow opens its own connection to the same file.
    await seedDb.close();
  }
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('map location review: my-position marker alongside topo pins', (
    tester,
  ) async {
    final docsDir = await getApplicationDocumentsDirectory();

    final wallIds = await _seedMapLocationReviewTopos(
      (name) => p.join(
        docsDir.path,
        'map_loc_review_${name.toLowerCase().replaceAll(' ', '_')}.png',
      ),
    );
    expect(wallIds, hasLength(3));

    // Reimplementation of `lib/main.dart`'s boot sequence (see file doc),
    // with `locationServiceProvider` overridden to a fixed fake so the
    // "you are here" marker resolves deterministically instead of depending
    // on simulated CoreLocation (there is no real GPS in the simulator).
    try {
      await Supabase.initialize(
        url: supabaseUrl,
        publishableKey: supabaseAnonKey,
        authOptions: const FlutterAuthClientOptions(
          authFlowType: AuthFlowType.pkce,
        ),
      );
    } catch (e) {
      debugPrint('Supabase.initialize failed; continuing without it: $e');
    }

    final container = ProviderContainer(
      overrides: [
        locationServiceProvider.overrideWithValue(
          const _FixedLocationService(_myFixedLocation),
        ),
      ],
    );
    addTearDown(container.dispose);
    await container.read(photoFilesProvider).warmDocsPath();

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const ClimbTopoApp(),
      ),
    );
    await tester.pumpAndSettle(const Duration(seconds: 2));

    // ------------------------------------------------------------------
    // Navigate: Topos home -> Community (feed tab by default).
    // ------------------------------------------------------------------
    final communityButton = find.byKey(const Key('home-community-button'));
    expect(
      tester.any(communityButton),
      isTrue,
      reason: 'home-community-button not found',
    );
    await tester.tap(communityButton);
    await tester.pumpAndSettle(const Duration(seconds: 1));

    // ------------------------------------------------------------------
    // Switch to the Map tab.
    // ------------------------------------------------------------------
    final mapToggle = find.byKey(const Key('community-map-toggle'));
    expect(
      tester.any(mapToggle),
      isTrue,
      reason: 'community-map-toggle not found',
    );
    await tester.tap(mapToggle);
    // Do NOT pumpAndSettle: flutter_map's tile fade-in animation never
    // settles, and myLocationProvider's FutureProvider needs a few pumps to
    // resolve too. Pump fixed durations instead.
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));

    // ------------------------------------------------------------------
    // 03. Community map with my-position marker alongside the 3 topo pins.
    // ------------------------------------------------------------------
    for (final wallId in wallIds) {
      final marker = find.byKey(Key('community-map-marker-$wallId'));
      expect(
        tester.any(marker),
        isTrue,
        reason: 'community-map-marker-$wallId not found',
      );
    }
    final myLocationMarker = find.byKey(
      const Key('community-map-my-location'),
    );
    expect(
      tester.any(myLocationMarker),
      isTrue,
      reason: 'community-map-my-location marker not found',
    );
    await binding.takeScreenshot('map-03-my-location');
  });
}
