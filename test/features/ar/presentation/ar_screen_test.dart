import 'dart:async';
import 'dart:ui' as ui;

import 'package:masi/app/theme.dart';
import 'package:masi/core/db/app_database.dart';
import 'package:masi/core/db/database_provider.dart';
import 'package:masi/features/ar/application/ar_channel.dart';
import 'package:masi/features/ar/application/ar_controller.dart';
import 'package:masi/features/ar/application/manual_align_controller.dart';
import 'package:masi/features/ar/domain/homography.dart';
import 'package:masi/features/ar/presentation/ar_overlay_painter.dart';
import 'package:masi/features/ar/presentation/ar_screen.dart';
import 'package:masi/features/library/application/library_providers.dart';
import 'package:masi/features/topo/data/route_repository.dart';
import 'package:masi/features/topo/domain/topo_route.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

/// Stands in for the real `path_provider` platform channel plugin, which has
/// no mock/fake registered in this suite's plain `flutter test` host.
///
/// `PhotoRepository.loadOriginal` (via `PhotoFiles.resolvePhotoPath`, added
/// alongside the #17 relative-photo-path batch) awaits
/// `getApplicationDocumentsDirectory()` for every persisted photo whose
/// stored `localPath` is relative (the canonical form) — which every photo
/// `LibraryCrudRepository.attachPhotoToWall` creates now is, since the fake
/// `/tmp/...` path this suite's A1 test attaches never exists on disk (see
/// `PhotoFiles.importPhoto`'s doc), so it's stored as-is in relative form.
///
/// Left unmocked, that `getApplicationDocumentsDirectory()` call goes out
/// over the real (unregistered) `plugins.flutter.io/path_provider`
/// `MethodChannel`. A plain `test()` body rejects such a call promptly with
/// `MissingPluginException`, but the identical call made from inside a
/// mounted widget's async lifecycle (as `ArScreen._load` does here) never
/// settles under this binding's ordinary fake-clock `pump()` — so
/// `_loading` would stay `true` forever, its `CircularProgressIndicator`'s
/// indeterminate/repeating animation would keep scheduling frames, and
/// `pumpAndSettle` would time out (confirmed while diagnosing this suite's
/// A1 failure). Overriding `PathProviderPlatform.instance` with this fake
/// bypasses the platform channel entirely — `getApplicationDocumentsPath`
/// becomes a plain Dart `Future` that resolves on an ordinary microtask —
/// so `pump()`/`pumpAndSettle()` observe it settle normally, exactly like
/// every other provider override in this test file.
class _FakePathProviderPlatform extends PathProviderPlatform {
  @override
  Future<String?> getApplicationDocumentsPath() async =>
      '/tmp/ar_screen_test_docs';
}

/// Decodes a tiny 2x2 RGBA image, for tests that need a real (non-null)
/// `ui.Image` to pass as [ArAlignmentStage.outline]. Mirrors
/// `ar_overlay_painter_test.dart`'s `_createTinyImage`; must be run inside
/// `tester.runAsync` here since these callers are `testWidgets` (running
/// under a fake-async zone), unlike that file's plain `test()` callers.
Future<ui.Image> _decode2x2() {
  final completer = Completer<ui.Image>();
  final pixels = Uint8List.fromList(<int>[
    255, 0, 0, 255, //
    0, 255, 0, 255, //
    0, 0, 255, 255, //
    255, 255, 0, 255, //
  ]);
  ui.decodeImageFromPixels(
    pixels,
    2,
    2,
    ui.PixelFormat.rgba8888,
    completer.complete,
  );
  return completer.future;
}

/// Covers the v2-ar-viewer AR screen contract:
///  - A1: on a non-iOS platform (the host `flutter test` always runs on —
///    `Platform.isIOS` reflects the ACTUAL test host, never the widget
///    under test, so this is inherent, not simulated), `ArScreen` renders
///    the unsupported placeholder, never a `UiKitView`, and never crashes —
///    even when the wall genuinely has a photo + routes persisted.
///  - A2/A3: [ArAlignmentStage] — the platform-agnostic widget `ArScreen`'s
///    iOS branch wraps around a real `UiKitView` — is pumped DIRECTLY here
///    with a plain placeholder `Widget` standing in for the camera surface
///    (see `ArScreen`'s class doc for why this is the documented seam:
///    `ArAlignmentStage` itself has no platform checks, so any harness can
///    exercise its overlay/toggle/gesture logic without ever touching
///    `UiKitView`). This drives the REAL `ArOverlayPainter` /
///    `ArController` / `ManualAlignController` wiring.
/// Decodes a tiny 1x1 RGBA image, standing in for a decoded rock mask in the
/// "highlight rock" toggle tests below.
Future<ui.Image> _createTinyImage() {
  final completer = Completer<ui.Image>();
  ui.decodeImageFromPixels(
    Uint8List.fromList(<int>[0, 229, 255, 255]),
    1,
    1,
    ui.PixelFormat.rgba8888,
    completer.complete,
  );
  return completer.future;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // ArController.setMode fires a real (fire-and-forget) MethodChannel call
  // on 'masi/ar' — mocked here (mirroring
  // test/features/ar/application/ar_controller_test.dart) so the
  // ArAlignmentStage group's mode-toggle interactions never hit an
  // unhandled MissingPluginException from the unregistered real channel.
  const arMethodChannel = MethodChannel('masi/ar');

  /// Records every `masi/ar` method call made during a test — used by
  /// the Re-scan control tests below to assert `rescan` was invoked (with no
  /// args) without needing a dedicated mock per test.
  ///
  /// `lockManual` defaults to returning `true` (a successful native pin) so
  /// every existing lock-flips-to-true test keeps passing without each one
  /// having to configure its own handler; the "native declines to lock"
  /// tests below override this per-test via a fresh
  /// `setMockMethodCallHandler` call.
  final List<MethodCall> arCalls = <MethodCall>[];

  // Swapped in for every test in this file (see _FakePathProviderPlatform's
  // doc) — harmless for every test besides A1/A1b/Fix 1 (the only ones that
  // mount a real ArScreen), since it's simply never consulted otherwise.
  final originalPathProviderPlatform = PathProviderPlatform.instance;
  setUp(() {
    arCalls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(arMethodChannel, (call) async {
          arCalls.add(call);
          if (call.method == 'lockManual') return true;
          return null;
        });
    PathProviderPlatform.instance = _FakePathProviderPlatform();
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(arMethodChannel, null);
    PathProviderPlatform.instance = originalPathProviderPlatform;
  });

  group('ArScreen', () {
    testWidgets(
      'A1: with a photo + route persisted for the wall, the screen still '
      'renders the iOS-only placeholder (no UiKitView, no crash) on this '
      'non-iOS test host',
      (tester) async {
        final db = AppDatabase(NativeDatabase.memory());
        addTearDown(db.close);
        final container = ProviderContainer(
          overrides: [
            appDatabaseProvider.overrideWithValue(db),
            nowMsProvider.overrideWithValue(() => 1000),
          ],
        );
        addTearDown(container.dispose);

        final crud = container.read(libraryCrudRepositoryProvider);
        final area = await crud.createArea('Area');
        final sector = await crud.createSector(area.id, 'Sector');
        final wall = await crud.createWall(sector.id, 'Wall');
        late String photoId;
        await tester.runAsync(() async {
          photoId = await crud.attachPhotoToWall(
            wall.id,
            XFile('/tmp/wall-photo.jpg'),
            1000,
            2000,
          );
          final routeRepo = RouteRepository(db, nowMs: () => 1000);
          await routeRepo.upsertRoute(
            wall.id,
            photoId,
            const TopoRoute(
              id: 1,
              number: 1,
              points: [Offset(0.1, 0.1), Offset(0.2, 0.2)],
            ),
          );
        });

        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(theme: MasiTheme.light, home: ArScreen(wallId: wall.id)),
          ),
        );
        await tester.pumpAndSettle();

        expect(
          find.byKey(const Key('ar-unsupported-placeholder')),
          findsOneWidget,
        );
        expect(find.byType(UiKitView), findsNothing);
        expect(find.text('AR live view is iOS-only'), findsOneWidget);
      },
    );

    testWidgets(
      'Fix 1: entering AR for a different wall resets arControllerProvider '
      'back to the auto (ARKit-tracking) default, manualAlignProvider back '
      'to identity, and arLockedProvider back to unlocked, even though all '
      'three are app-lifetime singletons never scoped to a wall',
      (tester) async {
        final db = AppDatabase(NativeDatabase.memory());
        addTearDown(db.close);
        final container = ProviderContainer(
          overrides: [
            appDatabaseProvider.overrideWithValue(db),
            nowMsProvider.overrideWithValue(() => 1000),
          ],
        );
        addTearDown(container.dispose);

        final crud = container.read(libraryCrudRepositoryProvider);
        final area = await crud.createArea('Area');
        final sector = await crud.createSector(area.id, 'Sector');
        final wallA = await crud.createWall(sector.id, 'Wall A');
        final wallB = await crud.createWall(sector.id, 'Wall B');

        // Enter AR for wall A. Neither wall has a photo/route persisted —
        // the reset must fire regardless, since it happens before the
        // photo-and-visible-route session-start gate is even checked.
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(theme: MasiTheme.light, home: ArScreen(wallId: wallA.id)),
          ),
        );
        await tester.pumpAndSettle();

        // Every AR entry now defaults to auto (ARKit tracking is the
        // primary alignment mode).
        expect(container.read(arControllerProvider).mode, ArMode.auto);
        expect(container.read(arLockedProvider), isFalse);

        // Simulate the user having switched to manual (e.g. ARKit tracking
        // never locked on) and hand-adjusted/locked the overlay, as if this
        // were a real wall-A AR session.
        container.read(arControllerProvider.notifier).setMode(ArMode.manual);
        container.read(manualAlignProvider.notifier).pan(const Offset(9, 9));
        container.read(arLockedProvider.notifier).toggle();
        expect(container.read(arControllerProvider).mode, ArMode.manual);
        expect(
          container.read(manualAlignProvider),
          isNot(Homography.identity()),
        );
        expect(container.read(arLockedProvider), isTrue);

        // "Back out": unmount wall A's ArScreen entirely — mirroring what a
        // real Navigator.pop does (destroys the whole route's widget
        // subtree) — before mounting wall B's. Skipping this step and
        // pumping wall B's ArScreen directly in wall A's place would NOT
        // reproduce a real "different wall" AR entry: with no Key, an
        // unchanged widget type at the same tree slot makes Flutter reuse
        // the EXISTING State (only `didUpdateWidget` fires, never
        // `initState`), so `_load`/`_resetArViewState` would never re-run —
        // unlike real navigation, where `context.push` always mounts a
        // brand-new widget subtree (and thus a brand-new `_ArScreenState`)
        // for the new route.
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();

        // Enter AR for a DIFFERENT wall: a genuinely fresh ArScreen widget
        // (a new wallId means a new route/widget in the real app), but the
        // SAME app-lifetime arControllerProvider/manualAlignProvider/
        // arLockedProvider.
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(theme: MasiTheme.light, home: ArScreen(wallId: wallB.id)),
          ),
        );
        await tester.pumpAndSettle();

        expect(
          container.read(arControllerProvider).mode,
          ArMode.auto,
          reason:
              "wall B's AR entry must land on the auto default, same as "
              "wall A's did — even though wall A's session had switched to "
              'manual and locked before backing out',
        );
        expect(
          container.read(manualAlignProvider),
          Homography.identity(),
          reason:
              "wall B's AR entry must not inherit wall A's leftover "
              'hand-adjusted homography',
        );
        expect(
          container.read(arLockedProvider),
          isFalse,
          reason: "wall B's AR entry must not inherit wall A's lock",
        );
      },
    );

    testWidgets(
      'B3: entering AR for a different wall resets arControllerProvider.'
      "rockQuadPercent back to null, so a prior session's native rock/crop "
      'quad can never leak into a new session that returns none',
      (tester) async {
        final db = AppDatabase(NativeDatabase.memory());
        addTearDown(db.close);
        final container = ProviderContainer(
          overrides: [
            appDatabaseProvider.overrideWithValue(db),
            nowMsProvider.overrideWithValue(() => 1000),
          ],
        );
        addTearDown(container.dispose);

        final crud = container.read(libraryCrudRepositoryProvider);
        final area = await crud.createArea('Area');
        final sector = await crud.createSector(area.id, 'Sector');
        final wallA = await crud.createWall(sector.id, 'Wall A');
        final wallB = await crud.createWall(sector.id, 'Wall B');

        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(theme: MasiTheme.light, home: ArScreen(wallId: wallA.id)),
          ),
        );
        await tester.pumpAndSettle();

        // Simulate a leftover rockQuadPercent from wall A's session, as if a
        // real channel.start had returned a confident native segmentation.
        container
            .read(arControllerProvider.notifier)
            .setRockSegmentation(quadPercent: const <Offset>[
              Offset(0.1, 0.1),
              Offset(0.9, 0.1),
              Offset(0.9, 0.9),
              Offset(0.1, 0.9),
            ]);
        expect(container.read(arControllerProvider).rockQuadPercent, isNotNull);

        // Back out and enter AR for a DIFFERENT wall — same real-navigation
        // mirroring as Fix 1 above (a brand-new ArScreen widget subtree, not
        // an in-place rebuild).
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();

        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(theme: MasiTheme.light, home: ArScreen(wallId: wallB.id)),
          ),
        );
        await tester.pumpAndSettle();

        expect(
          container.read(arControllerProvider).rockQuadPercent,
          isNull,
          reason:
              "wall B's AR entry must not inherit wall A's leftover "
              'rockQuadPercent',
        );
      },
    );

    group(
      'B4: EXIF parity -- refSize is exactly PhotoRef.width/height, never '
      'a second re-decode',
      () {
        // No EXIF-rotated JPEG fixture exists in this repo's test assets, so
        // this proves the narrower but load-bearing invariant instead (per
        // the B4 spec's documented fallback): AR's refSize NEVER comes from
        // a second, independent dimension decode -- it is always exactly
        // the PhotoRef.width/PhotoRef.height already persisted for this
        // photo. Those persisted dims themselves come from
        // `image_dimensions_native.dart`'s `decodeImageSize` (`dart:ui`'s
        // `instantiateImageCodec` on the picked file's raw bytes -- see
        // `topos_screen.dart`'s `_handleNewTopo`), which honors EXIF
        // orientation -- so PhotoRef.width/height are already the
        // EXIF-ORIENTED dims by the time AR ever sees them. A
        // rockQuadPercent fraction (documented in `ar_channel.dart` as "0..1
        // of the ORIENTED full reference photo") is only meaningful if
        // native's segmentation and Dart's refSize agree on what "oriented"
        // means -- this test guards that agreement holds all the way
        // through ArScreen -> ArAlignmentStage, using deliberately
        // non-square width/height (1000x2000) so a width/height swap bug
        // would be caught.
        testWidgets(
          'ArScreen constructs ArAlignmentStage.refSize as exactly '
          "Size(photo.width, photo.height) -- the same oriented dims "
          "PhotoRepository.loadOriginal reports, not an independently "
          're-decoded size',
          (tester) async {
            final db = AppDatabase(NativeDatabase.memory());
            addTearDown(db.close);
            final container = ProviderContainer(
              overrides: [
                appDatabaseProvider.overrideWithValue(db),
                nowMsProvider.overrideWithValue(() => 1000),
                arSupportedProvider.overrideWithValue(true),
                arAutoTrackingProvider.overrideWithValue(false),
                // Same self-consistency hardening as ar_web_manual_test
                // .dart's C4/remount groups: arSupported:true can drive a
                // real _resetArViewState -> ArController.setMode ->
                // arChannelProvider.setMode call; noop keeps that harmless
                // on this test host with no masi/ar mock registered.
                arChannelProvider.overrideWithValue(ArChannel.noop()),
              ],
            );
            addTearDown(container.dispose);

            final crud = container.read(libraryCrudRepositoryProvider);
            final area = await crud.createArea('Area');
            final sector = await crud.createSector(area.id, 'Sector');
            final wall = await crud.createWall(sector.id, 'Wall');
            late String photoId;
            await tester.runAsync(() async {
              photoId = await crud.attachPhotoToWall(
                wall.id,
                XFile('/tmp/exif-parity-test-photo.jpg'),
                1000,
                2000,
              );
              final routeRepo = RouteRepository(db, nowMs: () => 1000);
              await routeRepo.upsertRoute(
                wall.id,
                photoId,
                const TopoRoute(
                  id: 1,
                  number: 1,
                  points: [Offset(0.1, 0.1), Offset(0.2, 0.2)],
                ),
              );
            });

            final photo = await container
                .read(photoRepositoryProvider)
                .loadOriginal(wall.id);
            expect(photo, isNotNull);
            expect(
              photo!.width,
              1000,
              reason:
                  'PhotoRef.width must be exactly what was decoded/'
                  'persisted at attach time',
            );
            expect(photo.height, 2000);

            await tester.pumpWidget(
              UncontrolledProviderScope(
                container: container,
                child: MaterialApp(
                  theme: MasiTheme.light,
                  home: ArScreen(wallId: wall.id),
                ),
              ),
            );
            await tester.pumpAndSettle();

            final stage = tester.widget<ArAlignmentStage>(
              find.byType(ArAlignmentStage),
            );
            expect(
              stage.refSize,
              Size(photo.width.toDouble(), photo.height.toDouble()),
              reason:
                  "ArAlignmentStage's refSize -- the scale base every "
                  "rockQuadPercent fraction is multiplied against (see "
                  "ar_screen.dart's ArAlignmentStage.build) -- must be "
                  "exactly PhotoRef's own oriented width/height, never a "
                  'second re-decoded size that could disagree with what '
                  'native used to compute rockQuadPercent in the first '
                  'place',
            );
          },
        );
      },
    );

    testWidgets(
      'A1b: with no photo/routes at all, the screen still renders the '
      'iOS-only placeholder (platform gate wins regardless of data) — no '
      'crash',
      (tester) async {
        final db = AppDatabase(NativeDatabase.memory());
        addTearDown(db.close);
        final container = ProviderContainer(
          overrides: [
            appDatabaseProvider.overrideWithValue(db),
            nowMsProvider.overrideWithValue(() => 1000),
          ],
        );
        addTearDown(container.dispose);

        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              theme: MasiTheme.light,
              home: const ArScreen(wallId: 'no-such-wall'),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(
          find.byKey(const Key('ar-unsupported-placeholder')),
          findsOneWidget,
        );
        expect(find.byType(UiKitView), findsNothing);
      },
    );
  });

  group('ArAlignmentStage (platform-agnostic overlay/toggle/gesture core)', () {
    const refSize = Size(1000, 2000);
    // A fixed-size view so the composite fit/fill homography is
    // deterministic: fitInto(refSize=1000x2000, viewSize=400x800) scales by
    // exactly 0.4 (both axes hit their limit at once, no letterboxing), so
    // the route-space center (0.5, 0.5) always lands exactly on the view
    // center (200, 400).
    const viewSize = Size(400, 800);
    const route = TopoRoute(
      id: 1,
      number: 1,
      points: [Offset(0.1, 0.1), Offset(0.2, 0.2)],
    );

    /// `active: true` by default: every test in this group besides the
    /// dedicated gating tests below (#7) is exercising steady-state
    /// mode-toggle/gesture/lock behavior on a session that has already
    /// started natively — mirroring `ArState.active` flipping true once
    /// `ArScreen._startSession`'s `channel.start` call has actually
    /// succeeded. Pass `active: false` to instead exercise the pre-start
    /// disabled-controls gate itself.
    Widget buildStage(
      ProviderContainer container, {
      ui.Image? outline,
      bool active = true,
      String? startError,
      VoidCallback? onRetryStart,
    }) {
      if (active) {
        container.read(arControllerProvider.notifier).markActive(true);
      }
      return UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: MasiTheme.light,
          home: Scaffold(
            body: SizedBox(
              width: viewSize.width,
              height: viewSize.height,
              child: ArAlignmentStage(
                // Stand-in for the native camera surface — ArAlignmentStage
                // never inspects this widget, so a plain Container exercises
                // exactly the same overlay/toggle/gesture code path a real
                // UiKitView would sit underneath on-device.
                cameraView: Container(key: const Key('fake-camera-view')),
                routes: [route],
                refSize: refSize,
                outline: outline,
                startError: startError,
                onRetryStart: onRetryStart,
              ),
            ),
          ),
        ),
      );
    }

    /// Pins the test surface's logical size to exactly `viewSize` (400x800)
    /// so the `SizedBox(width: viewSize.width, height: viewSize.height)` in
    /// `buildStage` is never clamped by the platform's real screen bounds.
    /// Flutter's default test surface is 800x600 logical px, which would
    /// otherwise cap the 800-tall SizedBox at 600 before it ever reaches
    /// `ArAlignmentStage`'s `LayoutBuilder`, silently breaking the
    /// `fitInto(refSize, viewSize)` math this whole group's expected
    /// coordinates are built on. Mirrors the golden-test viewport pin in
    /// ar_overlay_painter_test.dart.
    void pinViewSize(WidgetTester tester) {
      tester.view.physicalSize = viewSize;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
    }

    ArOverlayPainter currentPainter(WidgetTester tester) {
      final customPaint = tester.widget<CustomPaint>(
        find.byWidgetPredicate(
          (w) => w is CustomPaint && w.painter is ArOverlayPainter,
        ),
      );
      return customPaint.painter as ArOverlayPainter;
    }

    /// Warps the route-space center point (0.5, 0.5) through the currently
    /// mounted painter's homography — the on-screen point the middle of the
    /// route geometry actually renders at.
    Offset warpedCenter(WidgetTester tester) {
      return currentPainter(
        tester,
      ).homography.warpOriginalPercent(const Offset(0.5, 0.5), refSize);
    }

    testWidgets(
      'MANUAL with no gesture yet: the composite homography is the fitted '
      'placement (route center lands on the view center) — manual mode '
      'starts fitted+draggable, not off-screen at raw identity',
      (tester) async {
        pinViewSize(tester);
        final container = ProviderContainer();
        addTearDown(container.dispose);
        container.read(arControllerProvider.notifier).setMode(ArMode.manual);

        await tester.pumpWidget(buildStage(container));
        await tester.pump();

        final center = warpedCenter(tester);
        expect(center.dx, closeTo(200, 1e-6));
        expect(center.dy, closeTo(400, 1e-6));
      },
    );

    testWidgets(
      'MANUAL after a pan drag: the warped route center moves by roughly '
      'the drag delta on top of the fitted placement, staying on screen',
      (tester) async {
        pinViewSize(tester);
        final container = ProviderContainer();
        addTearDown(container.dispose);
        container.read(arControllerProvider.notifier).setMode(ArMode.manual);

        await tester.pumpWidget(buildStage(container));
        await tester.pump();

        await tester.drag(
          find.byKey(const Key('ar-manual-gesture-layer')),
          const Offset(30, -20),
        );
        await tester.pump();

        final center = warpedCenter(tester);
        expect(center.dx, closeTo(230, 1e-6));
        expect(center.dy, closeTo(380, 1e-6));
        expect(center.dx, inInclusiveRange(0, viewSize.width));
        expect(center.dy, inInclusiveRange(0, viewSize.height));
      },
    );

    testWidgets(
      'AUTO with no alignment pushed yet: the composite falls back to the '
      'fitted ghost overlay (route center on the view center), confidence 0',
      (tester) async {
        pinViewSize(tester);
        final container = ProviderContainer();
        addTearDown(container.dispose);

        await tester.pumpWidget(buildStage(container));
        await tester.pump();

        expect(
          container.read(arControllerProvider).mode,
          ArMode.auto,
          reason: 'ArController starts in auto mode',
        );

        final center = warpedCenter(tester);
        expect(center.dx, closeTo(200, 1e-6));
        expect(center.dy, closeTo(400, 1e-6));
        expect(currentPainter(tester).confidence, 0.0);
      },
    );

    testWidgets('AUTO with a latest alignment reporting tracking:true + '
        'screenCorners: the composite is fromQuad(refSize corners, '
        'screenCorners) — mapping the reference photo directly onto the '
        'ARKit-reported screen corners — not the fitted-ghost fallback, '
        'confidence 1.0, outline hidden', (tester) async {
      pinViewSize(tester);
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final image = (await tester.runAsync(_decode2x2))!;

      await tester.pumpWidget(buildStage(container, outline: image));
      await tester.pump();

      const corners = [
        Offset(50, 50),
        Offset(350, 50),
        Offset(350, 750),
        Offset(50, 750),
      ];
      container
          .read(arControllerProvider.notifier)
          .onAlignment(
            ArAlignment(
              confidence: 0.0,
              tracking: true,
              screenCorners: corners,
            ),
          );
      await tester.pump();

      final expected = Homography.fromQuad([
        Offset.zero,
        Offset(refSize.width, 0),
        Offset(refSize.width, refSize.height),
        Offset(0, refSize.height),
      ], corners);

      expect(currentPainter(tester).homography, expected);
      expect(currentPainter(tester).confidence, 1.0);
      expect(currentPainter(tester).outline, isNull);

      // The reference photo's corners land on (approximately) the
      // ARKit-reported screen corners.
      final topLeft = expected.warp(Offset.zero);
      expect(topLeft.dx, closeTo(50, 1e-6));
      expect(topLeft.dy, closeTo(50, 1e-6));
      final bottomRight = expected.warp(Offset(refSize.width, refSize.height));
      expect(bottomRight.dx, closeTo(350, 1e-6));
      expect(bottomRight.dy, closeTo(750, 1e-6));
    });

    group('B2: rockQuadPercent as the fromQuad SOURCE quad', () {
      const corners = <Offset>[
        Offset(50, 50),
        Offset(350, 50),
        Offset(350, 750),
        Offset(50, 750),
      ];
      const rockQuadPercent = <Offset>[
        Offset(0.1, 0.1),
        Offset(0.9, 0.1),
        Offset(0.9, 0.9),
        Offset(0.1, 0.9),
      ];

      testWidgets(
        'AUTO + tracking with arState.rockQuadPercent set: the SOURCE quad '
        'is rockQuadPercent scaled by refSize, not the full-photo rect -- '
        'the rendered homography differs from the full-photo-src case',
        (tester) async {
          pinViewSize(tester);
          final container = ProviderContainer();
          addTearDown(container.dispose);
          container
              .read(arControllerProvider.notifier)
              .setRockSegmentation(quadPercent: rockQuadPercent);

          await tester.pumpWidget(buildStage(container));
          await tester.pump();

          container
              .read(arControllerProvider.notifier)
              .onAlignment(
                const ArAlignment(
                  confidence: 0.0,
                  tracking: true,
                  screenCorners: corners,
                ),
              );
          await tester.pump();

          final expectedRefCorners = [
            for (final p in rockQuadPercent)
              Offset(p.dx * refSize.width, p.dy * refSize.height),
          ];
          final expected = Homography.fromQuad(expectedRefCorners, corners);
          final fullPhotoHomography = Homography.fromQuad([
            Offset.zero,
            Offset(refSize.width, 0),
            Offset(refSize.width, refSize.height),
            Offset(0, refSize.height),
          ], corners);

          expect(currentPainter(tester).homography, expected);
          expect(
            currentPainter(tester).homography,
            isNot(fullPhotoHomography),
            reason:
                'a rockQuadPercent-scoped source quad must produce a '
                'different homography from the full-photo-rect source quad',
          );
        },
      );

      testWidgets(
        'AUTO + tracking with arState.rockQuadPercent null (the default): '
        'the SOURCE quad is the unchanged full-photo rect -- identical to '
        'current (pre-rockQuad) behavior',
        (tester) async {
          pinViewSize(tester);
          final container = ProviderContainer();
          addTearDown(container.dispose);
          expect(
            container.read(arControllerProvider).rockQuadPercent,
            isNull,
          );

          await tester.pumpWidget(buildStage(container));
          await tester.pump();

          container
              .read(arControllerProvider.notifier)
              .onAlignment(
                const ArAlignment(
                  confidence: 0.0,
                  tracking: true,
                  screenCorners: corners,
                ),
              );
          await tester.pump();

          final expected = Homography.fromQuad([
            Offset.zero,
            Offset(refSize.width, 0),
            Offset(refSize.width, refSize.height),
            Offset(0, refSize.height),
          ], corners);

          expect(currentPainter(tester).homography, expected);
        },
      );
    });

    group('rock-highlight toggle gates the painter\'s rockMask', () {
      testWidgets(
        'with a mask set on the controller but the highlight OFF (default), '
        'the painter receives rockMask: null; toggling the highlight ON '
        'passes the mask through, and toggling OFF again clears it',
        (tester) async {
          pinViewSize(tester);
          // Decode via runAsync: `decodeImageFromPixels` is real
          // (non-fake-async) engine work that never completes under
          // testWidgets' fake clock — the same reason every other
          // ui.Image-decoding test in this suite lives in a plain `test()`.
          final mask = (await tester.runAsync(_createTinyImage))!;
          addTearDown(mask.dispose);
          final container = ProviderContainer();
          addTearDown(container.dispose);
          container
              .read(arControllerProvider.notifier)
              .setRockSegmentation(mask: mask);

          await tester.pumpWidget(buildStage(container));
          await tester.pump();

          expect(
            container.read(arRockHighlightProvider),
            isFalse,
            reason: 'sanity: highlight defaults off',
          );
          expect(
            currentPainter(tester).rockMask,
            isNull,
            reason:
                'a mask is present on the controller, but with the highlight '
                'toggle off the painter must receive null (no silhouette)',
          );

          container.read(arRockHighlightProvider.notifier).toggle();
          await tester.pump();

          expect(
            currentPainter(tester).rockMask,
            same(mask),
            reason:
                'with the highlight on, the painter must receive the '
                "controller's rockMask",
          );

          container.read(arRockHighlightProvider.notifier).toggle();
          await tester.pump();

          expect(
            currentPainter(tester).rockMask,
            isNull,
            reason: 'toggling the highlight back off must clear the mask again',
          );
        },
      );

      testWidgets(
        'with the highlight ON but NO mask on the controller, the painter '
        'still receives null (nothing to highlight)',
        (tester) async {
          pinViewSize(tester);
          final container = ProviderContainer();
          addTearDown(container.dispose);
          container.read(arRockHighlightProvider.notifier).toggle();

          await tester.pumpWidget(buildStage(container));
          await tester.pump();

          expect(container.read(arRockHighlightProvider), isTrue);
          expect(currentPainter(tester).rockMask, isNull);
        },
      );

      testWidgets(
        'tapping the ar-highlight-rock-toggle FAB flips '
        'arRockHighlightProvider',
        (tester) async {
          pinViewSize(tester);
          final container = ProviderContainer();
          addTearDown(container.dispose);

          await tester.pumpWidget(buildStage(container));
          await tester.pump();

          expect(
            find.byKey(const Key('ar-highlight-rock-toggle')),
            findsOneWidget,
          );
          expect(container.read(arRockHighlightProvider), isFalse);

          await tester.tap(find.byKey(const Key('ar-highlight-rock-toggle')));
          await tester.pump();

          expect(container.read(arRockHighlightProvider), isTrue);
        },
      );
    });

    testWidgets(
      'AUTO with a latest alignment reporting tracking:false (even with '
      'screenCorners present): falls back to the fitted ghost overlay, not '
      'fromQuad — confidence 0',
      (tester) async {
        pinViewSize(tester);
        final container = ProviderContainer();
        addTearDown(container.dispose);

        await tester.pumpWidget(buildStage(container));
        await tester.pump();

        container
            .read(arControllerProvider.notifier)
            .onAlignment(
              ArAlignment(
                confidence: 0.0,
                tracking: false,
                screenCorners: [
                  Offset(50, 50),
                  Offset(350, 50),
                  Offset(350, 750),
                  Offset(50, 750),
                ],
              ),
            );
        await tester.pump();

        final center = warpedCenter(tester);
        expect(center.dx, closeTo(200, 1e-6));
        expect(center.dy, closeTo(400, 1e-6));
        expect(currentPainter(tester).confidence, 0.0);
      },
    );

    testWidgets(
      'the reset button (manual mode only) restores the composite back to '
      'the fitted placement (route center on the view center)',
      (tester) async {
        pinViewSize(tester);
        final container = ProviderContainer();
        addTearDown(container.dispose);
        container.read(arControllerProvider.notifier).setMode(ArMode.manual);
        container.read(manualAlignProvider.notifier).pan(const Offset(9, 9));

        await tester.pumpWidget(buildStage(container));
        await tester.pump();

        expect(
          container.read(manualAlignProvider),
          isNot(Homography.identity()),
        );
        expect(find.byKey(const Key('ar-reset')), findsOneWidget);

        await tester.tap(find.byKey(const Key('ar-reset')));
        await tester.pump();

        expect(container.read(manualAlignProvider), Homography.identity());

        final center = warpedCenter(tester);
        expect(center.dx, closeTo(200, 1e-6));
        expect(center.dy, closeTo(400, 1e-6));
      },
    );

    testWidgets(
      'discoverability: AUTO shows an "Auto" label with a "Point at the '
      'wall" hint; MANUAL (unlocked) shows a "Manual" label with a "Line up '
      'the outline" hint',
      (tester) async {
        final container = ProviderContainer();
        addTearDown(container.dispose);

        await tester.pumpWidget(buildStage(container));
        await tester.pump();

        expect(find.text('Auto'), findsOneWidget);
        expect(
          tester.widget<Text>(find.byKey(const Key('ar-hint'))).data,
          contains('Point at the wall'),
        );

        await tester.tap(find.byKey(const Key('ar-mode-toggle')));
        await tester.pump();

        expect(find.text('Manual'), findsOneWidget);
        expect(
          tester.widget<Text>(find.byKey(const Key('ar-hint'))).data,
          contains('Line up the outline'),
        );
      },
    );

    testWidgets(
      'the mode-toggle FAB shows the CURRENT mode as a letter: "A" in auto, '
      '"M" in manual',
      (tester) async {
        final container = ProviderContainer();
        addTearDown(container.dispose);

        await tester.pumpWidget(buildStage(container));
        await tester.pump();

        expect(
          find.descendant(
            of: find.byKey(const Key('ar-mode-toggle')),
            matching: find.text('A'),
          ),
          findsOneWidget,
        );

        await tester.tap(find.byKey(const Key('ar-mode-toggle')));
        await tester.pump();

        expect(
          find.descendant(
            of: find.byKey(const Key('ar-mode-toggle')),
            matching: find.text('M'),
          ),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'discoverability: AUTO + tracking:true shows a "Tracking" label with a '
      '"Routes locked to the wall" hint',
      (tester) async {
        final container = ProviderContainer();
        addTearDown(container.dispose);

        await tester.pumpWidget(buildStage(container));
        await tester.pump();

        container
            .read(arControllerProvider.notifier)
            .onAlignment(
              ArAlignment(
                confidence: 0.0,
                tracking: true,
                screenCorners: [
                  Offset(50, 50),
                  Offset(350, 50),
                  Offset(350, 750),
                  Offset(50, 750),
                ],
              ),
            );
        await tester.pump();

        expect(find.text('Tracking'), findsOneWidget);
        expect(
          tester.widget<Text>(find.byKey(const Key('ar-hint'))).data,
          contains('locked to the wall'),
        );
      },
    );

    testWidgets(
      'discoverability: once locked (not yet tracking), the status label '
      'reads "Locked" with a "Move slowly to find the wall" hint',
      (tester) async {
        final container = ProviderContainer();
        addTearDown(container.dispose);
        container.read(arControllerProvider.notifier).setMode(ArMode.manual);

        await tester.pumpWidget(buildStage(container));
        await tester.pump();

        await tester.tap(find.byKey(const Key('ar-lock')));
        await tester.pumpAndSettle();

        expect(find.text('Locked'), findsOneWidget);
        expect(
          tester.widget<Text>(find.byKey(const Key('ar-hint'))).data,
          contains('Move slowly to find the wall'),
        );
      },
    );

    testWidgets(
      'discoverability: once locked AND tracking, the status label reads '
      '"Locked" with a "Routes anchored to the wall" hint',
      (tester) async {
        final container = ProviderContainer();
        addTearDown(container.dispose);
        container.read(arControllerProvider.notifier).setMode(ArMode.manual);

        await tester.pumpWidget(buildStage(container));
        await tester.pump();

        await tester.tap(find.byKey(const Key('ar-lock')));
        await tester.pumpAndSettle();

        container
            .read(arControllerProvider.notifier)
            .onAlignment(
              ArAlignment(
                confidence: 0.0,
                tracking: true,
                screenCorners: const [
                  Offset(50, 50),
                  Offset(350, 50),
                  Offset(350, 750),
                  Offset(50, 750),
                ],
              ),
            );
        await tester.pump();

        expect(find.text('Locked'), findsOneWidget);
        expect(
          tester.widget<Text>(find.byKey(const Key('ar-hint'))).data,
          contains('Routes anchored to the wall'),
        );
      },
    );

    group('outline-guided alignment + Lock', () {
      testWidgets(
        'MANUAL + unlocked + an outline image supplied: the painter receives '
        'that exact image as its outline',
        (tester) async {
          pinViewSize(tester);
          final container = ProviderContainer();
          addTearDown(container.dispose);
          container.read(arControllerProvider.notifier).setMode(ArMode.manual);
          final image = (await tester.runAsync(_decode2x2))!;

          await tester.pumpWidget(buildStage(container, outline: image));
          await tester.pump();

          expect(currentPainter(tester).outline, same(image));
          expect(container.read(arLockedProvider), isFalse);
        },
      );

      testWidgets(
        'AUTO mode: the painter outline is null even when an outline image '
        'is supplied — the guide is manual-only',
        (tester) async {
          pinViewSize(tester);
          final container = ProviderContainer();
          addTearDown(container.dispose);
          final image = (await tester.runAsync(_decode2x2))!;

          await tester.pumpWidget(buildStage(container, outline: image));
          await tester.pump();

          expect(
            container.read(arControllerProvider).mode,
            ArMode.auto,
            reason: 'ArController starts in auto mode',
          );
          expect(currentPainter(tester).outline, isNull);
        },
      );

      testWidgets(
        'tapping ar-lock: locks the alignment, hides the outline guide, and '
        'removes the manual gesture layer (routes render frozen)',
        (tester) async {
          pinViewSize(tester);
          final container = ProviderContainer();
          addTearDown(container.dispose);
          container.read(arControllerProvider.notifier).setMode(ArMode.manual);
          final image = (await tester.runAsync(_decode2x2))!;

          await tester.pumpWidget(buildStage(container, outline: image));
          await tester.pump();

          expect(currentPainter(tester).outline, same(image));
          expect(
            find.byKey(const Key('ar-manual-gesture-layer')),
            findsOneWidget,
          );

          await tester.tap(find.byKey(const Key('ar-lock')));
          await tester.pumpAndSettle();

          expect(container.read(arLockedProvider), isTrue);
          expect(currentPainter(tester).outline, isNull);
          expect(
            find.byKey(const Key('ar-manual-gesture-layer')),
            findsNothing,
          );
          expect(
            tester.widget<Text>(find.byKey(const Key('ar-hint'))).data,
            contains('Move slowly to find the wall'),
          );
        },
      );

      testWidgets('tapping ar-lock a second time: unlocks again, restoring the '
          'outline guide and the manual gesture layer', (tester) async {
        pinViewSize(tester);
        final container = ProviderContainer();
        addTearDown(container.dispose);
        container.read(arControllerProvider.notifier).setMode(ArMode.manual);
        final image = (await tester.runAsync(_decode2x2))!;

        await tester.pumpWidget(buildStage(container, outline: image));
        await tester.pump();

        await tester.tap(find.byKey(const Key('ar-lock')));
        await tester.pumpAndSettle();
        expect(container.read(arLockedProvider), isTrue);

        await tester.tap(find.byKey(const Key('ar-lock')));
        await tester.pump();

        expect(container.read(arLockedProvider), isFalse);
        expect(currentPainter(tester).outline, same(image));
        expect(
          find.byKey(const Key('ar-manual-gesture-layer')),
          findsOneWidget,
        );
      });

      testWidgets(
        'while locked, the reset FAB is hidden but the lock FAB (as an '
        'unlock control) remains',
        (tester) async {
          pinViewSize(tester);
          final container = ProviderContainer();
          addTearDown(container.dispose);
          container.read(arControllerProvider.notifier).setMode(ArMode.manual);

          await tester.pumpWidget(buildStage(container));
          await tester.pump();
          expect(find.byKey(const Key('ar-reset')), findsOneWidget);
          expect(find.byKey(const Key('ar-lock')), findsOneWidget);

          await tester.tap(find.byKey(const Key('ar-lock')));
          await tester.pumpAndSettle();

          expect(find.byKey(const Key('ar-reset')), findsNothing);
          expect(find.byKey(const Key('ar-lock')), findsOneWidget);
        },
      );
    });

    group('manual lock <-> native wiring', () {
      testWidgets(
        'in unlocked manual mode, tapping ar-lock records exactly one '
        'lockManual call whose 8 corner doubles equal fit.warp(refCorners), '
        'and flips locked to true',
        (tester) async {
          pinViewSize(tester);
          final container = ProviderContainer();
          addTearDown(container.dispose);
          container.read(arControllerProvider.notifier).setMode(ArMode.manual);

          await tester.pumpWidget(buildStage(container));
          await tester.pump();
          arCalls.clear();

          await tester.tap(find.byKey(const Key('ar-lock')));
          await tester.pumpAndSettle();

          final lockCalls = arCalls.where((c) => c.method == 'lockManual');
          expect(lockCalls, hasLength(1));

          // manual starts at identity, so the composite is just fit: compute
          // the expected corners from Homography.fitInto(refSize, viewSize)
          // warped over the 4 ref corners.
          final fit = Homography.fitInto(refSize, viewSize);
          final expected = <double>[];
          for (final p in [
            Offset.zero,
            Offset(refSize.width, 0),
            Offset(refSize.width, refSize.height),
            Offset(0, refSize.height),
          ]) {
            final w = fit.warp(p);
            expected
              ..add(w.dx)
              ..add(w.dy);
          }

          final args = lockCalls.single.arguments as Map;
          final corners = (args['corners'] as List).cast<double>();
          expect(corners.length, 8);
          for (var i = 0; i < 8; i++) {
            expect(corners[i], closeTo(expected[i], 1e-6));
          }

          expect(container.read(arLockedProvider), isTrue);
        },
      );

      testWidgets(
        'in locked manual mode, tapping ar-lock records unlockManual (no '
        'args) and flips locked back to false',
        (tester) async {
          pinViewSize(tester);
          final container = ProviderContainer();
          addTearDown(container.dispose);
          container.read(arControllerProvider.notifier).setMode(ArMode.manual);

          await tester.pumpWidget(buildStage(container));
          await tester.pump();

          await tester.tap(find.byKey(const Key('ar-lock')));
          await tester.pumpAndSettle();
          expect(container.read(arLockedProvider), isTrue);
          arCalls.clear();

          await tester.tap(find.byKey(const Key('ar-lock')));
          await tester.pump();

          final unlockCalls = arCalls.where((c) => c.method == 'unlockManual');
          expect(unlockCalls, hasLength(1));
          expect(unlockCalls.single.arguments, isNull);
          expect(container.read(arLockedProvider), isFalse);
        },
      );

      testWidgets(
        'in unlocked manual mode, when native declines the lock (lockManual '
        'returns false — e.g. poor tracking), tapping ar-lock still records '
        'exactly one lockManual call but arLockedProvider stays false',
        (tester) async {
          pinViewSize(tester);
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(arMethodChannel, (call) async {
                arCalls.add(call);
                if (call.method == 'lockManual') return false;
                return null;
              });
          final container = ProviderContainer();
          addTearDown(container.dispose);
          container.read(arControllerProvider.notifier).setMode(ArMode.manual);

          await tester.pumpWidget(buildStage(container));
          await tester.pump();
          arCalls.clear();

          await tester.tap(find.byKey(const Key('ar-lock')));
          await tester.pumpAndSettle();

          final lockCalls = arCalls.where((c) => c.method == 'lockManual');
          expect(lockCalls, hasLength(1));
          expect(container.read(arLockedProvider), isFalse);
        },
      );
    });

    group('Re-scan control', () {
      testWidgets(
        'AUTO mode: the ar-rescan FAB is present, and tapping it invokes the '
        'native "rescan" method with no args',
        (tester) async {
          final container = ProviderContainer();
          addTearDown(container.dispose);

          await tester.pumpWidget(buildStage(container));
          await tester.pump();

          expect(
            container.read(arControllerProvider).mode,
            ArMode.auto,
            reason: 'ArController starts in auto mode',
          );
          expect(find.byKey(const Key('ar-rescan')), findsOneWidget);

          await tester.tap(find.byKey(const Key('ar-rescan')));
          await tester.pump();

          final rescanCalls = arCalls.where((c) => c.method == 'rescan');
          expect(rescanCalls, hasLength(1));
          expect(rescanCalls.single.arguments, isNull);
        },
      );

      testWidgets('MANUAL mode: the ar-rescan FAB is not shown', (
        tester,
      ) async {
        final container = ProviderContainer();
        addTearDown(container.dispose);
        container.read(arControllerProvider.notifier).setMode(ArMode.manual);

        await tester.pumpWidget(buildStage(container));
        await tester.pump();

        expect(find.byKey(const Key('ar-rescan')), findsNothing);
      });
    });

    group('Native-session gating (#7)', () {
      testWidgets(
        'inactive (native channel.start has not yet succeeded): the '
        'rescan/lock/mode-toggle FABs render disabled (onPressed null) and '
        'tapping them fires no masi/ar channel call — every AR control '
        'must be gated on ArState.active so a call never fires before the '
        'platform view has mounted its native handler',
        (tester) async {
          final container = ProviderContainer();
          addTearDown(container.dispose);
          container.read(arControllerProvider.notifier).setMode(ArMode.manual);

          await tester.pumpWidget(buildStage(container, active: false));
          await tester.pump();
          // Clears the "setMode" call the ArController.setMode(manual)
          // above already fired — this test asserts about calls made AFTER
          // the gated FABs are tapped below, not that setup itself.
          arCalls.clear();

          expect(
            tester
                .widget<FloatingActionButton>(
                  find.byKey(const Key('ar-mode-toggle')),
                )
                .onPressed,
            isNull,
          );
          expect(
            tester
                .widget<FloatingActionButton>(find.byKey(const Key('ar-lock')))
                .onPressed,
            isNull,
          );
          expect(
            tester
                .widget<FloatingActionButton>(
                  find.byKey(const Key('ar-reset')),
                )
                .onPressed,
            isNull,
          );

          await tester.tap(
            find.byKey(const Key('ar-lock')),
            warnIfMissed: false,
          );
          await tester.tap(
            find.byKey(const Key('ar-mode-toggle')),
            warnIfMissed: false,
          );
          await tester.pump();

          expect(arCalls, isEmpty);
          expect(container.read(arControllerProvider).mode, ArMode.manual);
        },
      );

      testWidgets(
        'once active, the same FABs are enabled again (regression guard: '
        'the gate must not be a one-way lock)',
        (tester) async {
          final container = ProviderContainer();
          addTearDown(container.dispose);
          container.read(arControllerProvider.notifier).setMode(ArMode.manual);

          await tester.pumpWidget(buildStage(container));
          await tester.pump();

          expect(
            tester
                .widget<FloatingActionButton>(
                  find.byKey(const Key('ar-mode-toggle')),
                )
                .onPressed,
            isNotNull,
          );
        },
      );
    });

    group('Start-failure retry affordance (#7b)', () {
      testWidgets(
        'startError set: the status pill shows a retry message instead of '
        'the usual mode/tracking readout, and tapping it invokes '
        'onRetryStart exactly once',
        (tester) async {
          pinViewSize(tester);
          final container = ProviderContainer();
          addTearDown(container.dispose);
          var retries = 0;

          await tester.pumpWidget(
            buildStage(
              container,
              startError: "Couldn't start AR — tap to retry",
              onRetryStart: () => retries++,
            ),
          );
          await tester.pump();

          expect(find.text("Couldn't start AR"), findsOneWidget);
          expect(find.text('Tap to retry'), findsOneWidget);
          expect(find.byKey(const Key('ar-status-retry')), findsOneWidget);

          await tester.tap(find.byKey(const Key('ar-status-retry')));
          await tester.pump();

          expect(retries, 1);
        },
      );

      testWidgets(
        'no startError: the status pill shows the normal mode readout and '
        'is not wrapped in a retry tap target',
        (tester) async {
          pinViewSize(tester);
          final container = ProviderContainer();
          addTearDown(container.dispose);

          await tester.pumpWidget(buildStage(container));
          await tester.pump();

          expect(find.byKey(const Key('ar-status-retry')), findsNothing);
          expect(find.byKey(const Key('ar-mode-label')), findsOneWidget);
        },
      );
    });

    group('A1: hold-last-good on a degenerate fromQuad solve', () {
      // All 4 points collinear (on the line y=50) -- Homography.fromQuad
      // returns Homography.identity() for a degenerate dst quad like this
      // one (verified directly against homography.dart; mirrors
      // homography_test.dart's B4 collinear-src case, just on the dst side).
      const degenerateCorners = <Offset>[
        Offset(50, 50),
        Offset(150, 50),
        Offset(250, 50),
        Offset(350, 50),
      ];
      const goodCorners = <Offset>[
        Offset(50, 50),
        Offset(350, 50),
        Offset(350, 750),
        Offset(50, 750),
      ];

      testWidgets(
        'A1-A2: a degenerate quad right after a good tracked frame keeps '
        'rendering the previous good homography, not Homography.identity()',
        (tester) async {
          pinViewSize(tester);
          final container = ProviderContainer();
          addTearDown(container.dispose);

          await tester.pumpWidget(buildStage(container));
          await tester.pump();

          container
              .read(arControllerProvider.notifier)
              .onAlignment(
                const ArAlignment(
                  confidence: 1.0,
                  tracking: true,
                  screenCorners: goodCorners,
                ),
              );
          await tester.pump();

          final goodHomography = currentPainter(tester).homography;
          expect(goodHomography, isNot(Homography.identity()));

          // Reset the corner-smoothing filter so the next (degenerate)
          // sample passes straight through unblended -- isolating the
          // hold-last-good behavior under test from EMA smoothing (covered
          // separately in ar_controller_test.dart / corner_smoother_test
          // .dart). Without this, blending the degenerate quad 65/35 with
          // the previous good one could denature its collinearity and mask
          // the very bug this test targets.
          container.read(arControllerProvider.notifier).resetCornerSmoothing();

          container
              .read(arControllerProvider.notifier)
              .onAlignment(
                const ArAlignment(
                  confidence: 1.0,
                  tracking: true,
                  screenCorners: degenerateCorners,
                ),
              );
          await tester.pump();

          expect(
            currentPainter(tester).homography,
            goodHomography,
            reason:
                'a degenerate fromQuad result must never be rendered '
                'directly -- the overlay should hold the last known-good '
                "homography instead of snapping to Homography.identity()'s "
                'huge top-left placement for this frame',
          );
          expect(
            currentPainter(tester).homography,
            isNot(Homography.identity()),
          );
        },
      );

      testWidgets(
        'with no prior good homography yet, a degenerate first tracked '
        'frame falls back to the fitted ghost placement, not identity',
        (tester) async {
          pinViewSize(tester);
          final container = ProviderContainer();
          addTearDown(container.dispose);

          await tester.pumpWidget(buildStage(container));
          await tester.pump();

          container
              .read(arControllerProvider.notifier)
              .onAlignment(
                const ArAlignment(
                  confidence: 1.0,
                  tracking: true,
                  screenCorners: degenerateCorners,
                ),
              );
          await tester.pump();

          final fit = Homography.fitInto(refSize, viewSize);
          expect(currentPainter(tester).homography, fit);
          expect(
            currentPainter(tester).homography,
            isNot(Homography.identity()),
          );
        },
      );

      testWidgets(
        'a tracking-loss gap clears the held last-good homography -- a '
        'degenerate frame right after re-acquiring track falls back to the '
        'fitted ghost, not the stale pre-loss placement',
        (tester) async {
          pinViewSize(tester);
          final container = ProviderContainer();
          addTearDown(container.dispose);

          await tester.pumpWidget(buildStage(container));
          await tester.pump();

          container
              .read(arControllerProvider.notifier)
              .onAlignment(
                const ArAlignment(
                  confidence: 1.0,
                  tracking: true,
                  screenCorners: goodCorners,
                ),
              );
          await tester.pump();
          expect(
            currentPainter(tester).homography,
            isNot(Homography.identity()),
          );

          container
              .read(arControllerProvider.notifier)
              .onAlignment(
                const ArAlignment(confidence: 0.0, tracking: false),
              );
          await tester.pump();

          container.read(arControllerProvider.notifier).resetCornerSmoothing();
          container
              .read(arControllerProvider.notifier)
              .onAlignment(
                const ArAlignment(
                  confidence: 1.0,
                  tracking: true,
                  screenCorners: degenerateCorners,
                ),
              );
          await tester.pump();

          final fit = Homography.fitInto(refSize, viewSize);
          expect(
            currentPainter(tester).homography,
            fit,
            reason:
                'the tracking-loss gap must have cleared the held last-good '
                'homography, so this degenerate re-acquisition frame falls '
                'back to the fitted ghost rather than a stale pre-loss '
                'placement',
          );
        },
      );

      testWidgets(
        'Defect 2: switching back to auto after a manual lock clears the '
        'held last-good homography -- a degenerate frame arriving in the '
        'SAME update as the mode switch falls back to the fitted ghost, '
        'not the stale manual-locked-session placement',
        (tester) async {
          pinViewSize(tester);
          final container = ProviderContainer();
          addTearDown(container.dispose);
          container.read(arControllerProvider.notifier).setMode(ArMode.manual);

          await tester.pumpWidget(buildStage(container));
          await tester.pump();

          // Lock manual alignment (native `lockManual` is mocked to
          // succeed -- see this file's top-level setUp) -- once locked,
          // rendering goes through the same fromQuad/hold-last-good path as
          // auto mode (see ArAlignmentStage's class doc).
          await tester.tap(find.byKey(const Key('ar-lock')));
          await tester.pumpAndSettle();
          expect(container.read(arLockedProvider), isTrue);

          container
              .read(arControllerProvider.notifier)
              .onAlignment(
                const ArAlignment(
                  confidence: 1.0,
                  tracking: true,
                  screenCorners: goodCorners,
                ),
              );
          await tester.pump();

          final goodHomography = currentPainter(tester).homography;
          expect(goodHomography, isNot(Homography.identity()));

          // Switch back to auto AND feed a degenerate frame BEFORE the
          // next pump, so both the mode change and the degenerate solve
          // land in the same build -- otherwise a redundant recompute of
          // the still-cached good corners in an intervening pump would
          // silently repopulate _lastGoodHomography with the same value
          // and mask the very bug this test targets (mode change also
          // resets arLockedProvider back to unlocked, per
          // ArController.setMode).
          container.read(arControllerProvider.notifier).setMode(ArMode.auto);
          container
              .read(arControllerProvider.notifier)
              .onAlignment(
                const ArAlignment(
                  confidence: 1.0,
                  tracking: true,
                  screenCorners: degenerateCorners,
                ),
              );
          await tester.pump();

          final fit = Homography.fitInto(refSize, viewSize);
          expect(
            currentPainter(tester).homography,
            fit,
            reason:
                'switching back to auto must clear the held last-good '
                'homography from the manual-locked session, so this '
                'degenerate first frame in the new mode falls back to the '
                'fitted ghost rather than re-pinning off a stale homography '
                'left over from the mode just left',
          );
        },
      );

      testWidgets(
        'F5: a concave (reflex-vertex) tracked-corner quad right after a '
        'good tracked frame keeps rendering the PREVIOUS good homography '
        '(no wild snap), never poisons _lastGoodHomography with the '
        'concave solve, and caps confidence below the fade threshold -- '
        'pre-fix, Homography.isDegenerateQuadSolve accepted a concave quad '
        'as non-degenerate: full confidence + a poisoned last-good pose',
        (tester) async {
          pinViewSize(tester);
          final container = ProviderContainer();
          addTearDown(container.dispose);

          await tester.pumpWidget(buildStage(container));
          await tester.pump();

          container
              .read(arControllerProvider.notifier)
              .onAlignment(
                const ArAlignment(
                  confidence: 1.0,
                  tracking: true,
                  screenCorners: goodCorners,
                ),
              );
          await tester.pump();

          final goodHomography = currentPainter(tester).homography;
          expect(goodHomography, isNot(Homography.identity()));
          expect(currentPainter(tester).confidence, 1.0);

          // Reset the corner-smoothing filter (see this group's A1-A2 test
          // above) so the concave sample below passes through unblended.
          container.read(arControllerProvider.notifier).resetCornerSmoothing();

          // One corner glitched inward into a reflex vertex -- concave, not
          // collinear -- exactly the shape homography_test.dart's F1 proves
          // fromQuad solves to a finite, non-identity homography for.
          const concaveCorners = <Offset>[
            Offset(100, 100),
            Offset(300, 100),
            Offset(150, 150),
            Offset(100, 300),
          ];
          container
              .read(arControllerProvider.notifier)
              .onAlignment(
                const ArAlignment(
                  confidence: 1.0,
                  tracking: true,
                  screenCorners: concaveCorners,
                ),
              );
          await tester.pump();

          expect(
            currentPainter(tester).homography,
            goodHomography,
            reason:
                'a concave tracked-corner solve must never be rendered '
                'directly -- the overlay must hold the previous good '
                'homography instead of snapping to the concave placement',
          );
          expect(
            currentPainter(tester).confidence,
            lessThan(kLowConfidenceThreshold),
            reason:
                'pre-fix this stayed at the full derived confidence (1.0) '
                '-- a solid overlay confidently presenting a placement '
                'from an unambiguous tracking-glitch quad',
          );

          // _lastGoodHomography itself must not have been overwritten by
          // the concave solve: feed a SECOND degenerate (collinear) frame
          // with no good frame in between. If the concave solve above had
          // poisoned _lastGoodHomography, this would now hold onto THAT
          // (wrong) placement instead of the original good one.
          container.read(arControllerProvider.notifier).resetCornerSmoothing();
          container
              .read(arControllerProvider.notifier)
              .onAlignment(
                const ArAlignment(
                  confidence: 1.0,
                  tracking: true,
                  screenCorners: degenerateCorners,
                ),
              );
          await tester.pump();

          expect(
            currentPainter(tester).homography,
            goodHomography,
            reason:
                '_lastGoodHomography must still be the original tracked '
                'pose -- the earlier concave solve must never have '
                'overwritten it',
          );
        },
      );
    });

    group(
      'A3: honest held-frame confidence -- a held/degenerate-solve frame '
      'renders at a capped low ("searching") confidence, never the real '
      'derived confidence',
      () {
        // Mirrors the "A1: hold-last-good" group's fixtures above: a
        // well-conditioned quad, and one flagged degenerate by
        // Homography.isDegenerateQuadSolve (exactly collinear here, but the
        // confidence-capping code path is identical for any rejected solve
        // -- see ArAlignmentStage's build method).
        const goodCorners = <Offset>[
          Offset(50, 50),
          Offset(350, 50),
          Offset(350, 750),
          Offset(50, 750),
        ];
        const degenerateCorners = <Offset>[
          Offset(50, 50),
          Offset(150, 50),
          Offset(250, 50),
          Offset(350, 50),
        ];

        testWidgets(
          'first-tracked-no-lastgood: a degenerate first tracked frame '
          'renders the fitted ghost at a capped LOW confidence, not the '
          'full derived confidence ARKit reported',
          (tester) async {
            pinViewSize(tester);
            final container = ProviderContainer();
            addTearDown(container.dispose);

            await tester.pumpWidget(buildStage(container));
            await tester.pump();

            container
                .read(arControllerProvider.notifier)
                .onAlignment(
                  const ArAlignment(
                    confidence: 0.0,
                    tracking: true,
                    screenCorners: degenerateCorners,
                    // trackingState defaults to normal -> derivedConfidence
                    // 1.0 -- proving the cap, not just a naturally-low
                    // ARKit-reported confidence, is what's in effect here.
                  ),
                );
            await tester.pump();

            final fit = Homography.fitInto(refSize, viewSize);
            expect(currentPainter(tester).homography, fit);
            expect(
              currentPainter(tester).confidence,
              lessThan(kLowConfidenceThreshold),
              reason:
                  'a degenerate first-ever solve must never render at full '
                  'derived confidence just because ARKit itself reports '
                  'good tracking quality -- the CURRENT frame\'s alignment '
                  'was never actually solved',
            );
          },
        );

        testWidgets(
          'stale-hold: a degenerate frame arriving right after a good '
          'tracked frame keeps rendering the PREVIOUS good homography, but '
          'the confidence drops to the capped low band instead of staying '
          'at the full derived confidence -- this is the core "confidently '
          'wrong" regression this fix targets: pre-fix, this rendered a '
          'SOLID overlay at a stale/possibly-wrong placement',
          (tester) async {
            pinViewSize(tester);
            final container = ProviderContainer();
            addTearDown(container.dispose);

            await tester.pumpWidget(buildStage(container));
            await tester.pump();

            container
                .read(arControllerProvider.notifier)
                .onAlignment(
                  const ArAlignment(
                    confidence: 0.0,
                    tracking: true,
                    screenCorners: goodCorners,
                  ),
                );
            await tester.pump();

            final goodHomography = currentPainter(tester).homography;
            expect(currentPainter(tester).confidence, 1.0);

            container.read(arControllerProvider.notifier).resetCornerSmoothing();
            container
                .read(arControllerProvider.notifier)
                .onAlignment(
                  const ArAlignment(
                    confidence: 0.0,
                    tracking: true,
                    screenCorners: degenerateCorners,
                  ),
                );
            await tester.pump();

            expect(
              currentPainter(tester).homography,
              goodHomography,
              reason: 'the held pose itself must be unaffected by this fix',
            );
            expect(
              currentPainter(tester).confidence,
              lessThan(kLowConfidenceThreshold),
              reason:
                  'pre-fix this stayed at 1.0 -- a solid overlay confidently '
                  'presenting a possibly-stale placement as fully '
                  'trustworthy',
            );
          },
        );

        testWidgets(
          'good frame (unchanged): a well-conditioned solve still renders '
          'at the full real derived confidence -- the cap only applies to '
          'held/degenerate frames',
          (tester) async {
            pinViewSize(tester);
            final container = ProviderContainer();
            addTearDown(container.dispose);

            await tester.pumpWidget(buildStage(container));
            await tester.pump();

            container
                .read(arControllerProvider.notifier)
                .onAlignment(
                  const ArAlignment(
                    confidence: 0.0,
                    tracking: true,
                    screenCorners: goodCorners,
                  ),
                );
            await tester.pump();

            final expected = Homography.fromQuad([
              Offset.zero,
              Offset(refSize.width, 0),
              Offset(refSize.width, refSize.height),
              Offset(0, refSize.height),
            ], goodCorners);

            expect(currentPainter(tester).homography, expected);
            expect(currentPainter(tester).confidence, 1.0);
          },
        );
      },
    );

    group(
      'A1: real confidence from trackingState drives the low-confidence '
      'fade + status pill',
      () {
        const corners = <Offset>[
          Offset(50, 50),
          Offset(350, 50),
          Offset(350, 750),
          Offset(50, 750),
        ];

        testWidgets(
          'A1-A4: trackingState absent (ArAlignment\'s default) -> '
          'confidence 1.0, "Tracking" label -- backward-compatible with '
          'pre-A1 behavior',
          (tester) async {
            pinViewSize(tester);
            final container = ProviderContainer();
            addTearDown(container.dispose);

            await tester.pumpWidget(buildStage(container));
            await tester.pump();

            container
                .read(arControllerProvider.notifier)
                .onAlignment(
                  const ArAlignment(
                    confidence: 0.0,
                    tracking: true,
                    screenCorners: corners,
                  ),
                );
            await tester.pump();

            expect(currentPainter(tester).confidence, 1.0);
            expect(find.text('Tracking'), findsOneWidget);
          },
        );

        testWidgets(
          'A1-A3: trackingState=limited -> confidence 0.35 (below '
          'kLowConfidenceThreshold, so the painter\'s low-confidence path '
          'fires), status pill reads "Limited" with a reason-derived hint',
          (tester) async {
            pinViewSize(tester);
            final container = ProviderContainer();
            addTearDown(container.dispose);

            await tester.pumpWidget(buildStage(container));
            await tester.pump();

            container
                .read(arControllerProvider.notifier)
                .onAlignment(
                  const ArAlignment(
                    confidence: 0.0,
                    tracking: true,
                    screenCorners: corners,
                    trackingState: ArTrackingState.limited,
                    limitedReason: 'excessiveMotion',
                  ),
                );
            await tester.pump();

            expect(currentPainter(tester).confidence, 0.35);
            expect(
              currentPainter(tester).confidence,
              lessThan(kLowConfidenceThreshold),
            );
            expect(find.text('Limited'), findsOneWidget);
            expect(
              tester.widget<Text>(find.byKey(const Key('ar-hint'))).data,
              'Move slower',
            );
          },
        );

        testWidgets(
          'A1-A3: trackingState=limited with tracking:true keeps the '
          'overlay in the tracked/placed state (fromQuad-solved from the '
          'reported screenCorners), NOT the centered ghost -- only '
          'confidence drops, the overlay never un-glues from the wall '
          '(native decouples the render/tracking:true gate from tracking '
          'quality -- only notAvailable ghosts it, see ArPlatformView.swift)',
          (tester) async {
            pinViewSize(tester);
            final container = ProviderContainer();
            addTearDown(container.dispose);

            await tester.pumpWidget(buildStage(container));
            await tester.pump();

            container
                .read(arControllerProvider.notifier)
                .onAlignment(
                  const ArAlignment(
                    confidence: 0.0,
                    tracking: true,
                    screenCorners: corners,
                    trackingState: ArTrackingState.limited,
                    limitedReason: 'excessiveMotion',
                  ),
                );
            await tester.pump();

            final expected = Homography.fromQuad([
              Offset.zero,
              Offset(refSize.width, 0),
              Offset(refSize.width, refSize.height),
              Offset(0, refSize.height),
            ], corners);

            expect(
              currentPainter(tester).homography,
              expected,
              reason:
                  'a .limited frame must still be treated as tracked/'
                  'placed -- the overlay stays glued to the wall '
                  '(fromQuad of the reported corners), it must not fall '
                  'back to the fitted ghost the way tracking:false does',
            );
            expect(
              currentPainter(tester).homography,
              isNot(Homography.fitInto(refSize, viewSize)),
            );
            expect(currentPainter(tester).confidence, 0.35);
            expect(
              currentPainter(tester).confidence,
              lessThan(kLowConfidenceThreshold),
            );
          },
        );

        testWidgets(
          'A1-A3: trackingState=notAvailable -> confidence 0.1',
          (tester) async {
            pinViewSize(tester);
            final container = ProviderContainer();
            addTearDown(container.dispose);

            await tester.pumpWidget(buildStage(container));
            await tester.pump();

            container
                .read(arControllerProvider.notifier)
                .onAlignment(
                  const ArAlignment(
                    confidence: 0.0,
                    tracking: true,
                    screenCorners: corners,
                    trackingState: ArTrackingState.notAvailable,
                  ),
                );
            await tester.pump();

            expect(currentPainter(tester).confidence, 0.1);
            expect(
              currentPainter(tester).confidence,
              lessThan(kLowConfidenceThreshold),
            );
          },
        );
      },
    );
  });
}
