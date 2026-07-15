import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:climbtopo/app/theme.dart';
import 'package:climbtopo/core/db/app_database.dart';
import 'package:climbtopo/core/db/database_provider.dart';
import 'package:climbtopo/core/grades/grade_system.dart';
import 'package:climbtopo/core/location/location_service.dart';
import 'package:climbtopo/features/account/application/auth_providers.dart';
import 'package:climbtopo/features/account/data/auth_repository.dart';
import 'package:climbtopo/features/library/application/library_providers.dart';
import 'package:climbtopo/features/library/data/library_crud_repository.dart';
import 'package:climbtopo/features/library/presentation/topos_screen.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:image/image.dart' as img;
// Not exported from package:image's barrel (see photo_gps_test.dart's
// identical import for why) -- needed here only to hand-build a geotagged
// JPEG fixture for the A7 GPS-capture test below.
import 'package:image/src/util/rational.dart';
import 'package:image_picker/image_picker.dart';

/// A minimal-but-real 1x1 transparent PNG (base64), used to give
/// `ui.instantiateImageCodec` real bytes to decode in the "New topo" flow
/// tests, rather than a fake/mocked decode step.
final _tinyPngBytes = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY'
  '42YAAAAASUVORK5CYII=',
);

/// Builds real JPEG bytes for a tiny image, optionally carrying EXIF GPS
/// tags for [latitude]/[longitude] (mirrors `photo_gps_test.dart`'s
/// identical fixture builder). Used by the A7 GPS-capture group below --
/// unlike the width/height-decode tests above, PNG can't carry EXIF here
/// (this version of package:image doesn't parse PNG's `eXIf` chunk), so
/// this fixture is a JPEG instead of `_tinyPngBytes`.
List<int> _buildJpegBytes({double? latitude, double? longitude}) {
  final image = img.Image(width: 4, height: 4);

  if (latitude != null && longitude != null) {
    final gps = image.exif.gpsIfd;
    _setDms(gps, 'GPSLatitude', latitude, positiveRef: 'N', negativeRef: 'S');
    _setDms(
      gps,
      'GPSLongitude',
      longitude,
      positiveRef: 'E',
      negativeRef: 'W',
    );
  }

  return img.encodeJpg(image);
}

void _setDms(
  img.IfdDirectory gps,
  String tagPrefix,
  double decimal, {
  required String positiveRef,
  required String negativeRef,
}) {
  final ref = decimal < 0 ? negativeRef : positiveRef;
  final absolute = decimal.abs();
  final degrees = absolute.floor();
  final minutesFull = (absolute - degrees) * 60;
  final minutes = minutesFull.floor();
  final secondsFull = (minutesFull - minutes) * 60;
  final secondsNumerator = (secondsFull * 10000).round();

  gps['${tagPrefix}Ref'] = img.IfdValueAscii(ref);
  gps[tagPrefix] = img.IfdValueRational.list([
    Rational(degrees, 1),
    Rational(minutes, 1),
    Rational(secondsNumerator, 10000),
  ]);
}

/// Builds a [ProviderContainer] wired to a fresh in-memory database and
/// registers teardown of both the container and the database connection.
///
/// addTearDown runs LIFO, so `db.close` is registered first: the container
/// must be disposed (cancelling Riverpod's live watch subscriptions) BEFORE
/// the underlying Drift connection is closed, otherwise closing the database
/// out from under a still-active watch stream hangs waiting on the
/// background executor isolate. (Mirrors
/// `test/features/library/presentation/areas_screen_test.dart`.)
///
/// [locationService], when given, overrides `locationServiceProvider` (see
/// `_handleNewTopo`'s no-EXIF device-location fallback) with a
/// [_FakeLocationService] so a test can script the device position without
/// touching real geolocation. Tests that don't pass it leave
/// `locationServiceProvider` un-overridden — the real
/// `GeolocatorLocationService` still never throws under `flutter_test` (no
/// platform channel is registered, so its internal try/catch resolves to
/// `null`), so every pre-existing "no EXIF GPS" test is unaffected.
ProviderContainer _makeContainer({LocationService? locationService}) {
  final db = AppDatabase(NativeDatabase.memory());
  final container = ProviderContainer(
    overrides: [
      appDatabaseProvider.overrideWithValue(db),
      nowMsProvider.overrideWithValue(() => 1000),
      if (locationService != null)
        locationServiceProvider.overrideWithValue(locationService),
    ],
  );
  addTearDown(db.close);
  addTearDown(container.dispose);
  return container;
}

/// A [LocationService] double that resolves to whatever fixed [result] it
/// was constructed with — no real geolocator call, ever, under
/// `flutter_test`. Mirrors `community_screen_test.dart`'s
/// `_FakeLocationService`.
class _FakeLocationService implements LocationService {
  const _FakeLocationService(this.result);

  final DeviceLocation? result;

  @override
  Future<DeviceLocation?> currentLocation() async => result;
}

/// Wraps [screen] in a real (minimal) [GoRouter] so `context.push` calls
/// (Organize -> `/areas`, row tap -> `/walls/:wallId`, and the "New topo"
/// flow's post-create push) resolve against a real `GoRouter` instead of
/// throwing for lack of one. The pushed-to routes only need to exist, not
/// look like anything real.
Widget _wrap(ProviderContainer container, Widget screen) {
  final router = GoRouter(
    initialLocation: '/',
    routes: [
      GoRoute(path: '/', builder: (context, state) => screen),
      GoRoute(
        path: '/walls/:wallId',
        builder: (context, state) => const SizedBox(),
      ),
      GoRoute(path: '/areas', builder: (context, state) => const SizedBox()),
    ],
  );
  return UncontrolledProviderScope(
    container: container,
    child: MaterialApp.router(theme: MasiTheme.light, routerConfig: router),
  );
}

/// Advances real asynchronous work (Drift's in-memory background executor,
/// image decode, and any other awaited futures) that would otherwise never
/// make progress under `testWidgets`' fake-async clock, then pumps to flush
/// the resulting Riverpod-triggered rebuilds and any in-flight
/// dialog/route transitions. Mirrors `areas_screen_test.dart`'s `_drain`.
Future<void> _drain(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 30));
  }
  await tester.pumpAndSettle();
}

/// Like [_drain], but deliberately WITHOUT the trailing `pumpAndSettle()`:
/// used by the "G5: SnackBar" group below to observe `_handleNewTopo`'s
/// GPS-outcome [SnackBar] WHILE it's still showing. A `pumpAndSettle()`
/// pumps forward until no more frames are scheduled, which for a SnackBar
/// means running its entrance animation, its full `duration` (4s default),
/// AND its exit animation to completion -- so calling it here would settle
/// the SnackBar fully off-screen before a `find.text` assertion ever ran.
/// This still performs the SAME number of real-delay+pump iterations as two
/// back-to-back [_drain] calls (the amount every other test in this file
/// already relies on to let `_handleNewTopo`'s real Drift/file-IO work
/// complete), just without ending in a settle.
Future<void> _drainNoSettle(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 30));
  }
}

/// Runs [body] (which performs real Drift async work) under the real event
/// loop so its awaits actually complete, capturing the result.
Future<T> _dbWork<T>(WidgetTester tester, Future<T> Function() body) async {
  late T result;
  await tester.runAsync(() async {
    result = await body();
  });
  return result;
}

/// A [LibraryCrudRepository] whose [setWallCoordinates] always throws,
/// leaving every other method (including [createTopo]/[attachPhotoToWall])
/// backed by the real implementation against [db]. Used to prove that
/// `_handleNewTopo`'s best-effort GPS capture is isolated: a coords-write
/// failure must never abort the topo/photo creation that already committed
/// before it runs, nor block the navigation that follows it.
class _ThrowingSetCoordinatesRepository extends LibraryCrudRepository {
  _ThrowingSetCoordinatesRepository(super.db, {required super.nowMs});

  @override
  Future<void> setWallCoordinates(
    String wallId,
    double latitude,
    double longitude,
  ) {
    throw Exception('setWallCoordinates boom (test)');
  }
}

void main() {
  group('A1: empty state', () {
    testWidgets(
      'no topos shows topos-empty-state and the topos-new-topo button',
      (tester) async {
        final container = _makeContainer();

        await tester.pumpWidget(_wrap(container, const ToposScreen()));
        await _drain(tester);

        expect(find.byKey(const Key('topos-empty-state')), findsOneWidget);
        expect(find.text('No topos yet'), findsOneWidget);
        expect(find.byKey(const Key('topos-new-topo')), findsOneWidget);
      },
    );
  });

  group('A2: populated list rendering', () {
    testWidgets(
      'renders one row per topo with correct name/subtitle text; a null '
      'thumbnailPath renders the gradient fallback, not a broken image',
      (tester) async {
        final db = AppDatabase(NativeDatabase.memory());
        addTearDown(db.close);
        final container = ProviderContainer(
          overrides: [
            appDatabaseProvider.overrideWithValue(db),
            nowMsProvider.overrideWithValue(() => 1000),
            toposProvider.overrideWith(
              (ref) => Stream.value(const [
                TopoRef(
                  wallId: 'wall-1',
                  name: 'Topo One',
                  thumbnailPath: null,
                  routeCount: 0,
                  createdAt: 1000,
                ),
                TopoRef(
                  wallId: 'wall-2',
                  name: 'Topo Two',
                  thumbnailPath: null,
                  routeCount: 3,
                  createdAt: 900,
                ),
              ]),
            ),
          ],
        );
        addTearDown(container.dispose);

        await tester.pumpWidget(_wrap(container, const ToposScreen()));
        await _drain(tester);

        expect(find.byKey(const Key('topo-item-wall-1')), findsOneWidget);
        expect(find.byKey(const Key('topo-item-wall-2')), findsOneWidget);
        expect(find.text('Topo One'), findsOneWidget);
        expect(find.text('Topo Two'), findsOneWidget);
        expect(find.text('0 routes'), findsOneWidget);
        expect(find.text('3 routes'), findsOneWidget);
        // Neither row has a thumbnailPath, so no Image widget (which could
        // error-out/show a broken-image icon) should be present at all —
        // only the gradient fallback container.
        expect(find.byType(Image), findsNothing);
      },
    );
  });

  group('A3: delete confirm flow', () {
    testWidgets(
      'confirming delete calls softDeleteWall via the real repo and the '
      'row disappears once the stream re-emits',
      (tester) async {
        final container = _makeContainer();
        final wallId = await _dbWork(
          tester,
          () => container
              .read(libraryCrudRepositoryProvider)
              .createTopo('Roof Wall'),
        );

        await tester.pumpWidget(_wrap(container, const ToposScreen()));
        await _drain(tester);

        expect(find.text('Roof Wall'), findsOneWidget);

        await tester.tap(find.byKey(Key('topo-menu-$wallId')));
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(Key('topo-delete-$wallId')));
        await tester.pumpAndSettle();

        expect(find.text('Delete?'), findsOneWidget);

        await tester.tap(find.byKey(Key('topo-delete-confirm-$wallId')));
        await _drain(tester);

        expect(find.text('Roof Wall'), findsNothing);
        expect(find.byKey(const Key('topos-empty-state')), findsOneWidget);

        final topos = await _dbWork(
          tester,
          () =>
              container.read(libraryCrudRepositoryProvider).watchTopos().first,
        );
        expect(topos, isEmpty);
      },
    );
  });

  group('A4: rename flow', () {
    testWidgets(
      'entering a new name and submitting calls renameWall via the real '
      'repo and updates the displayed name',
      (tester) async {
        final container = _makeContainer();
        final wallId = await _dbWork(
          tester,
          () => container
              .read(libraryCrudRepositoryProvider)
              .createTopo('Old Name'),
        );

        await tester.pumpWidget(_wrap(container, const ToposScreen()));
        await _drain(tester);

        expect(find.text('Old Name'), findsOneWidget);

        await tester.tap(find.byKey(Key('topo-menu-$wallId')));
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(Key('topo-rename-$wallId')));
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('crud-name-field')), findsOneWidget);

        await tester.enterText(
          find.byKey(const Key('crud-name-field')),
          'New Name',
        );
        await tester.pump();
        await tester.tap(find.byKey(const Key('crud-name-submit')));
        await tester.pumpAndSettle();
        await _drain(tester);

        expect(find.text('New Name'), findsOneWidget);
        expect(find.text('Old Name'), findsNothing);
      },
    );
  });

  group('#20: rename dialog keyboard dismissal', () {
    testWidgets(
      'submitting the rename dialog drops focus/keyboard, not just the '
      'dialog',
      (tester) async {
        final container = _makeContainer();
        final wallId = await _dbWork(
          tester,
          () => container
              .read(libraryCrudRepositoryProvider)
              .createTopo('Old Name'),
        );

        await tester.pumpWidget(_wrap(container, const ToposScreen()));
        await _drain(tester);

        await tester.tap(find.byKey(Key('topo-menu-$wallId')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(Key('topo-rename-$wallId')));
        await tester.pumpAndSettle();

        await tester.enterText(
          find.byKey(const Key('crud-name-field')),
          'New Name',
        );
        await tester.pump();
        expect(tester.testTextInput.hasAnyClients, isTrue);

        await tester.tap(find.byKey(const Key('crud-name-submit')));
        await tester.pumpAndSettle();

        expect(
          tester.testTextInput.hasAnyClients,
          isFalse,
          reason: 'submitting the rename dialog must dismiss the keyboard',
        );
      },
    );

    testWidgets(
      'cancelling the rename dialog drops focus/keyboard, not just the '
      'dialog',
      (tester) async {
        final container = _makeContainer();
        final wallId = await _dbWork(
          tester,
          () => container
              .read(libraryCrudRepositoryProvider)
              .createTopo('Old Name'),
        );

        await tester.pumpWidget(_wrap(container, const ToposScreen()));
        await _drain(tester);

        await tester.tap(find.byKey(Key('topo-menu-$wallId')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(Key('topo-rename-$wallId')));
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(const Key('crud-name-field')));
        await tester.pump();
        expect(tester.testTextInput.hasAnyClients, isTrue);

        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();

        expect(
          tester.testTextInput.hasAnyClients,
          isFalse,
          reason: 'cancelling the rename dialog must dismiss the keyboard',
        );
      },
    );
  });

  group('A5: organize action', () {
    testWidgets('topos-organize is present in the trailing app-bar slot', (
      tester,
    ) async {
      final container = _makeContainer();

      await tester.pumpWidget(_wrap(container, const ToposScreen()));
      await _drain(tester);

      expect(
        find.descendant(
          of: find.byType(AppBar),
          matching: find.byKey(const Key('topos-organize')),
        ),
        findsOneWidget,
      );
    });
  });

  group('A6: new-topo flow', () {
    testWidgets(
      'cancelling the photo-source sheet is a no-op: no topo is created',
      (tester) async {
        final container = _makeContainer();

        await tester.pumpWidget(
          _wrap(
            container,
            ToposScreen(
              photoSourcePicker: (context) async => null,
              photoPicker: (source) async =>
                  throw StateError('must not be called after cancel'),
            ),
          ),
        );
        await _drain(tester);

        await tester.tap(find.byKey(const Key('topos-new-topo')));
        await _drain(tester);

        expect(find.byKey(const Key('topos-empty-state')), findsOneWidget);
        final topos = await _dbWork(
          tester,
          () =>
              container.read(libraryCrudRepositoryProvider).watchTopos().first,
        );
        expect(topos, isEmpty);
      },
    );

    testWidgets('picking a real photo creates exactly one topo with a non-null '
        'thumbnailPath, via the real repo (attachPhotoToWall really ran)', (
      tester,
    ) async {
      final container = _makeContainer();
      late Directory tempDir;
      late File pngFile;
      await tester.runAsync(() async {
        tempDir = await Directory.systemTemp.createTemp('topos_screen_test');
        pngFile = File('${tempDir.path}/photo.png');
        await pngFile.writeAsBytes(_tinyPngBytes);
      });
      addTearDown(() {
        if (tempDir.existsSync()) {
          tempDir.deleteSync(recursive: true);
        }
      });

      await tester.pumpWidget(
        _wrap(
          container,
          ToposScreen(
            photoSourcePicker: (context) async => ImageSource.gallery,
            photoPicker: (source) async => XFile(pngFile.path),
          ),
        ),
      );
      await _drain(tester);

      await tester.tap(find.byKey(const Key('topos-new-topo')));
      await _drain(tester);
      await _drain(tester);

      final topos = await _dbWork(
        tester,
        () => container.read(libraryCrudRepositoryProvider).watchTopos().first,
      );
      expect(topos.length, 1);
      expect(topos.single.thumbnailPath, isNotNull);
    });

    testWidgets(
      'a picked photo with EXIF GPS sets the new topo\'s wall coordinates '
      '(reusing the SAME photoPicker seam, no native picker touched)',
      (tester) async {
        final container = _makeContainer();
        late Directory tempDir;
        late File jpegFile;
        await tester.runAsync(() async {
          tempDir = await Directory.systemTemp.createTemp(
            'topos_screen_gps_test',
          );
          jpegFile = File('${tempDir.path}/geotagged.jpg');
          await jpegFile.writeAsBytes(
            _buildJpegBytes(latitude: 47.4979, longitude: 19.0402),
          );
        });
        addTearDown(() {
          if (tempDir.existsSync()) {
            tempDir.deleteSync(recursive: true);
          }
        });

        await tester.pumpWidget(
          _wrap(
            container,
            ToposScreen(
              photoSourcePicker: (context) async => ImageSource.gallery,
              photoPicker: (source) async => XFile(jpegFile.path),
            ),
          ),
        );
        await _drain(tester);

        await tester.tap(find.byKey(const Key('topos-new-topo')));
        await _drain(tester);
        await _drain(tester);

        final topos = await _dbWork(
          tester,
          () =>
              container.read(libraryCrudRepositoryProvider).watchTopos().first,
        );
        expect(topos.length, 1);

        final wall = await _dbWork(
          tester,
          () => (container.read(appDatabaseProvider).select(
            container.read(appDatabaseProvider).walls,
          )..where((t) => t.id.equals(topos.single.wallId))).getSingle(),
        );
        expect(wall.latitude, closeTo(47.4979, 1e-4));
        expect(wall.longitude, closeTo(19.0402, 1e-4));
      },
    );

    testWidgets(
      'a picked photo with NO EXIF GPS leaves the new topo\'s wall '
      'coordinates null, no crash',
      (tester) async {
        final container = _makeContainer();
        late Directory tempDir;
        late File jpegFile;
        await tester.runAsync(() async {
          tempDir = await Directory.systemTemp.createTemp(
            'topos_screen_no_gps_test',
          );
          jpegFile = File('${tempDir.path}/no-gps.jpg');
          await jpegFile.writeAsBytes(_buildJpegBytes());
        });
        addTearDown(() {
          if (tempDir.existsSync()) {
            tempDir.deleteSync(recursive: true);
          }
        });

        await tester.pumpWidget(
          _wrap(
            container,
            ToposScreen(
              photoSourcePicker: (context) async => ImageSource.gallery,
              photoPicker: (source) async => XFile(jpegFile.path),
            ),
          ),
        );
        await _drain(tester);

        await tester.tap(find.byKey(const Key('topos-new-topo')));
        await _drain(tester);
        await _drain(tester);

        expect(tester.takeException(), isNull);
        final topos = await _dbWork(
          tester,
          () =>
              container.read(libraryCrudRepositoryProvider).watchTopos().first,
        );
        expect(topos.length, 1);

        final wall = await _dbWork(
          tester,
          () => (container.read(appDatabaseProvider).select(
            container.read(appDatabaseProvider).walls,
          )..where((t) => t.id.equals(topos.single.wallId))).getSingle(),
        );
        expect(wall.latitude, isNull);
        expect(wall.longitude, isNull);
      },
    );

    testWidgets(
      'B-ii-1: a picked photo with NO EXIF GPS + a device location '
      'available falls back to it for the new topo\'s wall coordinates',
      (tester) async {
        final container = _makeContainer(
          locationService: const _FakeLocationService((
            latitude: 47.4979,
            longitude: 19.0402,
          )),
        );
        late Directory tempDir;
        late File jpegFile;
        await tester.runAsync(() async {
          tempDir = await Directory.systemTemp.createTemp(
            'topos_screen_device_fallback_test',
          );
          jpegFile = File('${tempDir.path}/no-gps.jpg');
          await jpegFile.writeAsBytes(_buildJpegBytes());
        });
        addTearDown(() {
          if (tempDir.existsSync()) {
            tempDir.deleteSync(recursive: true);
          }
        });

        await tester.pumpWidget(
          _wrap(
            container,
            ToposScreen(
              photoSourcePicker: (context) async => ImageSource.gallery,
              photoPicker: (source) async => XFile(jpegFile.path),
            ),
          ),
        );
        await _drain(tester);

        await tester.tap(find.byKey(const Key('topos-new-topo')));
        await _drain(tester);
        await _drain(tester);

        expect(tester.takeException(), isNull);
        final topos = await _dbWork(
          tester,
          () =>
              container.read(libraryCrudRepositoryProvider).watchTopos().first,
        );
        expect(topos.length, 1);

        final wall = await _dbWork(
          tester,
          () => (container.read(appDatabaseProvider).select(
            container.read(appDatabaseProvider).walls,
          )..where((t) => t.id.equals(topos.single.wallId))).getSingle(),
        );
        expect(wall.latitude, closeTo(47.4979, 1e-9));
        expect(wall.longitude, closeTo(19.0402, 1e-9));
      },
    );

    testWidgets(
      'B-ii-2: a picked photo with NO EXIF GPS + device location denied/'
      'unavailable (null) leaves the new topo\'s wall coordinates null, '
      'no crash',
      (tester) async {
        final container = _makeContainer(
          locationService: const _FakeLocationService(null),
        );
        late Directory tempDir;
        late File jpegFile;
        await tester.runAsync(() async {
          tempDir = await Directory.systemTemp.createTemp(
            'topos_screen_device_denied_test',
          );
          jpegFile = File('${tempDir.path}/no-gps.jpg');
          await jpegFile.writeAsBytes(_buildJpegBytes());
        });
        addTearDown(() {
          if (tempDir.existsSync()) {
            tempDir.deleteSync(recursive: true);
          }
        });

        await tester.pumpWidget(
          _wrap(
            container,
            ToposScreen(
              photoSourcePicker: (context) async => ImageSource.gallery,
              photoPicker: (source) async => XFile(jpegFile.path),
            ),
          ),
        );
        await _drain(tester);

        await tester.tap(find.byKey(const Key('topos-new-topo')));
        await _drain(tester);
        await _drain(tester);

        expect(tester.takeException(), isNull);
        final topos = await _dbWork(
          tester,
          () =>
              container.read(libraryCrudRepositoryProvider).watchTopos().first,
        );
        expect(topos.length, 1);

        final wall = await _dbWork(
          tester,
          () => (container.read(appDatabaseProvider).select(
            container.read(appDatabaseProvider).walls,
          )..where((t) => t.id.equals(topos.single.wallId))).getSingle(),
        );
        expect(wall.latitude, isNull);
        expect(wall.longitude, isNull);
      },
    );

    testWidgets(
      'EXIF GPS wins over an available device location fallback for the '
      'new topo\'s wall coordinates',
      (tester) async {
        final container = _makeContainer(
          // A deliberately different device location -- if this "won" the
          // wall would end up with THESE coordinates instead of the EXIF
          // ones asserted below.
          locationService: const _FakeLocationService((
            latitude: 10,
            longitude: 10,
          )),
        );
        late Directory tempDir;
        late File jpegFile;
        await tester.runAsync(() async {
          tempDir = await Directory.systemTemp.createTemp(
            'topos_screen_exif_wins_test',
          );
          jpegFile = File('${tempDir.path}/geotagged.jpg');
          await jpegFile.writeAsBytes(
            _buildJpegBytes(latitude: 47.4979, longitude: 19.0402),
          );
        });
        addTearDown(() {
          if (tempDir.existsSync()) {
            tempDir.deleteSync(recursive: true);
          }
        });

        await tester.pumpWidget(
          _wrap(
            container,
            ToposScreen(
              photoSourcePicker: (context) async => ImageSource.gallery,
              photoPicker: (source) async => XFile(jpegFile.path),
            ),
          ),
        );
        await _drain(tester);

        await tester.tap(find.byKey(const Key('topos-new-topo')));
        await _drain(tester);
        await _drain(tester);

        final topos = await _dbWork(
          tester,
          () =>
              container.read(libraryCrudRepositoryProvider).watchTopos().first,
        );
        expect(topos.length, 1);

        final wall = await _dbWork(
          tester,
          () => (container.read(appDatabaseProvider).select(
            container.read(appDatabaseProvider).walls,
          )..where((t) => t.id.equals(topos.single.wallId))).getSingle(),
        );
        expect(wall.latitude, closeTo(47.4979, 1e-4));
        expect(wall.longitude, closeTo(19.0402, 1e-4));
      },
    );

    testWidgets(
      'tapping New topo while toposProvider is still loading is a no-op: '
      'the photo-source picker is never invoked and no topo is created '
      '(regression for the stale/loading topo-count defect)',
      (tester) async {
        final db = AppDatabase(NativeDatabase.memory());
        addTearDown(db.close);
        final container = ProviderContainer(
          overrides: [
            appDatabaseProvider.overrideWithValue(db),
            nowMsProvider.overrideWithValue(() => 1000),
            // A stream that never emits keeps toposProvider in AsyncLoading
            // forever, mimicking the still-loading window this defect
            // exploited.
            toposProvider.overrideWith(
              (ref) => const Stream<List<TopoRef>>.empty(),
            ),
          ],
        );
        addTearDown(container.dispose);

        var pickerInvoked = false;
        await tester.pumpWidget(
          _wrap(
            container,
            ToposScreen(
              photoSourcePicker: (context) async {
                pickerInvoked = true;
                return null;
              },
              photoPicker: (source) async =>
                  throw StateError('must not be called'),
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));

        expect(find.byType(CircularProgressIndicator), findsOneWidget);

        final button = tester.widget<ElevatedButton>(
          find.byKey(const Key('topos-new-topo')),
        );
        expect(
          button.onPressed,
          isNull,
          reason: 'button must be visually disabled while not yet loaded',
        );

        await tester.tap(
          find.byKey(const Key('topos-new-topo')),
          warnIfMissed: false,
        );
        await tester.pump();

        expect(pickerInvoked, isFalse);

        final topos = await _dbWork(
          tester,
          () =>
              container.read(libraryCrudRepositoryProvider).watchTopos().first,
        );
        expect(topos, isEmpty);
      },
    );

    testWidgets('a fast double-tap on New topo only ever creates one topo '
        '(re-entrancy guard regression test)', (tester) async {
      final container = _makeContainer();
      late Directory tempDir;
      late File pngFile;
      await tester.runAsync(() async {
        tempDir = await Directory.systemTemp.createTemp(
          'topos_screen_test_reentrancy',
        );
        pngFile = File('${tempDir.path}/photo.png');
        await pngFile.writeAsBytes(_tinyPngBytes);
      });
      addTearDown(() {
        if (tempDir.existsSync()) {
          tempDir.deleteSync(recursive: true);
        }
      });

      var sourcePickerCalls = 0;
      final sourceCompleter = Completer<ImageSource?>();

      await tester.pumpWidget(
        _wrap(
          container,
          ToposScreen(
            photoSourcePicker: (context) async {
              sourcePickerCalls++;
              return sourceCompleter.future;
            },
            photoPicker: (source) async => XFile(pngFile.path),
          ),
        ),
      );
      await _drain(tester);

      // First tap starts the flow and suspends on the (uncompleted)
      // source-picker future; the flow's re-entrancy flag is set
      // synchronously before that await, so a second tap while it is
      // still in flight must be swallowed by the guard rather than
      // starting a second concurrent flow.
      await tester.tap(find.byKey(const Key('topos-new-topo')));
      await tester.tap(find.byKey(const Key('topos-new-topo')));
      await tester.pump();

      expect(
        sourcePickerCalls,
        1,
        reason:
            'second tap must be ignored while the first flow is '
            'still in flight',
      );

      await tester.runAsync(() async {
        sourceCompleter.complete(ImageSource.gallery);
      });
      await _drain(tester);
      await _drain(tester);

      final topos = await _dbWork(
        tester,
        () => container.read(libraryCrudRepositoryProvider).watchTopos().first,
      );
      expect(topos.length, 1);
    });

    testWidgets(
      'a picker exception is swallowed: the Topos home does not crash and '
      'remains usable',
      (tester) async {
        final container = _makeContainer();

        await tester.pumpWidget(
          _wrap(
            container,
            ToposScreen(
              photoSourcePicker: (context) async => ImageSource.gallery,
              photoPicker: (source) async => throw Exception('picker exploded'),
            ),
          ),
        );
        await _drain(tester);

        await tester.tap(find.byKey(const Key('topos-new-topo')));
        await _drain(tester);

        expect(tester.takeException(), isNull);
        expect(find.byKey(const Key('topos-empty-state')), findsOneWidget);
        expect(find.byKey(const Key('topos-new-topo')), findsOneWidget);

        final topos = await _dbWork(
          tester,
          () =>
              container.read(libraryCrudRepositoryProvider).watchTopos().first,
        );
        expect(topos, isEmpty);
      },
    );
  });

  group(
    'G5: SnackBar reflects the outcome of best-effort GPS capture '
    '(_handleNewTopo)',
    () {
      testWidgets(
        'a picked photo WITH EXIF GPS shows the "Location found in photo" '
        'SnackBar',
        (tester) async {
          final container = _makeContainer();
          late Directory tempDir;
          late File jpegFile;
          await tester.runAsync(() async {
            tempDir = await Directory.systemTemp.createTemp(
              'topos_screen_snackbar_exif_test',
            );
            jpegFile = File('${tempDir.path}/geotagged.jpg');
            await jpegFile.writeAsBytes(
              _buildJpegBytes(latitude: 47.4979, longitude: 19.0402),
            );
          });
          addTearDown(() {
            if (tempDir.existsSync()) {
              tempDir.deleteSync(recursive: true);
            }
          });

          await tester.pumpWidget(
            _wrap(
              container,
              ToposScreen(
                photoSourcePicker: (context) async => ImageSource.gallery,
                photoPicker: (source) async => XFile(jpegFile.path),
              ),
            ),
          );
          await _drain(tester);

          await tester.tap(find.byKey(const Key('topos-new-topo')));
          await _drainNoSettle(tester);

          expect(find.text('Location found in photo'), findsOneWidget);
        },
      );

      testWidgets(
        'a picked photo with NO EXIF GPS + an available device location '
        'shows the "Location set from your current position" SnackBar',
        (tester) async {
          final container = _makeContainer(
            locationService: const _FakeLocationService((
              latitude: 47.4979,
              longitude: 19.0402,
            )),
          );
          late Directory tempDir;
          late File jpegFile;
          await tester.runAsync(() async {
            tempDir = await Directory.systemTemp.createTemp(
              'topos_screen_snackbar_device_test',
            );
            jpegFile = File('${tempDir.path}/no-gps.jpg');
            await jpegFile.writeAsBytes(_buildJpegBytes());
          });
          addTearDown(() {
            if (tempDir.existsSync()) {
              tempDir.deleteSync(recursive: true);
            }
          });

          await tester.pumpWidget(
            _wrap(
              container,
              ToposScreen(
                photoSourcePicker: (context) async => ImageSource.gallery,
                photoPicker: (source) async => XFile(jpegFile.path),
              ),
            ),
          );
          await _drain(tester);

          await tester.tap(find.byKey(const Key('topos-new-topo')));
          await _drainNoSettle(tester);

          expect(
            find.text('Location set from your current position'),
            findsOneWidget,
          );
        },
      );

      testWidgets(
        'a picked photo with NO EXIF GPS and no device location shows the '
        '"No location found in photo" SnackBar',
        (tester) async {
          final container = _makeContainer(
            locationService: const _FakeLocationService(null),
          );
          late Directory tempDir;
          late File jpegFile;
          await tester.runAsync(() async {
            tempDir = await Directory.systemTemp.createTemp(
              'topos_screen_snackbar_none_test',
            );
            jpegFile = File('${tempDir.path}/no-gps.jpg');
            await jpegFile.writeAsBytes(_buildJpegBytes());
          });
          addTearDown(() {
            if (tempDir.existsSync()) {
              tempDir.deleteSync(recursive: true);
            }
          });

          await tester.pumpWidget(
            _wrap(
              container,
              ToposScreen(
                photoSourcePicker: (context) async => ImageSource.gallery,
                photoPicker: (source) async => XFile(jpegFile.path),
              ),
            ),
          );
          await _drain(tester);

          await tester.tap(find.byKey(const Key('topos-new-topo')));
          await _drainNoSettle(tester);

          expect(find.text('No location found in photo'), findsOneWidget);
        },
      );
    },
  );

  group(
    'coord-capture isolation: a setWallCoordinates failure must not abort '
    "the already-committed topo/photo creation or block navigation "
    '(regression -- the shared outer try/catch used to swallow this AFTER '
    'unwinding past context.push)',
    () {
      testWidgets(
        'a repo whose setWallCoordinates throws still leaves the topo+photo '
        "committed AND still navigates to the new wall's canvas",
        (tester) async {
          final db = AppDatabase(NativeDatabase.memory());
          addTearDown(db.close);
          final repo = _ThrowingSetCoordinatesRepository(
            db,
            nowMs: () => 1000,
          );
          final container = ProviderContainer(
            overrides: [
              appDatabaseProvider.overrideWithValue(db),
              nowMsProvider.overrideWithValue(() => 1000),
              libraryCrudRepositoryProvider.overrideWithValue(repo),
            ],
          );
          addTearDown(container.dispose);

          late Directory tempDir;
          late File jpegFile;
          await tester.runAsync(() async {
            tempDir = await Directory.systemTemp.createTemp(
              'topos_screen_coords_throw_test',
            );
            jpegFile = File('${tempDir.path}/geotagged.jpg');
            // Geotagged so extractGpsFromImageBytes returns non-null and
            // _handleNewTopo actually calls the throwing setWallCoordinates
            // -- a photo with no GPS would never exercise this path at all.
            await jpegFile.writeAsBytes(
              _buildJpegBytes(latitude: 47.4979, longitude: 19.0402),
            );
          });
          addTearDown(() {
            if (tempDir.existsSync()) {
              tempDir.deleteSync(recursive: true);
            }
          });

          // A bespoke router (rather than the shared `_wrap`) so the
          // `/walls/:wallId` destination is independently observable: it
          // renders a distinctly-keyed screen and records the pushed
          // wallId, which is the only way to tell "navigation happened"
          // apart from "navigation was silently skipped" -- the bug this
          // test targets leaves the user stuck on ToposScreen with no
          // visible error.
          String? pushedWallId;
          final router = GoRouter(
            initialLocation: '/',
            routes: [
              GoRoute(
                path: '/',
                builder: (context, state) => ToposScreen(
                  photoSourcePicker: (context) async => ImageSource.gallery,
                  photoPicker: (source) async => XFile(jpegFile.path),
                ),
              ),
              GoRoute(
                path: '/walls/:wallId',
                builder: (context, state) {
                  pushedWallId = state.pathParameters['wallId'];
                  return const Scaffold(
                    key: Key('fake-walls-screen'),
                    body: SizedBox(),
                  );
                },
              ),
              GoRoute(
                path: '/areas',
                builder: (context, state) => const SizedBox(),
              ),
            ],
          );

          await tester.pumpWidget(
            UncontrolledProviderScope(
              container: container,
              child: MaterialApp.router(
                theme: MasiTheme.light,
                routerConfig: router,
              ),
            ),
          );
          await _drain(tester);

          await tester.tap(find.byKey(const Key('topos-new-topo')));
          await _drain(tester);
          await _drain(tester);

          // No uncaught exception should ever surface: the throw must be
          // fully contained.
          expect(tester.takeException(), isNull);

          // The topo (and its photo) were already committed to the DB
          // BEFORE setWallCoordinates ran, so they must exist regardless of
          // whether the throw is isolated -- this alone does not
          // distinguish pre-fix from post-fix behavior.
          final topos = await _dbWork(tester, () => repo.watchTopos().first);
          expect(topos.length, 1);
          expect(topos.single.thumbnailPath, isNotNull);

          // This DOES distinguish pre-fix from post-fix: pre-fix, the
          // setWallCoordinates throw propagates out of the shared outer
          // try, skipping the `context.push` call below it entirely, so
          // this screen never appears and pushedWallId stays null.
          expect(
            find.byKey(const Key('fake-walls-screen')),
            findsOneWidget,
            reason:
                'a coords-capture failure must not prevent navigating to '
                'the newly-created topo',
          );
          expect(pushedWallId, topos.single.wallId);
        },
      );
    },
  );

  group('A2b: singular route-count subtitle', () {
    testWidgets('a topo with exactly one route renders "1 route" (singular)', (
      tester,
    ) async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final container = ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWithValue(db),
          nowMsProvider.overrideWithValue(() => 1000),
          toposProvider.overrideWith(
            (ref) => Stream.value(const [
              TopoRef(
                wallId: 'wall-singular',
                name: 'Singular Wall',
                thumbnailPath: null,
                routeCount: 1,
                createdAt: 1000,
              ),
            ]),
          ),
        ],
      );
      addTearDown(container.dispose);

      await tester.pumpWidget(_wrap(container, const ToposScreen()));
      await _drain(tester);

      expect(find.text('1 route'), findsOneWidget);
      expect(find.text('1 routes'), findsNothing);
    });
  });

  group('B: new-topo button contrast', () {
    testWidgets(
      'B-a: while topos are still loading (button disabled), the resolved '
      'foreground color keeps adequate contrast on the accent background, '
      'not the low-contrast ~38%-opacity onSurface Material default',
      (tester) async {
        final db = AppDatabase(NativeDatabase.memory());
        addTearDown(db.close);
        final container = ProviderContainer(
          overrides: [
            appDatabaseProvider.overrideWithValue(db),
            nowMsProvider.overrideWithValue(() => 1000),
            // A stream that never emits keeps toposProvider in AsyncLoading
            // forever, so canCreate stays false and the button stays
            // disabled (mirrors the A6 loading regression test above).
            toposProvider.overrideWith(
              (ref) => const Stream<List<TopoRef>>.empty(),
            ),
          ],
        );
        addTearDown(container.dispose);

        await tester.pumpWidget(_wrap(container, const ToposScreen()));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));

        final button = tester.widget<ElevatedButton>(
          find.byKey(const Key('topos-new-topo')),
        );
        expect(button.onPressed, isNull, reason: 'still loading -> disabled');

        final resolvedForeground = button.style!.foregroundColor!.resolve(
          <WidgetState>{WidgetState.disabled},
        )!;
        final resolvedBackground = button.style!.backgroundColor!.resolve(
          <WidgetState>{WidgetState.disabled},
        )!;

        // Must be materially more opaque than Material's default disabled
        // foreground (onSurface @ 38% alpha = 0.38), which is what produced
        // the low-contrast dark-on-purple text.
        expect(resolvedForeground.a, greaterThanOrEqualTo(0.6));
        // And it must be derived from onAccent (white, in the light theme
        // used by this test's MaterialApp), not the dark onSurface fallback.
        expect(resolvedForeground.r, greaterThan(0.9));
        expect(resolvedForeground.g, greaterThan(0.9));
        expect(resolvedForeground.b, greaterThan(0.9));

        // The background must still read as the purple accent while
        // disabled/loading, not fall back to a washed-out grey fill.
        expect(
          (resolvedBackground.r - MasiColors.light.accent.r).abs(),
          lessThan(0.05),
        );
        expect(
          (resolvedBackground.g - MasiColors.light.accent.g).abs(),
          lessThan(0.05),
        );
        expect(
          (resolvedBackground.b - MasiColors.light.accent.b).abs(),
          lessThan(0.05),
        );
      },
    );

    testWidgets(
      'B-b: the enabled state is unchanged - accent background, white '
      'onAccent foreground',
      (tester) async {
        final container = _makeContainer();

        await tester.pumpWidget(_wrap(container, const ToposScreen()));
        await _drain(tester);

        final button = tester.widget<ElevatedButton>(
          find.byKey(const Key('topos-new-topo')),
        );
        expect(button.onPressed, isNotNull, reason: 'loaded -> enabled');

        final resolvedForeground = button.style!.foregroundColor!.resolve(
          <WidgetState>{},
        );
        final resolvedBackground = button.style!.backgroundColor!.resolve(
          <WidgetState>{},
        );

        expect(resolvedForeground, MasiColors.light.onAccent);
        expect(resolvedBackground, MasiColors.light.accent);
      },
    );
  });

  group('A11: grade pill', () {
    testWidgets(
      'a topo with a top grade shows a pill with the band color and label',
      (tester) async {
        final db = AppDatabase(NativeDatabase.memory());
        addTearDown(db.close);
        final container = ProviderContainer(
          overrides: [
            appDatabaseProvider.overrideWithValue(db),
            nowMsProvider.overrideWithValue(() => 1000),
            toposProvider.overrideWith(
              (ref) => Stream.value(const [
                TopoRef(
                  wallId: 'wall-graded',
                  name: 'Graded Wall',
                  thumbnailPath: null,
                  routeCount: 3,
                  createdAt: 1000,
                  topGradeLabel: '7a',
                  topGradeBand: GradeBand.hard,
                ),
              ]),
            ),
          ],
        );
        addTearDown(container.dispose);

        await tester.pumpWidget(_wrap(container, const ToposScreen()));
        await _drain(tester);

        expect(find.text('7a'), findsOneWidget);
        expect(find.text('3 routes'), findsOneWidget);

        final pillContainer = tester.widget<Container>(
          find
              .ancestor(of: find.text('7a'), matching: find.byType(Container))
              .first,
        );
        final decoration = pillContainer.decoration as BoxDecoration;
        expect(decoration.color, MasiColors.light.gradeHard);
      },
    );

    testWidgets('a topo with no graded routes shows no pill, just "N routes"', (
      tester,
    ) async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final container = ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWithValue(db),
          nowMsProvider.overrideWithValue(() => 1000),
          toposProvider.overrideWith(
            (ref) => Stream.value(const [
              TopoRef(
                wallId: 'wall-bare',
                name: 'Bare Wall',
                thumbnailPath: null,
                routeCount: 2,
                createdAt: 1000,
              ),
            ]),
          ),
        ],
      );
      addTearDown(container.dispose);

      await tester.pumpWidget(_wrap(container, const ToposScreen()));
      await _drain(tester);

      expect(find.text('2 routes'), findsOneWidget);
      // No grade label of any kind should render for an ungraded topo.
      expect(find.textContaining(RegExp(r'^\d+[a-c]\+?$')), findsNothing);
    });
  });

  group('account button reflects auth state (#19)', () {
    testWidgets(
      'signed-out renders the generic person_outline icon, no CircleAvatar, '
      'key preserved',
      (tester) async {
        final db = AppDatabase(NativeDatabase.memory());
        addTearDown(db.close);
        final container = ProviderContainer(
          overrides: [
            appDatabaseProvider.overrideWithValue(db),
            nowMsProvider.overrideWithValue(() => 1000),
            authStateProvider.overrideWith(
              (ref) => Stream.value(const AuthSessionState.signedOut()),
            ),
          ],
        );
        addTearDown(container.dispose);

        await tester.pumpWidget(_wrap(container, const ToposScreen()));
        await _drain(tester);

        expect(find.byKey(const Key('topos-account-button')), findsOneWidget);
        final button = tester.widget<IconButton>(
          find.byKey(const Key('topos-account-button')),
        );
        expect(button.icon, isA<Icon>());
        expect((button.icon as Icon).icon, Icons.person_outline);
        expect(find.byType(CircleAvatar), findsNothing);
      },
    );

    testWidgets(
      'a still-loading auth stream also renders the person_outline icon '
      '(never a blank/empty avatar)',
      (tester) async {
        final db = AppDatabase(NativeDatabase.memory());
        addTearDown(db.close);
        final container = ProviderContainer(
          overrides: [
            appDatabaseProvider.overrideWithValue(db),
            nowMsProvider.overrideWithValue(() => 1000),
            // Never emits: authStateProvider stays AsyncLoading forever.
            authStateProvider.overrideWith(
              (ref) => const Stream<AuthSessionState>.empty(),
            ),
          ],
        );
        addTearDown(container.dispose);

        await tester.pumpWidget(_wrap(container, const ToposScreen()));
        await _drain(tester);

        final button = tester.widget<IconButton>(
          find.byKey(const Key('topos-account-button')),
        );
        expect(button.icon, isA<Icon>());
        expect((button.icon as Icon).icon, Icons.person_outline);
        expect(find.byType(CircleAvatar), findsNothing);
      },
    );

    testWidgets(
      'signed-in with a real email renders a CircleAvatar showing initials '
      '("PK" for peter.keri@example.com), key preserved',
      (tester) async {
        final db = AppDatabase(NativeDatabase.memory());
        addTearDown(db.close);
        final container = ProviderContainer(
          overrides: [
            appDatabaseProvider.overrideWithValue(db),
            nowMsProvider.overrideWithValue(() => 1000),
            authStateProvider.overrideWith(
              (ref) => Stream.value(
                const AuthSessionState.signedIn('peter.keri@example.com'),
              ),
            ),
          ],
        );
        addTearDown(container.dispose);

        await tester.pumpWidget(_wrap(container, const ToposScreen()));
        await _drain(tester);

        expect(find.byKey(const Key('topos-account-button')), findsOneWidget);
        expect(
          find.descendant(
            of: find.byKey(const Key('topos-account-button')),
            matching: find.byType(CircleAvatar),
          ),
          findsOneWidget,
        );
        expect(find.text('PK'), findsOneWidget);
        // The generic icon must not be layered underneath the avatar.
        expect(
          find.descendant(
            of: find.byKey(const Key('topos-account-button')),
            matching: find.byIcon(Icons.person_outline),
          ),
          findsNothing,
        );
      },
    );
  });

  group('D1b: Community/Logbook nav buttons on the app bar', () {
    testWidgets(
      'home-community-button and home-logbook-button are present in the '
      'trailing app-bar slot alongside the existing Organize action',
      (tester) async {
        final container = _makeContainer();

        await tester.pumpWidget(_wrap(container, const ToposScreen()));
        await _drain(tester);

        expect(
          find.descendant(
            of: find.byType(AppBar),
            matching: find.byKey(const Key('home-community-button')),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: find.byType(AppBar),
            matching: find.byKey(const Key('home-logbook-button')),
          ),
          findsOneWidget,
        );
        // The existing Organize action must still be intact.
        expect(find.byKey(const Key('topos-organize')), findsOneWidget);
      },
    );
  });

  group(
    'D1c: "Topos" title fits after moving the filter trigger out of the '
    'app bar',
    () {
      testWidgets(
        'at normal text scale on a standard phone width, the app-bar title '
        '"Topos" renders without truncating, and the filter trigger is no '
        'longer one of the app-bar trailing actions',
        (tester) async {
          tester.view.physicalSize = const Size(390, 844);
          tester.view.devicePixelRatio = 1.0;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);

          final container = _makeContainer();

          await tester.pumpWidget(_wrap(container, const ToposScreen()));
          await _drain(tester);

          expect(tester.takeException(), isNull);

          final titleFinder = find.descendant(
            of: find.byType(AppBar),
            matching: find.text('Topos'),
          );
          expect(titleFinder, findsOneWidget);

          // NOTE: we deliberately do NOT assert
          // `RenderParagraph.didExceedMaxLines` here. `flutter test` never
          // loads the app's real fonts, so glyph metrics (measured with a
          // throwaway debug harness while writing this test) come out
          // dramatically wider than on a real device -- e.g. a titleMedium
          // text button label measured meaningfully wider in-test than
          // expected with a real font -- which makes a literal one-line-fit
          // assertion measure a test-harness artifact, not the real defect.
          // The structural checks below (four app-bar actions instead of
          // five; filter button relocated to the body) are what actually
          // fixes the truncation, and the real fix is verified visually via
          // the project's simulator-screenshot loop (see CLAUDE.md).
          //
          // The filter trigger must have actually moved: gone from the
          // app bar, present somewhere in the body instead.
          expect(
            find.descendant(
              of: find.byType(AppBar),
              matching: find.byKey(const Key('topos-filter-button')),
            ),
            findsNothing,
          );
          expect(
            find.byKey(const Key('topos-filter-button')),
            findsOneWidget,
          );
        },
      );
    },
  );

  group('D5d: publish/unpublish menu action', () {
    testWidgets(
      'the menu shows "Publish" for a private topo; tapping it opens a '
      'confirm dialog; cancelling leaves the wall private and un-dirty',
      (tester) async {
        final container = _makeContainer();
        final wallId = await _dbWork(
          tester,
          () => container
              .read(libraryCrudRepositoryProvider)
              .createTopo('Shareable Wall'),
        );

        await tester.pumpWidget(_wrap(container, const ToposScreen()));
        await _drain(tester);

        await tester.tap(find.byKey(Key('topo-menu-$wallId')));
        await tester.pumpAndSettle();

        expect(find.byKey(Key('topo-publish-$wallId')), findsOneWidget);
        expect(find.text('Publish'), findsOneWidget);
        expect(find.text('Unpublish'), findsNothing);

        await tester.tap(find.byKey(Key('topo-publish-$wallId')));
        await tester.pumpAndSettle();

        expect(find.text('Publish to Community?'), findsOneWidget);
        expect(
          find.byKey(Key('topo-publish-confirm-$wallId')),
          findsOneWidget,
          reason:
              'confirming publish must go through a dedicated confirm '
              'action, not fire straight off the menu tap',
        );

        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();

        final rawDb = container.read(appDatabaseProvider);
        final wall = await _dbWork(
          tester,
          () => (rawDb.select(
            rawDb.walls,
          )..where((t) => t.id.equals(wallId))).getSingle(),
        );
        expect(
          wall.visibility,
          'private',
          reason: 'cancelling the confirm dialog must not publish',
        );
        expect(wall.dirty, isFalse);
      },
    );

    testWidgets(
      'confirming the publish dialog calls publishTopo: the wall becomes '
      'shared, and the menu now shows "Unpublish"',
      (tester) async {
        final container = _makeContainer();
        final wallId = await _dbWork(
          tester,
          () => container
              .read(libraryCrudRepositoryProvider)
              .createTopo('Shareable Wall'),
        );

        await tester.pumpWidget(_wrap(container, const ToposScreen()));
        await _drain(tester);

        await tester.tap(find.byKey(Key('topo-menu-$wallId')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(Key('topo-publish-$wallId')));
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(Key('topo-publish-confirm-$wallId')));
        await _drain(tester);

        final rawDb = container.read(appDatabaseProvider);
        final wall = await _dbWork(
          tester,
          () => (rawDb.select(
            rawDb.walls,
          )..where((t) => t.id.equals(wallId))).getSingle(),
        );
        expect(wall.visibility, 'shared');
        expect(wall.dirty, isTrue);

        // Re-open the menu: it should now offer "Unpublish", not "Publish".
        await tester.tap(find.byKey(Key('topo-menu-$wallId')));
        await tester.pumpAndSettle();

        expect(find.text('Unpublish'), findsOneWidget);
        expect(find.text('Publish'), findsNothing);
      },
    );

    testWidgets(
      'tapping Unpublish on an already-shared topo calls unpublishTopo '
      'directly (no confirm dialog) and the wall reverts to private',
      (tester) async {
        final container = _makeContainer();
        final wallId = await _dbWork(
          tester,
          () => container
              .read(libraryCrudRepositoryProvider)
              .createTopo('Shared Wall'),
        );
        await _dbWork(
          tester,
          () =>
              container.read(libraryCrudRepositoryProvider).publishTopo(wallId),
        );

        await tester.pumpWidget(_wrap(container, const ToposScreen()));
        await _drain(tester);

        await tester.tap(find.byKey(Key('topo-menu-$wallId')));
        await tester.pumpAndSettle();

        expect(find.text('Unpublish'), findsOneWidget);

        await tester.tap(find.byKey(Key('topo-publish-$wallId')));
        await _drain(tester);

        // No confirm dialog should have appeared for unpublish.
        expect(find.text('Publish to Community?'), findsNothing);

        final rawDb = container.read(appDatabaseProvider);
        final wall = await _dbWork(
          tester,
          () => (rawDb.select(
            rawDb.walls,
          )..where((t) => t.id.equals(wallId))).getSingle(),
        );
        expect(wall.visibility, 'private');
      },
    );
  });

  group('E1: filter button + Filters sheet (Subtask D)', () {
    testWidgets(
      'topos-filter-button lives in the body (not the app bar, which stays '
      'roomy for the "Topos" title); tapping it opens the Filters sheet '
      'with the grade picker, visibility control, area chips (incl. '
      'Unfiled) and Clear',
      (tester) async {
        final container = _makeContainer();

        await tester.pumpWidget(_wrap(container, const ToposScreen()));
        await _drain(tester);

        // Relocated out of the AppBar (see D1c/title-truncation fix) so the
        // AppBar's trailing actions stay uncrowded and the "Topos" title
        // doesn't truncate.
        expect(
          find.descendant(
            of: find.byType(AppBar),
            matching: find.byKey(const Key('topos-filter-button')),
          ),
          findsNothing,
        );
        expect(find.byKey(const Key('topos-filter-button')), findsOneWidget);
        // No filter is active yet, so no badge should show.
        expect(
          find.byKey(const Key('topos-filter-active-indicator')),
          findsNothing,
        );

        await tester.tap(find.byKey(const Key('topos-filter-button')));
        await tester.pumpAndSettle();

        expect(find.text('Filters'), findsOneWidget);
        expect(find.byKey(const Key('filter-grade-system')), findsOneWidget);
        expect(find.byKey(const Key('filter-grade-min')), findsOneWidget);
        expect(find.byKey(const Key('filter-grade-max')), findsOneWidget);
        expect(
          find.byKey(const Key('topos-filter-visibility')),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('topos-filter-area-unfiled')),
          findsOneWidget,
        );
        expect(find.byKey(const Key('topos-filter-clear')), findsOneWidget);
      },
    );
  });

  group('E2: visibility facet filters the list live (Subtask D)', () {
    ProviderContainer buildVisibilityContainer() {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final container = ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWithValue(db),
          nowMsProvider.overrideWithValue(() => 1000),
          toposProvider.overrideWith(
            (ref) => Stream.value(const [
              TopoRef(
                wallId: 'w-private',
                name: 'Private Topo',
                thumbnailPath: null,
                routeCount: 0,
                createdAt: 1000,
              ),
              TopoRef(
                wallId: 'w-shared',
                name: 'Shared Topo',
                thumbnailPath: null,
                routeCount: 0,
                createdAt: 900,
                visibility: 'shared',
              ),
            ]),
          ),
        ],
      );
      addTearDown(container.dispose);
      return container;
    }

    testWidgets(
      'selecting Shared hides the private topo; switching back to All '
      'shows it again, live, without leaving the sheet',
      (tester) async {
        final container = buildVisibilityContainer();

        await tester.pumpWidget(_wrap(container, const ToposScreen()));
        await _drain(tester);

        expect(find.text('Private Topo'), findsOneWidget);
        expect(find.text('Shared Topo'), findsOneWidget);

        await tester.tap(find.byKey(const Key('topos-filter-button')));
        await tester.pumpAndSettle();

        await tester.tap(
          find.byKey(const Key('topos-filter-visibility-shared')),
        );
        await tester.pumpAndSettle();

        expect(find.text('Private Topo'), findsNothing);
        expect(find.text('Shared Topo'), findsOneWidget);
        expect(
          find.byKey(const Key('topos-filter-active-indicator')),
          findsOneWidget,
          reason: 'an active visibility facet must show the badge',
        );

        await tester.tap(
          find.byKey(const Key('topos-filter-visibility-all')),
        );
        await tester.pumpAndSettle();

        expect(find.text('Private Topo'), findsOneWidget);
        expect(find.text('Shared Topo'), findsOneWidget);
        expect(
          find.byKey(const Key('topos-filter-active-indicator')),
          findsNothing,
        );
      },
    );

    testWidgets(
      'a filter that matches nothing shows the distinct filtered-empty '
      'state, not the "no topos yet" empty state',
      (tester) async {
        final db = AppDatabase(NativeDatabase.memory());
        addTearDown(db.close);
        final container = ProviderContainer(
          overrides: [
            appDatabaseProvider.overrideWithValue(db),
            nowMsProvider.overrideWithValue(() => 1000),
            toposProvider.overrideWith(
              (ref) => Stream.value(const [
                TopoRef(
                  wallId: 'w-private',
                  name: 'Private Topo',
                  thumbnailPath: null,
                  routeCount: 0,
                  createdAt: 1000,
                ),
              ]),
            ),
          ],
        );
        addTearDown(container.dispose);

        await tester.pumpWidget(_wrap(container, const ToposScreen()));
        await _drain(tester);

        await tester.tap(find.byKey(const Key('topos-filter-button')));
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const Key('topos-filter-visibility-shared')),
        );
        await tester.pumpAndSettle();

        expect(
          find.byKey(const Key('topos-filtered-empty-state')),
          findsOneWidget,
        );
        expect(find.text('No topos match your filters'), findsOneWidget);
        expect(find.byKey(const Key('topos-empty-state')), findsNothing);
        expect(find.text('Private Topo'), findsNothing);
      },
    );
  });

  group('E3: area facet incl. Unfiled filters the list live (Subtask D)', () {
    testWidgets(
      'area chips are built from areasProvider plus an explicit Unfiled '
      'option; selecting Unfiled shows only the null-area topo',
      (tester) async {
        final db = AppDatabase(NativeDatabase.memory());
        addTearDown(db.close);
        final container = ProviderContainer(
          overrides: [
            appDatabaseProvider.overrideWithValue(db),
            nowMsProvider.overrideWithValue(() => 1000),
            areasProvider.overrideWith(
              (ref) => Stream.value(const [
                AreaRef(id: 'area-1', name: 'Squamish'),
              ]),
            ),
            toposProvider.overrideWith(
              (ref) => Stream.value(const [
                TopoRef(
                  wallId: 'w-in-area',
                  name: 'In Area Topo',
                  thumbnailPath: null,
                  routeCount: 0,
                  createdAt: 1000,
                  areaId: 'area-1',
                  areaName: 'Squamish',
                ),
                TopoRef(
                  wallId: 'w-unfiled',
                  name: 'Unfiled Topo',
                  thumbnailPath: null,
                  routeCount: 0,
                  createdAt: 900,
                ),
              ]),
            ),
          ],
        );
        addTearDown(container.dispose);

        await tester.pumpWidget(_wrap(container, const ToposScreen()));
        await _drain(tester);

        await tester.tap(find.byKey(const Key('topos-filter-button')));
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('topos-filter-area-area-1')), findsOneWidget);
        expect(find.text('Squamish'), findsOneWidget);
        // The sentinel Area must never surface as a selectable chip.
        expect(find.text('__default__'), findsNothing);

        await tester.tap(find.byKey(const Key('topos-filter-area-unfiled')));
        await tester.pumpAndSettle();

        expect(find.text('In Area Topo'), findsNothing);
        expect(find.text('Unfiled Topo'), findsOneWidget);
        expect(
          find.byKey(const Key('topos-filter-active-indicator')),
          findsOneWidget,
        );
      },
    );
  });

  group('E4: Clear resets every facet (Subtask D)', () {
    testWidgets(
      'Clear resets visibility + area selections and the active indicator '
      'disappears; the full list reappears',
      (tester) async {
        final db = AppDatabase(NativeDatabase.memory());
        addTearDown(db.close);
        final container = ProviderContainer(
          overrides: [
            appDatabaseProvider.overrideWithValue(db),
            nowMsProvider.overrideWithValue(() => 1000),
            areasProvider.overrideWith(
              (ref) => Stream.value(const [
                AreaRef(id: 'area-1', name: 'Squamish'),
              ]),
            ),
            toposProvider.overrideWith(
              (ref) => Stream.value(const [
                TopoRef(
                  wallId: 'w-private-in-area',
                  name: 'Private In Area',
                  thumbnailPath: null,
                  routeCount: 0,
                  createdAt: 1000,
                  areaId: 'area-1',
                  areaName: 'Squamish',
                ),
                TopoRef(
                  wallId: 'w-shared-unfiled',
                  name: 'Shared Unfiled',
                  thumbnailPath: null,
                  routeCount: 0,
                  createdAt: 900,
                  visibility: 'shared',
                ),
              ]),
            ),
          ],
        );
        addTearDown(container.dispose);

        await tester.pumpWidget(_wrap(container, const ToposScreen()));
        await _drain(tester);

        await tester.tap(find.byKey(const Key('topos-filter-button')));
        await tester.pumpAndSettle();

        await tester.tap(
          find.byKey(const Key('topos-filter-visibility-shared')),
        );
        await tester.pumpAndSettle();

        expect(find.text('Private In Area'), findsNothing);
        expect(find.text('Shared Unfiled'), findsOneWidget);

        await tester.tap(find.byKey(const Key('topos-filter-clear')));
        await tester.pumpAndSettle();

        expect(find.text('Private In Area'), findsOneWidget);
        expect(find.text('Shared Unfiled'), findsOneWidget);
        expect(
          find.byKey(const Key('topos-filter-active-indicator')),
          findsNothing,
        );
        expect(
          container.read(toposFilterProvider),
          const ToposFilter(),
        );
      },
    );
  });

  group('layout overflow regression: Filters sheet', () {
    /// Wraps [screen] in the same minimal [GoRouter] as [_wrap], plus a
    /// [MediaQuery] override so `textScaler` can be forced to a large value
    /// independently of the surface size set via [setViewportSize].
    Widget wrapWithScale(
      ProviderContainer container,
      Widget screen,
      double textScale,
    ) {
      final router = GoRouter(
        initialLocation: '/',
        routes: [
          GoRoute(path: '/', builder: (context, state) => screen),
          GoRoute(
            path: '/walls/:wallId',
            builder: (context, state) => const SizedBox(),
          ),
          GoRoute(
            path: '/areas',
            builder: (context, state) => const SizedBox(),
          ),
        ],
      );
      return UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(
          theme: MasiTheme.light,
          routerConfig: router,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(textScale)),
            child: child!,
          ),
        ),
      );
    }

    void setViewportSize(WidgetTester tester, Size size) {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
    }

    // NOTE on surface width: `ToposScreen`'s AppBar carries four trailing
    // actions (Organize, Community, Logbook, Account -- the filter trigger
    // now lives in the body, see the title-truncation fix below). Organize
    // used to be a `TextButton` whose label could overflow the AppBar itself
    // on a narrow phone-width surface at large text scales -- that has since
    // been fixed (Organize is now a fixed-size `IconButton`, see the "AppBar
    // Organize action + _TopoRow" group below, which deliberately does NOT
    // dodge phone width). 700px is kept here anyway to isolate exactly what
    // THIS group cares about -- the Filters sheet's own layout, independent
    // of the AppBar -- and because it still exercises something real:
    // `showModalBottomSheet` caps a sheet's content width on wide/tablet-ish
    // surfaces, so the sheet's available width barely grows past ~700, and
    // the "Filters"/Clear header row still overflows there pre-fix exactly
    // as it would on a narrower phone.
    const stressWidth = 700.0;

    testWidgets(
      'vertical stress: ${stressWidth}x500 @ 2.5x text scale — opening the '
      'Filters sheet does not overflow vertically',
      (tester) async {
        setViewportSize(tester, const Size(stressWidth, 500));
        final container = _makeContainer();

        await tester.pumpWidget(
          wrapWithScale(container, const ToposScreen(), 2.5),
        );
        await _drain(tester);
        expect(
          tester.takeException(),
          isNull,
          reason: 'the AppBar itself must not overflow at this surface size '
              '(see NOTE above) -- if it does, widen `stressWidth`',
        );

        await tester.tap(find.byKey(const Key('topos-filter-button')));
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'horizontal stress: ${stressWidth}x800 @ 3.0x text scale — the '
      '"Filters"/Clear header row does not overflow horizontally '
      '(regression: the title must truncate rather than push Clear '
      'off-screen)',
      (tester) async {
        setViewportSize(tester, const Size(stressWidth, 800));
        final container = _makeContainer();

        await tester.pumpWidget(
          wrapWithScale(container, const ToposScreen(), 3.0),
        );
        await _drain(tester);
        expect(
          tester.takeException(),
          isNull,
          reason: 'the AppBar itself must not overflow at this surface size '
              '(see NOTE above) -- if it does, widen `stressWidth`',
        );

        await tester.tap(find.byKey(const Key('topos-filter-button')));
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull);
      },
    );
  });

  group(
    'layout overflow regression: AppBar Organize action + _TopoRow at '
    'phone width (regression: an unbounded "Organize" TextButton label in '
    'the AppBar actions, and an unwrapped grade-pill+routes Row in '
    '_TopoRow, must not overflow at large text)',
    () {
      Widget wrapWithScale(
        ProviderContainer container,
        Widget screen,
        double textScale,
      ) {
        final router = GoRouter(
          initialLocation: '/',
          routes: [
            GoRoute(path: '/', builder: (context, state) => screen),
            GoRoute(
              path: '/walls/:wallId',
              builder: (context, state) => const SizedBox(),
            ),
            GoRoute(
              path: '/areas',
              builder: (context, state) => const SizedBox(),
            ),
          ],
        );
        return UncontrolledProviderScope(
          container: container,
          child: MaterialApp.router(
            theme: MasiTheme.light,
            routerConfig: router,
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(textScale)),
              child: child!,
            ),
          ),
        );
      }

      void setViewportSize(WidgetTester tester, Size size) {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
      }

      testWidgets(
        'a populated topo list at 360x800 @ 3.0x text scale does not '
        'overflow -- neither the AppBar (Organize action) nor a _TopoRow '
        'with a grade pill + route count (regression: unlike the '
        '"Filters sheet" group above, this case does NOT dodge the AppBar '
        'via a wide stressWidth -- 360 is a real phone width)',
        (tester) async {
          setViewportSize(tester, const Size(360, 800));
          final db = AppDatabase(NativeDatabase.memory());
          addTearDown(db.close);
          final container = ProviderContainer(
            overrides: [
              appDatabaseProvider.overrideWithValue(db),
              nowMsProvider.overrideWithValue(() => 1000),
              toposProvider.overrideWith(
                (ref) => Stream.value(const [
                  TopoRef(
                    wallId: 'wall-stress',
                    name: 'Stress Test Wall',
                    thumbnailPath: null,
                    routeCount: 12,
                    createdAt: 1000,
                    topGradeLabel: '7a',
                    topGradeBand: GradeBand.hard,
                  ),
                ]),
              ),
            ],
          );
          addTearDown(container.dispose);

          await tester.pumpWidget(
            wrapWithScale(container, const ToposScreen(), 3.0),
          );
          await _drain(tester);

          expect(tester.takeException(), isNull);
        },
      );
    },
  );

  group(
    'T1: visibility badge — clear division between published/private topos '
    '(community vs. own)',
    () {
      testWidgets(
        'a shared topo shows the Published badge, a private topo shows the '
        'Private badge, each distinctly keyed and distinguishable by text; '
        'no overflow at 390x800 @ 1.0x',
        (tester) async {
          tester.view.physicalSize = const Size(390, 800);
          tester.view.devicePixelRatio = 1.0;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);

          final db = AppDatabase(NativeDatabase.memory());
          addTearDown(db.close);
          final container = ProviderContainer(
            overrides: [
              appDatabaseProvider.overrideWithValue(db),
              nowMsProvider.overrideWithValue(() => 1000),
              toposProvider.overrideWith(
                (ref) => Stream.value(const [
                  TopoRef(
                    wallId: 'wall-shared-badge',
                    name: 'Shared Wall',
                    thumbnailPath: null,
                    routeCount: 1,
                    createdAt: 1000,
                    visibility: 'shared',
                  ),
                  TopoRef(
                    wallId: 'wall-private-badge',
                    name: 'Private Wall',
                    thumbnailPath: null,
                    routeCount: 1,
                    createdAt: 900,
                  ),
                ]),
              ),
            ],
          );
          addTearDown(container.dispose);

          await tester.pumpWidget(_wrap(container, const ToposScreen()));
          await _drain(tester);

          expect(tester.takeException(), isNull);

          final sharedBadge = find.byKey(
            const Key('topo-visibility-badge-wall-shared-badge'),
          );
          final privateBadge = find.byKey(
            const Key('topo-visibility-badge-wall-private-badge'),
          );
          expect(sharedBadge, findsOneWidget);
          expect(privateBadge, findsOneWidget);

          // Distinguishable by their text content.
          expect(
            find.descendant(of: sharedBadge, matching: find.text('Published')),
            findsOneWidget,
          );
          expect(
            find.descendant(of: sharedBadge, matching: find.text('Private')),
            findsNothing,
          );
          expect(
            find.descendant(of: privateBadge, matching: find.text('Private')),
            findsOneWidget,
          );
          expect(
            find.descendant(
              of: privateBadge,
              matching: find.text('Published'),
            ),
            findsNothing,
          );
        },
      );
    },
  );

  group('S1: search field filters by name', () {
    testWidgets(
      'entering "moon" hides "Sunset Arete" and shows only "Moonrise Slab"',
      (tester) async {
        final db = AppDatabase(NativeDatabase.memory());
        addTearDown(db.close);
        final container = ProviderContainer(
          overrides: [
            appDatabaseProvider.overrideWithValue(db),
            nowMsProvider.overrideWithValue(() => 1000),
            toposProvider.overrideWith(
              (ref) => Stream.value(const [
                TopoRef(
                  wallId: 'wall-sunset',
                  name: 'Sunset Arete',
                  thumbnailPath: null,
                  routeCount: 0,
                  createdAt: 1000,
                ),
                TopoRef(
                  wallId: 'wall-moonrise',
                  name: 'Moonrise Slab',
                  thumbnailPath: null,
                  routeCount: 0,
                  createdAt: 900,
                ),
              ]),
            ),
          ],
        );
        addTearDown(container.dispose);

        await tester.pumpWidget(_wrap(container, const ToposScreen()));
        await _drain(tester);

        expect(find.text('Sunset Arete'), findsOneWidget);
        expect(find.text('Moonrise Slab'), findsOneWidget);

        await tester.enterText(
          find.byKey(const Key('topos-search-field')),
          'moon',
        );
        await tester.pumpAndSettle();

        expect(find.text('Moonrise Slab'), findsOneWidget);
        expect(find.text('Sunset Arete'), findsNothing);
      },
    );
  });

  group(
    'S2: search with no matches shows the search-specific empty state',
    () {
      testWidgets(
        'a query matching nothing shows topos-search-empty-state, not the '
        'filtered or "no topos yet" empty states, and no topo rows',
        (tester) async {
          final db = AppDatabase(NativeDatabase.memory());
          addTearDown(db.close);
          final container = ProviderContainer(
            overrides: [
              appDatabaseProvider.overrideWithValue(db),
              nowMsProvider.overrideWithValue(() => 1000),
              toposProvider.overrideWith(
                (ref) => Stream.value(const [
                  TopoRef(
                    wallId: 'wall-sunset',
                    name: 'Sunset Arete',
                    thumbnailPath: null,
                    routeCount: 0,
                    createdAt: 1000,
                  ),
                ]),
              ),
            ],
          );
          addTearDown(container.dispose);

          await tester.pumpWidget(_wrap(container, const ToposScreen()));
          await _drain(tester);

          await tester.enterText(
            find.byKey(const Key('topos-search-field')),
            'nonexistent-query-xyz',
          );
          await tester.pumpAndSettle();

          expect(
            find.byKey(const Key('topos-search-empty-state')),
            findsOneWidget,
          );
          expect(find.text('No topos match your search'), findsOneWidget);
          expect(find.byKey(const Key('topos-empty-state')), findsNothing);
          expect(
            find.byKey(const Key('topos-filtered-empty-state')),
            findsNothing,
          );
          expect(find.text('Sunset Arete'), findsNothing);
        },
      );
    },
  );

  group('S3: search ANDs with the existing filter', () {
    testWidgets(
      'with a Shared visibility filter active AND a query, only topos '
      'matching BOTH appear',
      (tester) async {
        final db = AppDatabase(NativeDatabase.memory());
        addTearDown(db.close);
        final container = ProviderContainer(
          overrides: [
            appDatabaseProvider.overrideWithValue(db),
            nowMsProvider.overrideWithValue(() => 1000),
            toposProvider.overrideWith(
              (ref) => Stream.value(const [
                TopoRef(
                  wallId: 'wall-moon-shared',
                  name: 'Moonrise Slab',
                  thumbnailPath: null,
                  routeCount: 0,
                  createdAt: 1000,
                  visibility: 'shared',
                ),
                TopoRef(
                  wallId: 'wall-moon-private',
                  name: 'Moonrise Wall',
                  thumbnailPath: null,
                  routeCount: 0,
                  createdAt: 950,
                ),
                TopoRef(
                  wallId: 'wall-sunrise-shared',
                  name: 'Sunrise Slope',
                  thumbnailPath: null,
                  routeCount: 0,
                  createdAt: 900,
                  visibility: 'shared',
                ),
              ]),
            ),
          ],
        );
        addTearDown(container.dispose);

        await tester.pumpWidget(_wrap(container, const ToposScreen()));
        await _drain(tester);

        container
            .read(toposFilterProvider.notifier)
            .setVisibility(ToposVisibilityFilter.shared);
        await tester.pumpAndSettle();

        // Filter alone: both shared topos show, the private one is hidden.
        expect(find.text('Moonrise Slab'), findsOneWidget);
        expect(find.text('Sunrise Slope'), findsOneWidget);
        expect(find.text('Moonrise Wall'), findsNothing);

        await tester.enterText(
          find.byKey(const Key('topos-search-field')),
          'moon',
        );
        await tester.pumpAndSettle();

        // Search ANDs with the filter: only the shared AND
        // name-matching topo remains.
        expect(find.text('Moonrise Slab'), findsOneWidget);
        expect(find.text('Sunrise Slope'), findsNothing);
        expect(find.text('Moonrise Wall'), findsNothing);
      },
    );
  });

  group('S4: clearing the query restores the full (filtered) list', () {
    testWidgets(
      'clearing topos-search-field after a narrowing query restores every '
      'topo that still matches the active filter',
      (tester) async {
        final db = AppDatabase(NativeDatabase.memory());
        addTearDown(db.close);
        final container = ProviderContainer(
          overrides: [
            appDatabaseProvider.overrideWithValue(db),
            nowMsProvider.overrideWithValue(() => 1000),
            toposProvider.overrideWith(
              (ref) => Stream.value(const [
                TopoRef(
                  wallId: 'wall-sunset',
                  name: 'Sunset Arete',
                  thumbnailPath: null,
                  routeCount: 0,
                  createdAt: 1000,
                ),
                TopoRef(
                  wallId: 'wall-moonrise',
                  name: 'Moonrise Slab',
                  thumbnailPath: null,
                  routeCount: 0,
                  createdAt: 900,
                ),
              ]),
            ),
          ],
        );
        addTearDown(container.dispose);

        await tester.pumpWidget(_wrap(container, const ToposScreen()));
        await _drain(tester);

        await tester.enterText(
          find.byKey(const Key('topos-search-field')),
          'moon',
        );
        await tester.pumpAndSettle();

        expect(find.text('Sunset Arete'), findsNothing);
        expect(find.text('Moonrise Slab'), findsOneWidget);

        await tester.enterText(
          find.byKey(const Key('topos-search-field')),
          '',
        );
        await tester.pumpAndSettle();

        expect(find.text('Sunset Arete'), findsOneWidget);
        expect(find.text('Moonrise Slab'), findsOneWidget);
      },
    );
  });
}
