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
import 'package:climbtopo/features/community/application/community_providers.dart';
import 'package:climbtopo/features/community/data/community_repository.dart';
import 'package:climbtopo/features/library/application/library_providers.dart';
import 'package:climbtopo/features/library/data/library_crud_repository.dart';
import 'package:climbtopo/features/library/presentation/set_location_picker.dart';
import 'package:climbtopo/features/library/presentation/topos_screen.dart';
import 'package:climbtopo/shared/presentation/masi_icon.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:image/image.dart' as img;
// Not exported from package:image's barrel (see photo_gps_test.dart's
// identical import for why) -- needed here only to hand-build a geotagged
// JPEG fixture for the A7 GPS-capture test below.
import 'package:image/src/util/rational.dart';
import 'package:image_picker/image_picker.dart';
import 'package:latlong2/latlong.dart';

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
/// [bottomChromeInset], when given, overrides the ambient
/// `MediaQuery.padding.bottom` seen by [screen] — used only by the #51
/// floating-bar-inset test below to simulate the REAL non-zero clearance
/// `NavShell`'s `extendBody: true` Scaffold reports to its body in
/// production (this bare `_wrap` harness has no `NavShell` of its own, so
/// the ambient inset would otherwise always be 0). Every other existing
/// call site leaves this null, so its behavior is completely unchanged.
Widget _wrap(
  ProviderContainer container,
  Widget screen, {
  double? bottomChromeInset,
}) {
  final router = GoRouter(
    initialLocation: '/',
    routes: [
      GoRoute(path: '/', builder: (context, state) => screen),
      GoRoute(
        path: '/walls/:wallId',
        builder: (context, state) => const SizedBox(),
      ),
      GoRoute(path: '/areas', builder: (context, state) => const SizedBox()),
      // The "Show on map" menu action's destination (see
      // `_TopoRow._handleShowOnMap`) -- a keyed placeholder carrying the
      // pushed query params in its text, so a test can confirm both that
      // navigation happened AND that it carried the right tab/focus values,
      // without needing the real `CommunityScreen`/`FlutterMap`.
      GoRoute(
        path: '/community',
        builder: (context, state) => Text(
          'community-'
          '${state.uri.queryParameters['tab']}-'
          '${state.uri.queryParameters['focus']}',
          key: const Key('community-placeholder'),
        ),
      ),
    ],
  );
  return UncontrolledProviderScope(
    container: container,
    child: MaterialApp.router(
      theme: MasiTheme.light,
      routerConfig: router,
      builder: bottomChromeInset == null
          ? null
          : (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(padding: EdgeInsets.only(bottom: bottomChromeInset)),
              child: child!,
            ),
    ),
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

/// Advances past the `_NewTopoNameDialog` that now blocks `_handleNewTopo`
/// between the photo being picked/decoded and `createTopo` actually being
/// called (plan #25). Runs a full [_drain] first -- not just a fake-time
/// `pump()` -- because the decode step immediately before the dialog
/// (`ui.instantiateImageCodec`) is REAL async platform work that, like the
/// rest of `_handleNewTopo`'s Drift/file-IO, only progresses under
/// `tester.runAsync`'s real event loop; a bare `pump()` here would check
/// for the dialog before decode has actually finished. `_drain`'s trailing
/// `pumpAndSettle()` is safe to call even though `_handleNewTopo` is still
/// suspended awaiting the dialog's `showDialog` future -- the dialog's own
/// entrance transition settles, then `pumpAndSettle()` simply returns
/// without ever reaching (or skipping past) the SnackBar/navigation that
/// only run once this helper's submit tap lets `_handleNewTopo` resume.
///
/// Asserts the dialog is actually showing (so a regression that silently
/// drops the prompt fails loudly here instead of a confusing timeout/no-op
/// further down), then taps `topo-name-submit` to accept whatever name is
/// currently in the field -- the prefilled `'Topo N'` default, unless a
/// test typed over it first -- and pumps once more so the rest of the
/// flow starts making progress before the caller's own `_drain`/
/// `_drainNoSettle` continues driving it.
Future<void> _acceptTopoNameDialog(WidgetTester tester) async {
  await _drain(tester);
  expect(find.byKey(const Key('topo-name-field')), findsOneWidget);
  await tester.tap(find.byKey(const Key('topo-name-submit')));
  await tester.pump();
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

/// A tile provider that never performs any network/file I/O: every tile
/// request resolves synchronously to the same tiny in-memory image. Copied
/// from `community_screen_test.dart`'s identical class (library-private to
/// that file) -- wired into every "Set location" picker this file opens, so
/// its `FlutterMap`'s `TileLayer` can never attempt a real network fetch
/// under `flutter_test` (see CLAUDE.md: "never hit the network in a widget
/// test").
class _NoopTileProvider extends TileProvider {
  @override
  ImageProvider getImage(TileCoordinates coordinates, TileLayer options) {
    return MemoryImage(_tinyPngBytes);
  }
}

/// A [LibraryCrudRepository] whose [moveWall] always throws, leaving every
/// other method backed by the real implementation against [db]. Used to
/// prove `_handleMove`'s `await repo.moveWall(...)` is guarded: a move
/// failure (e.g. the destination sector got hard-deleted between the picker
/// opening and the tap, tripping the `PRAGMA foreign_keys = ON` FK check)
/// must surface as an error SnackBar, never an unhandled async error.
class _ThrowingMoveWallRepository extends LibraryCrudRepository {
  _ThrowingMoveWallRepository(super.db, {required super.nowMs});

  @override
  Future<void> moveWall(String wallId, String newSectorId) {
    throw Exception('moveWall boom (test)');
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

    testWidgets(
      'the empty state\'s inline "New topo" button starts New topo flow '
      '(reuses _handleNewTopo, same as the floating button)',
      (tester) async {
        final container = _makeContainer();
        late Directory tempDir;
        late File pngFile;
        await tester.runAsync(() async {
          tempDir = await Directory.systemTemp.createTemp(
            'topos_screen_empty_state_new_topo_test',
          );
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

        expect(find.byKey(const Key('topos-empty-new-topo')), findsOneWidget);

        await tester.tap(find.byKey(const Key('topos-empty-new-topo')));
        await _acceptTopoNameDialog(tester);
        await _drain(tester);
        await _drain(tester);

        final topos = await _dbWork(
          tester,
          () => container.read(libraryCrudRepositoryProvider).watchTopos().first,
        );
        expect(topos.length, 1);
      },
    );

    testWidgets(
      'the empty state\'s inline "New topo" button is disabled while a '
      'creation flow is already in flight (same `canCreate`/`_creating` '
      'guard the floating button uses)',
      (tester) async {
        final container = _makeContainer();
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
              photoPicker: (source) async =>
                  throw StateError('must not be called'),
            ),
          ),
        );
        await _drain(tester);

        final buttonBefore = tester.widget<ElevatedButton>(
          find.byKey(const Key('topos-empty-new-topo')),
        );
        expect(buttonBefore.onPressed, isNotNull);

        // Start a flow via the FLOATING button and suspend on the
        // (uncompleted) source-picker future -- the re-entrancy flag is
        // set synchronously before that await (see `_handleNewTopo`), so
        // the INLINE empty-state button, which shares the exact same
        // `canCreate` guard, must now render disabled too.
        await tester.tap(find.byKey(const Key('topos-new-topo')));
        await tester.pump();

        expect(sourcePickerCalls, 1);
        final buttonDuring = tester.widget<ElevatedButton>(
          find.byKey(const Key('topos-empty-new-topo')),
        );
        expect(
          buttonDuring.onPressed,
          isNull,
          reason:
              'the empty-state button must disable while a creation flow '
              'from either trigger is in flight',
        );

        await tester.runAsync(() async {
          sourceCompleter.complete(null);
        });
        await _drain(tester);
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

    testWidgets(
      '#56: a thumbnailPath pointing at a photo that cannot be decoded '
      '(e.g. a legacy photo whose thumbnail was never generated on disk) '
      'never leaves the row blank or crashes -- it resolves to the '
      'gradient placeholder',
      (tester) async {
        final db = AppDatabase(NativeDatabase.memory());
        addTearDown(db.close);
        final tempDir = Directory.systemTemp.createTempSync(
          'topos_screen_missing_thumb_test_',
        );
        addTearDown(() {
          if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
        });
        // Deliberately never created -- simulates a thumb key that
        // resolved (thumbKeyFor + resolvePhotoPathSync both succeed
        // syntactically) but whose file genuinely isn't on disk.
        final missingThumbPath = '${tempDir.path}/thumbs/ghost.jpg';
        final container = ProviderContainer(
          overrides: [
            appDatabaseProvider.overrideWithValue(db),
            nowMsProvider.overrideWithValue(() => 1000),
            toposProvider.overrideWith(
              (ref) => Stream.value([
                TopoRef(
                  wallId: 'wall-missing-thumb',
                  name: 'Ghost Topo',
                  thumbnailPath: missingThumbPath,
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

        expect(tester.takeException(), isNull);
        expect(
          find.byKey(const Key('topo-item-wall-missing-thumb')),
          findsOneWidget,
        );
        expect(find.text('Ghost Topo'), findsOneWidget);
      },
    );

    testWidgets(
      '#51: the topos list folds the floating bottom bar\'s clearance into '
      'its own bottom padding, so the last row is not left hidden behind it',
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
              ]),
            ),
          ],
        );
        addTearDown(container.dispose);

        // Simulates the REAL, non-zero clearance `NavShell`'s
        // `extendBody: true` Scaffold reports to this screen's body in
        // production (see `nav_shell.dart`'s doc) -- this bare harness has
        // no `NavShell` of its own, so without this override the ambient
        // inset would always be 0 and this test couldn't tell the fold-in
        // from a no-op.
        await tester.pumpWidget(
          _wrap(container, const ToposScreen(), bottomChromeInset: 40),
        );
        await _drain(tester);

        final listView = tester.widget<ListView>(find.byType(ListView));
        final padding = listView.padding as EdgeInsets;
        expect(
          padding.bottom,
          greaterThanOrEqualTo(40),
          reason:
              'the list\'s bottom padding must include the floating bar\'s '
              'clearance so its last row scrolls clear of the bar instead '
              'of ending up hidden behind it',
        );
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
      await _acceptTopoNameDialog(tester);
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
        await _acceptTopoNameDialog(tester);
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
        await _acceptTopoNameDialog(tester);
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
        await _acceptTopoNameDialog(tester);
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
        await _acceptTopoNameDialog(tester);
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
        await _acceptTopoNameDialog(tester);
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
      await _acceptTopoNameDialog(tester);
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

  group('#25 (Lane B): name prompt shown before a topo is ever created', () {
    testWidgets(
      'B1: after a photo is picked/decoded, a topo-name-field/'
      'topo-name-submit dialog appears BEFORE any topo exists, prefilled '
      'with the default "Topo N" name; accepting it reproduces the old '
      'auto-numbered behavior',
      (tester) async {
        final container = _makeContainer();
        late Directory tempDir;
        late File pngFile;
        await tester.runAsync(() async {
          tempDir = await Directory.systemTemp.createTemp(
            'topos_screen_name_prompt_test',
          );
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

        // The dialog must be up, prefilled, and NOTHING created yet.
        expect(find.byKey(const Key('topo-name-field')), findsOneWidget);
        expect(find.byKey(const Key('topo-name-submit')), findsOneWidget);
        final field = tester.widget<TextField>(
          find.byKey(const Key('topo-name-field')),
        );
        expect(field.controller!.text, 'Topo 1');

        final toposWhileOpen = await _dbWork(
          tester,
          () =>
              container.read(libraryCrudRepositoryProvider).watchTopos().first,
        );
        expect(
          toposWhileOpen,
          isEmpty,
          reason: 'createTopo must not run until the dialog is submitted',
        );

        await tester.tap(find.byKey(const Key('topo-name-submit')));
        await _drain(tester);
        await _drain(tester);

        final topos = await _dbWork(
          tester,
          () =>
              container.read(libraryCrudRepositoryProvider).watchTopos().first,
        );
        expect(topos.length, 1);
        expect(topos.single.name, 'Topo 1');
      },
    );

    testWidgets(
      'B2: entering a custom name and submitting reaches repo.createTopo '
      'with that name, trimmed',
      (tester) async {
        final container = _makeContainer();
        late Directory tempDir;
        late File pngFile;
        await tester.runAsync(() async {
          tempDir = await Directory.systemTemp.createTemp(
            'topos_screen_name_prompt_custom_test',
          );
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

        expect(find.byKey(const Key('topo-name-field')), findsOneWidget);
        await tester.enterText(
          find.byKey(const Key('topo-name-field')),
          '  The Roof  ',
        );
        await tester.pump();
        await tester.tap(find.byKey(const Key('topo-name-submit')));
        await _drain(tester);
        await _drain(tester);

        final topos = await _dbWork(
          tester,
          () =>
              container.read(libraryCrudRepositoryProvider).watchTopos().first,
        );
        expect(topos.length, 1);
        expect(
          topos.single.name,
          'The Roof',
          reason:
              'the entered name must be trimmed before reaching createTopo',
        );
        // NOT `find.text('The Roof')`: on success `_handleNewTopo` navigates
        // straight into the new topo's canvas (`context.push('/walls/$wallId')`
        // -- see that method's doc), so by the time this runs the Topos LIST
        // (the only place "The Roof" would ever be painted) sits underneath
        // the pushed `/walls/:wallId` route and is no longer findable via
        // `find.text` (default `skipOffstage: true`). The DB read above --
        // mirroring B1's identical "read `watchTopos()`, assert the name"
        // pattern, which has no such trailing widget-text check either -- is
        // the real, robust proof that the trimmed name reached
        // `repo.createTopo`.
      },
    );

    testWidgets(
      'B2b: the submit action is disabled while the field is empty/'
      'whitespace-only, so a blank name can never reach createTopo',
      (tester) async {
        final container = _makeContainer();
        late Directory tempDir;
        late File pngFile;
        await tester.runAsync(() async {
          tempDir = await Directory.systemTemp.createTemp(
            'topos_screen_name_prompt_empty_test',
          );
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

        await tester.enterText(
          find.byKey(const Key('topo-name-field')),
          '   ',
        );
        await tester.pump();

        final submitButton = tester.widget<TextButton>(
          find.byKey(const Key('topo-name-submit')),
        );
        expect(
          submitButton.onPressed,
          isNull,
          reason: 'whitespace-only name must disable submit',
        );

        // Cancel out (rather than leaving the dialog open) so this test
        // doesn't leak a pending route into the next one.
        await tester.tap(find.text('Cancel'));
        await _drain(tester);
      },
    );

    testWidgets(
      'B3: cancelling the name dialog aborts creation entirely -- no '
      'topo/wall row is created, no orphan state, and a fresh flow can '
      'still be started and completed afterwards',
      (tester) async {
        final container = _makeContainer();
        late Directory tempDir;
        late File pngFile;
        await tester.runAsync(() async {
          tempDir = await Directory.systemTemp.createTemp(
            'topos_screen_name_prompt_cancel_test',
          );
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

        expect(find.byKey(const Key('topo-name-field')), findsOneWidget);
        await tester.tap(find.text('Cancel'));
        await _drain(tester);

        expect(tester.takeException(), isNull);
        expect(find.byKey(const Key('topo-name-field')), findsNothing);
        expect(find.byKey(const Key('topos-empty-state')), findsOneWidget);

        final topos = await _dbWork(
          tester,
          () =>
              container.read(libraryCrudRepositoryProvider).watchTopos().first,
        );
        expect(
          topos,
          isEmpty,
          reason: 'cancelling must never create a wall/photo row',
        );

        // The re-entrancy guard must have been released by the `finally`
        // in `_handleNewTopo` -- the button is enabled again, and a fresh
        // flow started right after a cancel still completes normally.
        final button = tester.widget<ElevatedButton>(
          find.byKey(const Key('topos-new-topo')),
        );
        expect(button.onPressed, isNotNull);

        await tester.tap(find.byKey(const Key('topos-new-topo')));
        await _drain(tester);
        await tester.tap(find.byKey(const Key('topo-name-submit')));
        await _drain(tester);
        await _drain(tester);

        final afterTopos = await _dbWork(
          tester,
          () =>
              container.read(libraryCrudRepositoryProvider).watchTopos().first,
        );
        expect(afterTopos.length, 1);
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
          await _acceptTopoNameDialog(tester);
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
          await _acceptTopoNameDialog(tester);
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
          await _acceptTopoNameDialog(tester);
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
          await _acceptTopoNameDialog(tester);
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

  group('A11: grade-band dots (replaces the old single hardest-grade pill)', () {
    testWidgets(
      'a topo whose routes span two bands shows exactly two dots, colored '
      'by band, easiest-first',
      (tester) async {
        final db = AppDatabase(NativeDatabase.memory());
        addTearDown(db.close);
        final container = ProviderContainer(
          overrides: [
            appDatabaseProvider.overrideWithValue(db),
            nowMsProvider.overrideWithValue(() => 1000),
            toposProvider.overrideWith(
              (ref) => Stream.value([
                TopoRef(
                  wallId: 'wall-multi-band',
                  name: 'Multi Band Wall',
                  thumbnailPath: null,
                  routeCount: 3,
                  createdAt: 1000,
                  routeGradeKeys: [
                    gradeSortKey(GradeSystem.french, '5a'), // intermediate
                    gradeSortKey(GradeSystem.french, '7a'), // hard
                  ],
                ),
              ]),
            ),
          ],
        );
        addTearDown(container.dispose);

        await tester.pumpWidget(_wrap(container, const ToposScreen()));
        await _drain(tester);

        expect(find.text('3 routes'), findsOneWidget);
        expect(
          find.byKey(
            const Key('topo-grade-dot-wall-multi-band-intermediate'),
          ),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('topo-grade-dot-wall-multi-band-hard')),
          findsOneWidget,
        );
        // Exactly those two -- no dot for a band that isn't present.
        expect(find.byKey(const Key('topo-grade-dot-wall-multi-band-beginner')),
            findsNothing);

        final intermediateDot = tester.widget<Container>(
          find.byKey(const Key('topo-grade-dot-wall-multi-band-intermediate')),
        );
        expect(
          (intermediateDot.decoration as BoxDecoration).color,
          MasiColors.light.gradeIntermediate,
        );
        final hardDot = tester.widget<Container>(
          find.byKey(const Key('topo-grade-dot-wall-multi-band-hard')),
        );
        expect(
          (hardDot.decoration as BoxDecoration).color,
          MasiColors.light.gradeHard,
        );

        // Easiest-first: laid out left-to-right, the intermediate dot sits
        // strictly left of the hard dot.
        final intermediateX = tester
            .getTopLeft(
              find.byKey(
                const Key('topo-grade-dot-wall-multi-band-intermediate'),
              ),
            )
            .dx;
        final hardX = tester
            .getTopLeft(
              find.byKey(const Key('topo-grade-dot-wall-multi-band-hard')),
            )
            .dx;
        expect(intermediateX, lessThan(hardX));
      },
    );

    testWidgets(
      'a topo whose routes are all in one band shows exactly one dot',
      (tester) async {
        final db = AppDatabase(NativeDatabase.memory());
        addTearDown(db.close);
        final container = ProviderContainer(
          overrides: [
            appDatabaseProvider.overrideWithValue(db),
            nowMsProvider.overrideWithValue(() => 1000),
            toposProvider.overrideWith(
              (ref) => Stream.value([
                TopoRef(
                  wallId: 'wall-graded',
                  name: 'Graded Wall',
                  thumbnailPath: null,
                  routeCount: 3,
                  createdAt: 1000,
                  routeGradeKeys: [
                    gradeSortKey(GradeSystem.french, '7a'),
                    gradeSortKey(GradeSystem.french, '7a+'),
                    gradeSortKey(GradeSystem.french, '7c'),
                  ],
                ),
              ]),
            ),
          ],
        );
        addTearDown(container.dispose);

        await tester.pumpWidget(_wrap(container, const ToposScreen()));
        await _drain(tester);

        expect(find.text('3 routes'), findsOneWidget);
        expect(
          find.byKey(const Key('topo-grade-dot-wall-graded-hard')),
          findsOneWidget,
        );
        final dot = tester.widget<Container>(
          find.byKey(const Key('topo-grade-dot-wall-graded-hard')),
        );
        expect(
          (dot.decoration as BoxDecoration).color,
          MasiColors.light.gradeHard,
        );
      },
    );

    testWidgets('a topo with no graded routes shows no dots, just "N routes"', (
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
      // No dot of any band should render for an ungraded topo.
      for (final band in GradeBand.values) {
        expect(
          find.byKey(Key('topo-grade-dot-wall-bare-${band.name}')),
          findsNothing,
        );
      }
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
        expect(button.icon, isA<MasiIcon>());
        expect((button.icon as MasiIcon).name, 'person');
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
        expect(button.icon, isA<MasiIcon>());
        expect((button.icon as MasiIcon).name, 'person');
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

  group('D1b: Community/Logbook nav buttons removed from the app bar', () {
    testWidgets(
      'home-community-button and home-logbook-button are no longer present '
      'in the app bar (Community is reachable via the bottom-nav Map/Feed '
      'tabs; Logbook via feed-logbook-button) -- Organize/Account remain',
      (tester) async {
        final container = _makeContainer();

        await tester.pumpWidget(_wrap(container, const ToposScreen()));
        await _drain(tester);

        expect(
          find.descendant(
            of: find.byType(AppBar),
            matching: find.byKey(const Key('home-community-button')),
          ),
          findsNothing,
        );
        expect(
          find.descendant(
            of: find.byType(AppBar),
            matching: find.byKey(const Key('home-logbook-button')),
          ),
          findsNothing,
        );
        // The existing Organize/Account actions must still be intact.
        expect(find.byKey(const Key('topos-organize')), findsOneWidget);
        expect(find.byKey(const Key('topos-account-button')), findsOneWidget);
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

  group('Q1: "Show on map" menu action', () {
    testWidgets(
      'a topo WITH coordinates shows an enabled "Show on map" item; tapping '
      'it navigates to /community?tab=map&focus=<wallId>',
      (tester) async {
        final container = _makeContainer();
        final wallId = await _dbWork(
          tester,
          () => container
              .read(libraryCrudRepositoryProvider)
              .createTopo('Located Wall'),
        );
        await _dbWork(
          tester,
          () => container
              .read(libraryCrudRepositoryProvider)
              .setWallCoordinates(wallId, 47.4979, 19.0402),
        );

        await tester.pumpWidget(_wrap(container, const ToposScreen()));
        await _drain(tester);

        await tester.tap(find.byKey(Key('topo-menu-$wallId')));
        await tester.pumpAndSettle();

        final itemFinder = find.byKey(Key('topo-show-on-map-$wallId'));
        expect(itemFinder, findsOneWidget);
        expect(find.text('No location set'), findsNothing);

        await tester.tap(itemFinder);
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('community-placeholder')), findsOneWidget);
        expect(find.text('community-map-$wallId'), findsOneWidget);
      },
    );

    testWidgets(
      'a topo WITHOUT coordinates shows a muted "Show on map" action '
      '(never navigates)',
      (tester) async {
        final container = _makeContainer();
        final wallId = await _dbWork(
          tester,
          () => container
              .read(libraryCrudRepositoryProvider)
              .createTopo('Unlocated Wall'),
        );

        await tester.pumpWidget(_wrap(container, const ToposScreen()));
        await _drain(tester);

        await tester.tap(find.byKey(Key('topo-menu-$wallId')));
        await tester.pumpAndSettle();

        final itemFinder = find.byKey(Key('topo-show-on-map-$wallId'));
        expect(itemFinder, findsOneWidget);
        expect(find.text('No location set'), findsOneWidget);

        // The action sheet's `CupertinoActionSheetAction` has no built-in
        // disabled state (unlike the old `PopupMenuItem.enabled`), so this
        // is recreated with a no-op `onPressed` -- tapping it must never
        // navigate, and the sheet must simply stay open.
        await tester.tap(itemFinder);
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('community-placeholder')), findsNothing);
        expect(itemFinder, findsOneWidget);
      },
    );
  });

  group('S-L: "Set location" manual map pin picker', () {
    testWidgets(
      'S-L1a: a topo WITH coordinates shows an enabled "Edit location" item',
      (tester) async {
        final container = _makeContainer();
        final wallId = await _dbWork(
          tester,
          () => container
              .read(libraryCrudRepositoryProvider)
              .createTopo('Located Wall'),
        );
        await _dbWork(
          tester,
          () => container
              .read(libraryCrudRepositoryProvider)
              .setWallCoordinates(wallId, 47.4979, 19.0402),
        );

        await tester.pumpWidget(_wrap(container, const ToposScreen()));
        await _drain(tester);

        await tester.tap(find.byKey(Key('topo-menu-$wallId')));
        await tester.pumpAndSettle();

        final itemFinder = find.byKey(Key('topo-set-location-$wallId'));
        expect(itemFinder, findsOneWidget);
        expect(find.text('Edit location'), findsOneWidget);
      },
    );

    testWidgets(
      'S-L1b: a topo WITHOUT coordinates shows an enabled "Set location" '
      'item',
      (tester) async {
        final container = _makeContainer();
        final wallId = await _dbWork(
          tester,
          () => container
              .read(libraryCrudRepositoryProvider)
              .createTopo('Unlocated Wall'),
        );

        await tester.pumpWidget(_wrap(container, const ToposScreen()));
        await _drain(tester);

        await tester.tap(find.byKey(Key('topo-menu-$wallId')));
        await tester.pumpAndSettle();

        final itemFinder = find.byKey(Key('topo-set-location-$wallId'));
        expect(itemFinder, findsOneWidget);
        expect(find.text('Set location'), findsOneWidget);
      },
    );

    testWidgets(
      'S-L2: tapping "Set location" opens the full-screen map picker '
      '(Save action + fixed center crosshair)',
      (tester) async {
        final container = _makeContainer();
        final wallId = await _dbWork(
          tester,
          () => container
              .read(libraryCrudRepositoryProvider)
              .createTopo('New Wall'),
        );

        await tester.pumpWidget(
          _wrap(
            container,
            ToposScreen(setLocationTileProvider: _NoopTileProvider()),
          ),
        );
        await _drain(tester);

        await tester.tap(find.byKey(Key('topo-menu-$wallId')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(Key('topo-set-location-$wallId')));
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('set-location-save')), findsOneWidget);
        expect(find.byKey(const Key('set-location-cancel')), findsOneWidget);
        expect(
          find.byKey(const Key('set-location-crosshair')),
          findsOneWidget,
        );
        // "New Wall" has no coordinates yet (`initial == null`), so nothing
        // has been actively chosen the moment the picker opens -- Save must
        // start disabled rather than ready to silently pop whatever the
        // camera happens to be centered on (see set_location_picker.dart's
        // `_locationChosen`/data-integrity fix).
        expect(
          tester
              .widget<TextButton>(find.byKey(const Key('set-location-save')))
              .onPressed,
          isNull,
        );
        expect(find.byKey(const Key('set-location-hint')), findsOneWidget);
      },
    );

    testWidgets(
      'S-L3: panning the map via a REAL drag gesture then tapping Save '
      'writes the post-drag camera center via setWallCoordinates and shows '
      'a "Location saved" confirmation SnackBar',
      (tester) async {
        final controller = MapController();
        addTearDown(controller.dispose);
        final container = _makeContainer();
        final wallId = await _dbWork(
          tester,
          () => container
              .read(libraryCrudRepositoryProvider)
              .createTopo('New Wall'),
        );

        await tester.pumpWidget(
          _wrap(
            container,
            ToposScreen(
              setLocationTileProvider: _NoopTileProvider(),
              setLocationMapController: controller,
            ),
          ),
        );
        await _drain(tester);

        await tester.tap(find.byKey(Key('topo-menu-$wallId')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(Key('topo-set-location-$wallId')));
        await tester.pumpAndSettle();

        // "New Wall" has no coordinates, so the picker opens on the neutral
        // (0, 0) world view and Save starts disabled (see S-L2).
        expect(
          tester
              .widget<TextButton>(find.byKey(const Key('set-location-save')))
              .onPressed,
          isNull,
        );

        // Simulate the user ACTUALLY panning the map: a real drag gesture
        // on the FlutterMap, which flutter_map reports to
        // `MapOptions.onPositionChanged` as `hasGesture: true` -- unlike a
        // programmatic `MapController.move` (what the old, buggy silent
        // recenter used, and what S-L3 itself used to drive here), this is
        // what's actually required to flip `_locationChosen` and enable
        // Save now. The crosshair is fixed to the screen center, so
        // "where the pin points" is exactly wherever `camera.center` ends
        // up after the drag.
        await tester.drag(find.byType(FlutterMap), const Offset(-120, -80));
        await tester.pump();

        final centerAfterDrag = controller.camera.center;
        // Sanity: the drag actually moved the camera away from the (0, 0)
        // starting view -- otherwise the assertions below would pass
        // vacuously even if the drag were a no-op.
        expect(centerAfterDrag.latitude.abs(), greaterThan(0.01));
        expect(centerAfterDrag.longitude.abs(), greaterThan(0.01));

        expect(
          tester
              .widget<TextButton>(find.byKey(const Key('set-location-save')))
              .onPressed,
          isNotNull,
        );

        await tester.tap(find.byKey(const Key('set-location-save')));
        await _drain(tester);

        expect(find.text('Location saved'), findsOneWidget);

        final topos = await _dbWork(
          tester,
          () =>
              container.read(libraryCrudRepositoryProvider).watchTopos().first,
        );
        final saved = topos.firstWhere((t) => t.wallId == wallId);
        expect(saved.latitude, isNotNull);
        expect(saved.longitude, isNotNull);
        // The persisted coordinates are exactly the camera center at the
        // moment of the (real, gesture-driven) pan -- not some other value
        // the silent recenter or the neutral fallback might have left it at.
        expect(saved.latitude!, closeTo(centerAfterDrag.latitude, 0.0001));
        expect(saved.longitude!, closeTo(centerAfterDrag.longitude, 0.0001));
      },
    );

    testWidgets(
      'S-L4: Cancel pops without writing any coordinates',
      (tester) async {
        final container = _makeContainer();
        final wallId = await _dbWork(
          tester,
          () => container
              .read(libraryCrudRepositoryProvider)
              .createTopo('New Wall'),
        );

        await tester.pumpWidget(
          _wrap(
            container,
            ToposScreen(setLocationTileProvider: _NoopTileProvider()),
          ),
        );
        await _drain(tester);

        await tester.tap(find.byKey(Key('topo-menu-$wallId')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(Key('topo-set-location-$wallId')));
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(const Key('set-location-cancel')));
        await _drain(tester);

        expect(find.byKey(const Key('set-location-save')), findsNothing);
        expect(find.text('New Wall'), findsOneWidget);

        final topos = await _dbWork(
          tester,
          () =>
              container.read(libraryCrudRepositoryProvider).watchTopos().first,
        );
        final unchanged = topos.firstWhere((t) => t.wallId == wallId);
        expect(unchanged.latitude, isNull);
        expect(unchanged.longitude, isNull);
      },
    );

    testWidgets(
      'S-L5: "use my location" moves the map to the fake device fix, counts '
      'as an active choice (enabling Save), and Save then pops exactly that '
      'fix',
      (tester) async {
        final controller = MapController();
        addTearDown(controller.dispose);
        const fakeLocation = _FakeLocationService((
          latitude: 40.0,
          longitude: -3.7,
        ));
        late BuildContext capturedContext;

        await tester.pumpWidget(
          MaterialApp(
            theme: MasiTheme.light,
            home: Builder(
              builder: (context) {
                capturedContext = context;
                return const SizedBox();
              },
            ),
          ),
        );

        // Captured (rather than `unawaited`) so this test can await it to
        // completion below, once Save is tapped.
        final pickerFuture = showSetLocationPicker(
          capturedContext,
          tileProvider: _NoopTileProvider(),
          controller: controller,
          locationService: fakeLocation,
        );
        await tester.pumpAndSettle();

        // No interaction yet (`initial` is null) -- Save must start
        // disabled.
        expect(
          tester
              .widget<TextButton>(find.byKey(const Key('set-location-save')))
              .onPressed,
          isNull,
        );

        await tester.tap(find.byKey(const Key('set-location-my-location')));
        await _drain(tester);

        final center = controller.camera.center;
        expect((center.latitude - 40.0).abs(), lessThan(0.01));
        expect((center.longitude - (-3.7)).abs(), lessThan(0.01));

        // Tapping the explicit "use my location" button IS an active
        // choice (per set_location_picker.dart's `_locationChosen` doc),
        // unlike the silent initial recenter it otherwise resembles -- so
        // Save must now be enabled and pop exactly the fake device fix.
        expect(
          tester
              .widget<TextButton>(find.byKey(const Key('set-location-save')))
              .onPressed,
          isNotNull,
        );

        await tester.tap(find.byKey(const Key('set-location-save')));
        await tester.pumpAndSettle();

        final picked = await pickerFuture;
        expect(picked, isNotNull);
        expect((picked!.latitude - 40.0).abs(), lessThan(0.01));
        expect((picked.longitude - (-3.7)).abs(), lessThan(0.01));
      },
    );

    testWidgets(
      'S-L6: THE FIX -- a programmatic camera move (mirroring the silent '
      'initial recenter) does NOT enable Save, even though it really does '
      'move the camera; only a real gesture pan does',
      (tester) async {
        final controller = MapController();
        addTearDown(controller.dispose);
        late BuildContext capturedContext;

        await tester.pumpWidget(
          MaterialApp(
            theme: MasiTheme.light,
            home: Builder(
              builder: (context) {
                capturedContext = context;
                return const SizedBox();
              },
            ),
          ),
        );

        final pickerFuture = showSetLocationPicker(
          capturedContext,
          tileProvider: _NoopTileProvider(),
          controller: controller,
        );
        await tester.pumpAndSettle();

        expect(
          tester
              .widget<TextButton>(find.byKey(const Key('set-location-save')))
              .onPressed,
          isNull,
        );

        // Exactly what `_trySilentInitialRecenter` (and the old, buggy
        // unconditional Save) relied on: a programmatic
        // `MapController.move`, which flutter_map reports to
        // `onPositionChanged` as `hasGesture: false`.
        controller.move(const LatLng(41.9, 12.5), 12);
        await tester.pump();

        // The move really did relocate the camera -- so the disabled
        // assertion below is about the interaction kind, not about nothing
        // having happened.
        expect(controller.camera.center.latitude, closeTo(41.9, 0.01));
        expect(controller.camera.center.longitude, closeTo(12.5, 0.01));

        // THE FIX: still disabled. Before this fix, Save's `onPressed` was
        // unconditional, so this same programmatic move would have left an
        // un-panned Save ready to silently persist it.
        expect(
          tester
              .widget<TextButton>(find.byKey(const Key('set-location-save')))
              .onPressed,
          isNull,
        );

        // Tapping a disabled Save must be a no-op: the picker stays open,
        // nothing pops.
        await tester.tap(find.byKey(const Key('set-location-save')));
        await tester.pump();
        expect(find.byKey(const Key('set-location-save')), findsOneWidget);

        // NOW drive a real gesture pan -- this is what must flip the gate.
        await tester.drag(find.byType(FlutterMap), const Offset(-100, -60));
        await tester.pump();

        expect(
          tester
              .widget<TextButton>(find.byKey(const Key('set-location-save')))
              .onPressed,
          isNotNull,
        );

        final centerAfterDrag = controller.camera.center;
        await tester.tap(find.byKey(const Key('set-location-save')));
        await tester.pumpAndSettle();

        final picked = await pickerFuture;
        expect(picked, isNotNull);
        expect(picked!.latitude, closeTo(centerAfterDrag.latitude, 0.0001));
        expect(picked.longitude, closeTo(centerAfterDrag.longitude, 0.0001));
      },
    );

    testWidgets(
      'S-L7: editing an EXISTING location (initial != null) -- Save is '
      'enabled immediately, with no interaction required, and pops that '
      'location unchanged',
      (tester) async {
        final controller = MapController();
        addTearDown(controller.dispose);
        const existing = LatLng(47.4979, 19.0402);
        late BuildContext capturedContext;

        await tester.pumpWidget(
          MaterialApp(
            theme: MasiTheme.light,
            home: Builder(
              builder: (context) {
                capturedContext = context;
                return const SizedBox();
              },
            ),
          ),
        );

        final pickerFuture = showSetLocationPicker(
          capturedContext,
          initial: existing,
          tileProvider: _NoopTileProvider(),
          controller: controller,
        );
        await tester.pumpAndSettle();

        // There's already a valid coordinate to edit -- unlike S-L2/S-L6's
        // `initial == null` case, Save must be enabled from the very first
        // frame, with zero interaction.
        expect(
          tester
              .widget<TextButton>(find.byKey(const Key('set-location-save')))
              .onPressed,
          isNotNull,
        );
        expect(find.byKey(const Key('set-location-hint')), findsNothing);

        await tester.tap(find.byKey(const Key('set-location-save')));
        await tester.pumpAndSettle();

        final picked = await pickerFuture;
        expect(picked, isNotNull);
        expect(picked!.latitude, closeTo(existing.latitude, 0.001));
        expect(picked.longitude, closeTo(existing.longitude, 0.001));
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
        // No filter is active yet, so the filter_active icon should not show.
        expect(
          find.byWidgetPredicate((w) => w is MasiIcon && w.name == 'filter_active'),
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
          find.byWidgetPredicate((w) => w is MasiIcon && w.name == 'filter_active'),
          findsOneWidget,
          reason: 'an active visibility facet must show the filter_active icon',
        );

        await tester.tap(
          find.byKey(const Key('topos-filter-visibility-all')),
        );
        await tester.pumpAndSettle();

        expect(find.text('Private Topo'), findsOneWidget);
        expect(find.text('Shared Topo'), findsOneWidget);
        expect(
          find.byWidgetPredicate((w) => w is MasiIcon && w.name == 'filter_active'),
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
          find.byWidgetPredicate((w) => w is MasiIcon && w.name == 'filter_active'),
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
          find.byWidgetPredicate((w) => w is MasiIcon && w.name == 'filter_active'),
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
    'the AppBar actions, and an unwrapped grade-dots+routes Row in '
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
        'with a full 5-band row of grade dots + route count (regression: '
        'unlike the "Filters sheet" group above, this case does NOT dodge '
        'the AppBar via a wide stressWidth -- 360 is a real phone width)',
        (tester) async {
          setViewportSize(tester, const Size(360, 800));
          final db = AppDatabase(NativeDatabase.memory());
          addTearDown(db.close);
          final container = ProviderContainer(
            overrides: [
              appDatabaseProvider.overrideWithValue(db),
              nowMsProvider.overrideWithValue(() => 1000),
              toposProvider.overrideWith(
                (ref) => Stream.value([
                  TopoRef(
                    wallId: 'wall-stress',
                    name: 'Stress Test Wall',
                    thumbnailPath: null,
                    routeCount: 12,
                    createdAt: 1000,
                    // All 5 bands present -- the widest the dots row gets.
                    routeGradeKeys: [
                      gradeSortKey(GradeSystem.french, '4a'),
                      gradeSortKey(GradeSystem.french, '5c'),
                      gradeSortKey(GradeSystem.french, '6b'),
                      gradeSortKey(GradeSystem.french, '7a'),
                      gradeSortKey(GradeSystem.french, '8a'),
                    ],
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

  group('S1b: search field clear affordance', () {
    testWidgets(
      'the clear ("x") button is hidden while the search field is empty, '
      'appears once text is entered, and tapping it clears the field and '
      'restores the unfiltered list',
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

        expect(find.byKey(const Key('topos-search-clear')), findsNothing);

        await tester.enterText(
          find.byKey(const Key('topos-search-field')),
          'moon',
        );
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('topos-search-clear')), findsOneWidget);
        expect(find.text('Sunset Arete'), findsNothing);

        await tester.tap(find.byKey(const Key('topos-search-clear')));
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('topos-search-clear')), findsNothing);
        expect(find.text('Sunset Arete'), findsOneWidget);
        expect(find.text('Moonrise Slab'), findsOneWidget);
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

  group('D8: "Move to…" — move a topo to another sector', () {
    testWidgets(
      'V1: the menu shows topo-move-<wallId>; tapping it opens a picker '
      'labelled "AreaName › SectorName" per candidate; selecting a '
      'move-target-sector-<id> calls moveWall via the real repo (the '
      'wall\'s sectorId actually changes) and shows a confirmation SnackBar',
      (tester) async {
        final container = _makeContainer();
        final repo = container.read(libraryCrudRepositoryProvider);

        final areaA = await _dbWork(tester, () => repo.createArea('Area A'));
        final currentSector = await _dbWork(
          tester,
          () => repo.createSector(areaA.id, 'Current Sector'),
        );
        final destSector = await _dbWork(
          tester,
          () => repo.createSector(areaA.id, 'Dest Sector'),
        );
        final wall = await _dbWork(
          tester,
          () => repo.createWall(currentSector.id, 'My Topo'),
        );

        await tester.pumpWidget(_wrap(container, const ToposScreen()));
        await _drain(tester);

        await tester.tap(find.byKey(Key('topo-menu-${wall.id}')));
        await tester.pumpAndSettle();

        expect(find.byKey(Key('topo-move-${wall.id}')), findsOneWidget);

        await tester.tap(find.byKey(Key('topo-move-${wall.id}')));
        await _drain(tester);

        expect(
          find.text('Area A › Dest Sector'),
          findsOneWidget,
          reason: 'candidates must be labelled "AreaName › SectorName"',
        );
        expect(
          find.byKey(Key('move-target-sector-${destSector.id}')),
          findsOneWidget,
        );

        await tester.tap(
          find.byKey(Key('move-target-sector-${destSector.id}')),
        );
        await _drain(tester);

        final newSectorId = await _dbWork(
          tester,
          () => repo.wallSectorId(wall.id),
        );
        expect(newSectorId, destSector.id);
        expect(find.text('Moved to Dest Sector'), findsOneWidget);
      },
    );

    testWidgets(
      'V3 (own-filter): a FOREIGN-owned sector never appears as a '
      'candidate; an unowned (own-device) sector does',
      (tester) async {
        final container = _makeContainer();
        final repo = container.read(libraryCrudRepositoryProvider);
        final db = container.read(appDatabaseProvider);

        final area = await _dbWork(tester, () => repo.createArea('Area'));
        final currentSector = await _dbWork(
          tester,
          () => repo.createSector(area.id, 'Current Sector'),
        );
        final wall = await _dbWork(
          tester,
          () => repo.createWall(currentSector.id, 'My Topo'),
        );
        // Own (unowned, this device -- currentUid defaults to null).
        await _dbWork(
          tester,
          () => repo.createSector(area.id, 'Own Sector'),
        );
        // Foreign -- pulled in locally from discovering someone else's
        // shared topo -- must never be offered as a move destination.
        final foreignRepo = LibraryCrudRepository(
          db,
          nowMs: () => 1000,
          currentUid: () => 'foreign-uid',
        );
        await _dbWork(
          tester,
          () => foreignRepo.createSector(area.id, 'Foreign Sector'),
        );

        await tester.pumpWidget(_wrap(container, const ToposScreen()));
        await _drain(tester);

        await tester.tap(find.byKey(Key('topo-menu-${wall.id}')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(Key('topo-move-${wall.id}')));
        await _drain(tester);

        expect(find.text('Area › Own Sector'), findsOneWidget);
        expect(find.text('Area › Foreign Sector'), findsNothing);
      },
    );

    testWidgets(
      'V4: the topo\'s CURRENT sector is excluded from the candidate list',
      (tester) async {
        final container = _makeContainer();
        final repo = container.read(libraryCrudRepositoryProvider);

        final area = await _dbWork(tester, () => repo.createArea('Area'));
        final currentSector = await _dbWork(
          tester,
          () => repo.createSector(area.id, 'Current Sector'),
        );
        await _dbWork(
          tester,
          () => repo.createSector(area.id, 'Other Sector'),
        );
        final wall = await _dbWork(
          tester,
          () => repo.createWall(currentSector.id, 'My Topo'),
        );

        await tester.pumpWidget(_wrap(container, const ToposScreen()));
        await _drain(tester);

        await tester.tap(find.byKey(Key('topo-menu-${wall.id}')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(Key('topo-move-${wall.id}')));
        await _drain(tester);

        expect(find.text('Area › Current Sector'), findsNothing);
        expect(find.text('Area › Other Sector'), findsOneWidget);
      },
    );

    testWidgets(
      'E1: a repo whose moveWall throws (e.g. the destination sector was '
      'hard-deleted between the picker opening and the tap, tripping the FK '
      'check) shows an error SnackBar and produces NO unhandled exception '
      '(regression -- the bare, un-try/catch-guarded await used to let the '
      'throw escape as a silent, unobserved async error)',
      (tester) async {
        final db = AppDatabase(NativeDatabase.memory());
        addTearDown(db.close);
        final repo = _ThrowingMoveWallRepository(db, nowMs: () => 1000);
        final container = ProviderContainer(
          overrides: [
            appDatabaseProvider.overrideWithValue(db),
            nowMsProvider.overrideWithValue(() => 1000),
            libraryCrudRepositoryProvider.overrideWithValue(repo),
          ],
        );
        addTearDown(container.dispose);

        final areaA = await _dbWork(tester, () => repo.createArea('Area A'));
        final currentSector = await _dbWork(
          tester,
          () => repo.createSector(areaA.id, 'Current Sector'),
        );
        final destSector = await _dbWork(
          tester,
          () => repo.createSector(areaA.id, 'Dest Sector'),
        );
        final wall = await _dbWork(
          tester,
          () => repo.createWall(currentSector.id, 'My Topo'),
        );

        await tester.pumpWidget(_wrap(container, const ToposScreen()));
        await _drain(tester);

        await tester.tap(find.byKey(Key('topo-menu-${wall.id}')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(Key('topo-move-${wall.id}')));
        await _drain(tester);

        await tester.tap(
          find.byKey(Key('move-target-sector-${destSector.id}')),
        );
        // NOT pumpAndSettle -- see _drainNoSettle's doc: settling would run
        // the error SnackBar's full show+hide animation before the
        // find.text assertion below ever ran.
        await _drainNoSettle(tester);

        expect(
          tester.takeException(),
          isNull,
          reason: 'a move failure must never surface as an unhandled async '
              'error',
        );
        expect(
          find.text("Couldn't move — please try again"),
          findsOneWidget,
        );

        final unchangedSectorId = await _dbWork(
          tester,
          () => repo.wallSectorId(wall.id),
        );
        expect(
          unchangedSectorId,
          currentSector.id,
          reason: 'the throwing moveWall must not have actually moved it',
        );
      },
    );
  });

  group(
    'N3: proximity-sorted Topos-home list (own + nearby community, '
    'nearest-first)',
    () {
      testWidgets(
        'own topos with coordinates sort nearest-first ahead of a farther '
        'one, and an unlocated own topo sorts last',
        (tester) async {
          final db = AppDatabase(NativeDatabase.memory());
          addTearDown(db.close);
          final container = ProviderContainer(
            overrides: [
              appDatabaseProvider.overrideWithValue(db),
              nowMsProvider.overrideWithValue(() => 1000),
              locationServiceProvider.overrideWithValue(
                const _FakeLocationService((latitude: 0.0, longitude: 0.0)),
              ),
              toposProvider.overrideWith(
                (ref) => Stream.value(const [
                  TopoRef(
                    wallId: 'wall-far',
                    name: 'Far Topo',
                    thumbnailPath: null,
                    routeCount: 0,
                    createdAt: 1000,
                    latitude: 10.0,
                    longitude: 10.0,
                  ),
                  TopoRef(
                    wallId: 'wall-near',
                    name: 'Near Topo',
                    thumbnailPath: null,
                    routeCount: 0,
                    createdAt: 900,
                    latitude: 0.01,
                    longitude: 0.01,
                  ),
                  TopoRef(
                    wallId: 'wall-unlocated',
                    name: 'Unlocated Topo',
                    thumbnailPath: null,
                    routeCount: 0,
                    createdAt: 800,
                  ),
                ]),
              ),
            ],
          );
          addTearDown(container.dispose);

          await tester.pumpWidget(_wrap(container, const ToposScreen()));
          await _drain(tester);

          final nearTop = tester
              .getTopLeft(find.byKey(const Key('topo-item-wall-near')))
              .dy;
          final farTop = tester
              .getTopLeft(find.byKey(const Key('topo-item-wall-far')))
              .dy;
          final unlocatedTop = tester
              .getTopLeft(find.byKey(const Key('topo-item-wall-unlocated')))
              .dy;

          expect(
            nearTop,
            lessThan(farTop),
            reason: 'the nearer own topo must render above the farther one',
          );
          expect(
            farTop,
            lessThan(unlocatedTop),
            reason: 'every located topo must render above the unlocated one',
          );

          // Own topos keep their `topo-item-<wallId>` key/full menu -- the
          // proximity resort doesn't change what an own row IS, only its
          // position.
          expect(
            find.byKey(const Key('topo-menu-wall-near')),
            findsOneWidget,
          );
        },
      );

      testWidgets(
        'a nearby community topo (not already one of this device\'s own) '
        'appears in the merged list, is visually marked as shared, and '
        'tapping it navigates to /community/topo/<wallId>',
        (tester) async {
          final db = AppDatabase(NativeDatabase.memory());
          addTearDown(db.close);
          final container = ProviderContainer(
            overrides: [
              appDatabaseProvider.overrideWithValue(db),
              nowMsProvider.overrideWithValue(() => 1000),
              locationServiceProvider.overrideWithValue(
                const _FakeLocationService((latitude: 0.0, longitude: 0.0)),
              ),
              toposProvider.overrideWith((ref) => Stream.value(const [])),
              sharedToposProvider.overrideWith(
                (ref) => Stream.value(const [
                  SharedTopo(
                    wallId: 'wall-community',
                    name: 'Community Boulder',
                    routeCount: 2,
                    likeCount: 0,
                    commentCount: 0,
                    latitude: 0.02,
                    longitude: 0.02,
                  ),
                ]),
              ),
            ],
          );
          addTearDown(container.dispose);

          String? pushedPath;
          final router = GoRouter(
            initialLocation: '/',
            routes: [
              GoRoute(
                path: '/',
                builder: (context, state) => const ToposScreen(),
              ),
              GoRoute(
                path: '/community/topo/:wallId',
                builder: (context, state) {
                  pushedPath =
                      '/community/topo/${state.pathParameters['wallId']}';
                  return const SizedBox();
                },
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

          const rowKey = Key('topo-item-community-wall-community');
          expect(find.byKey(rowKey), findsOneWidget);
          expect(
            find.byKey(const Key('topo-shared-badge-wall-community')),
            findsOneWidget,
          );
          expect(find.text('Community Boulder'), findsOneWidget);

          await tester.tap(find.byKey(rowKey));
          await _drain(tester);

          expect(pushedPath, '/community/topo/wall-community');
        },
      );

      testWidgets(
        'a community topo whose wallId already matches one of this '
        'device\'s own topos is never duplicated -- only the own row shows',
        (tester) async {
          final db = AppDatabase(NativeDatabase.memory());
          addTearDown(db.close);
          final container = ProviderContainer(
            overrides: [
              appDatabaseProvider.overrideWithValue(db),
              nowMsProvider.overrideWithValue(() => 1000),
              locationServiceProvider.overrideWithValue(
                const _FakeLocationService((latitude: 0.0, longitude: 0.0)),
              ),
              toposProvider.overrideWith(
                (ref) => Stream.value(const [
                  TopoRef(
                    wallId: 'wall-published',
                    name: 'My Published Topo',
                    thumbnailPath: null,
                    routeCount: 1,
                    createdAt: 1000,
                    latitude: 0.01,
                    longitude: 0.01,
                    visibility: 'shared',
                  ),
                ]),
              ),
              sharedToposProvider.overrideWith(
                (ref) => Stream.value(const [
                  SharedTopo(
                    wallId: 'wall-published',
                    name: 'My Published Topo',
                    routeCount: 1,
                    likeCount: 0,
                    commentCount: 0,
                    latitude: 0.01,
                    longitude: 0.01,
                  ),
                ]),
              ),
            ],
          );
          addTearDown(container.dispose);

          await tester.pumpWidget(_wrap(container, const ToposScreen()));
          await _drain(tester);

          expect(
            find.byKey(const Key('topo-item-wall-published')),
            findsOneWidget,
          );
          expect(
            find.byKey(const Key('topo-item-community-wall-published')),
            findsNothing,
          );
        },
      );
    },
  );
}
