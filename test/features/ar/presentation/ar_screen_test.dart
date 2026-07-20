import 'dart:async';
import 'dart:ui' as ui;

import 'package:climbtopo/app/theme.dart';
import 'package:climbtopo/core/db/app_database.dart';
import 'package:climbtopo/core/db/database_provider.dart';
import 'package:climbtopo/features/ar/application/ar_channel.dart';
import 'package:climbtopo/features/ar/application/ar_controller.dart';
import 'package:climbtopo/features/ar/application/manual_align_controller.dart';
import 'package:climbtopo/features/ar/domain/homography.dart';
import 'package:climbtopo/features/ar/presentation/ar_overlay_painter.dart';
import 'package:climbtopo/features/ar/presentation/ar_screen.dart';
import 'package:climbtopo/features/library/application/library_providers.dart';
import 'package:climbtopo/features/topo/data/route_repository.dart';
import 'package:climbtopo/features/topo/domain/topo_route.dart';
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
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // ArController.setMode fires a real (fire-and-forget) MethodChannel call
  // on 'climbtopo/ar' — mocked here (mirroring
  // test/features/ar/application/ar_controller_test.dart) so the
  // ArAlignmentStage group's mode-toggle interactions never hit an
  // unhandled MissingPluginException from the unregistered real channel.
  const arMethodChannel = MethodChannel('climbtopo/ar');

  /// Records every `climbtopo/ar` method call made during a test — used by
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
        'tapping them fires no climbtopo/ar channel call — every AR control '
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
  });
}
