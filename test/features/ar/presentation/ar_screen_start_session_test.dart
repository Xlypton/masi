import 'package:masi/app/theme.dart';
import 'package:masi/core/db/app_database.dart';
import 'package:masi/core/db/database_provider.dart';
import 'package:masi/features/ar/application/ar_channel.dart';
import 'package:masi/features/ar/application/ar_controller.dart';
import 'package:masi/features/ar/domain/rock_box.dart';
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

/// Stands in for the real `path_provider` platform channel plugin (no mock
/// registered in this suite's plain `flutter test` host). Needed here because
/// this file mounts a real [ArScreen] with a persisted photo — see
/// `ar_screen_test.dart`'s identically-named fake for the full rationale (an
/// unmocked `getApplicationDocumentsPath()` call made from inside
/// `ArScreen._load`'s async lifecycle never settles under `pumpAndSettle`).
class _FakePathProviderPlatform extends PathProviderPlatform {
  @override
  Future<String?> getApplicationDocumentsPath() async =>
      '/tmp/ar_screen_start_session_test_docs';
}

/// A fake [ArChannel] whose [start] resolves to `true` (a "native started
/// successfully" result) rather than [ArChannel.noop]'s always-`false`
/// result, so this test can exercise `_ArScreenState._startSession`'s
/// success path for real.
///
/// Constructed via `super.noop()` — [ArChannel.noop]'s own constructor sets
/// the private `_noop` flag every OTHER public method
/// (`alignments`/`setMode`/`rescan`/`lockManual`/`unlockManual`) checks first
/// (`if (_noop) return ...`) — so leaving all of them un-overridden here
/// already gives the exact same safe no-op behavior `ArChannel.noop()` itself
/// provides, with no need to duplicate that logic. [start]/[stop] are
/// overridden since this test needs to observe/control them directly.
class _FakeArChannel extends ArChannel {
  _FakeArChannel() : super.noop();

  /// Set by [stop] when called. Lets this test assert that
  /// `_ArScreenState.dispose()` actually invokes `channel.stop()` (releasing
  /// the native camera/tracking session) rather than silently skipping it —
  /// see the dispose-time bug this test's final block documents/asserts.
  bool stopCalled = false;

  @override
  Future<bool> start({
    required String referenceImagePath,
    required int refWidth,
    required int refHeight,
    ArPlacementEngine engine = ArPlacementEngine.arkit,
    List<double>? rockQuad,
  }) async => true;

  @override
  Future<void> stop() {
    stopCalled = true;
    return super.stop();
  }
}

/// Covers the end-to-end forwarding `_ArScreenState._startSession` is
/// responsible for post-Ship-1 (#68): once `channel.start(...)` resolves,
/// the session is marked active and `ArController.setRockBox` is called with
/// the box `rockBoxFromRoutes` derives from the wall's OWN routes (a pure
/// function of `_routes`, never anything native returns — see
/// `rock_box.dart`).
///
/// This test reaches `_startSession` for real, by mounting a genuine
/// `UiKitView` (native/auto-tracking branch) and letting its
/// `onPlatformViewCreated` callback fire — the same gate
/// `_maybeStartSession`'s doc describes as the only legitimate way
/// `_startSession` is ever invoked.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late PathProviderPlatform originalPathProviderPlatform;
  setUp(() {
    originalPathProviderPlatform = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _FakePathProviderPlatform();
    // A real UiKitView's `_createNewUiKitView` awaits
    // `SystemChannels.platform_views`'s 'create' method call before ever
    // invoking `onPlatformViewCreated` (see the framework's
    // `platform_view.dart`) — and `_maybeStartSession`/`_startSession` are
    // ONLY ever reached from that callback (see `ar_screen.dart`'s doc).
    // With no handler registered at all, that 'create' call throws
    // MissingPluginException and onPlatformViewCreated never fires, so
    // this test would never reach the very line under test. Returning
    // `null` unconditionally mirrors the Flutter SDK's own
    // `FakeIosPlatformViewsController`'s happy-path 'create' response
    // (`packages/flutter/test/services/fake_platform_views.dart`) — there's
    // no real native view to track here, just enough to let the awaited
    // Future resolve so the framework fires the created-callback.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          SystemChannels.platform_views,
          (call) async => null,
        );
  });
  tearDown(() {
    PathProviderPlatform.instance = originalPathProviderPlatform;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform_views, null);
  });

  testWidgets(
    '_startSession marks the session active and sets arControllerProvider.'
    "rockBox to rockBoxFromRoutes(_routes)'s result once channel.start() "
    'resolves -- deleting that forwarding line in ar_screen.dart must fail '
    'this test',
    (tester) async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final fakeChannel = _FakeArChannel();
      final container = ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWithValue(db),
          nowMsProvider.overrideWithValue(() => 1000),
          arSupportedProvider.overrideWithValue(true),
          // true (the native/auto-tracking branch): ArScreen.build only ever
          // constructs a real UiKitView -- and thus only ever wires
          // onPlatformViewCreated -> _maybeStartSession -- when this is
          // true. With this false (the web branch, per ar_web_manual_test
          // .dart's C4 group), _startSession is never invoked at all: the
          // web camera surface's own onReady callback marks the session
          // active directly, bypassing _startSession/channel.start()
          // entirely (see ar_screen.dart's build doc).
          arAutoTrackingProvider.overrideWithValue(true),
          arChannelProvider.overrideWithValue(fakeChannel),
        ],
      );
      addTearDown(container.dispose);

      const route = TopoRoute(
        id: 1,
        number: 1,
        points: [Offset(0.1, 0.2), Offset(0.4, 0.5)],
        // visible defaults to true -- _maybeStartSession's hasVisibleRoute
        // gate needs at least one visible route or it bails before ever
        // calling _startSession.
      );
      // Computed via the SAME pure function `_startSession` must call --
      // this test proves the forwarding wire-up, not `rockBoxFromRoutes`'s
      // geometry itself (that's covered in isolation by rock_box_test.dart).
      final expectedBox = rockBoxFromRoutes(const [route]);
      expect(expectedBox, isNotNull);

      final crud = container.read(libraryCrudRepositoryProvider);
      final area = await crud.createArea('Area');
      final sector = await crud.createSector(area.id, 'Sector');
      final wall = await crud.createWall(sector.id, 'Wall');
      late String photoId;
      await tester.runAsync(() async {
        photoId = await crud.attachPhotoToWall(
          wall.id,
          XFile('/tmp/ar-start-session-test-photo.jpg'),
          1000,
          2000,
        );
        final routeRepo = RouteRepository(db, nowMs: () => 1000);
        await routeRepo.upsertRoute(wall.id, photoId, route);
      });

      expect(
        container.read(arControllerProvider).rockBox,
        isNull,
        reason: 'sanity: nothing set yet before the session ever starts',
      );
      expect(
        container.read(arControllerProvider).active,
        isFalse,
        reason: 'sanity: nothing marked active yet',
      );

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

      expect(
        find.byType(UiKitView),
        findsOneWidget,
        reason:
            'sanity: arSupportedProvider:true + arAutoTrackingProvider:true '
            'must take the native branch, or onPlatformViewCreated (and '
            'thus _startSession) is never reached at all',
      );
      expect(
        container.read(arControllerProvider).active,
        isTrue,
        reason:
            '_startSession must mark the session active once channel.start() '
            'resolves',
      );
      expect(
        container.read(arControllerProvider).rockBox,
        expectedBox,
        reason:
            '_startSession must call '
            'setRockBox(rockBoxFromRoutes(_routes)) -- the same pure '
            'function computed independently above from the identical '
            'route geometry',
      );

      // Explicitly unmount (mirrors the same pattern `ar_screen_test.dart`'s
      // Fix 1/B3 tests already use to simulate a real Navigator.pop) so this
      // test controls exactly when `_ArScreenState.dispose()` runs, rather
      // than leaving it to the framework's own implicit end-of-test teardown.
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      expect(
        tester.takeException(),
        isNull,
        reason: 'dispose() must not throw',
      );
      expect(
        fakeChannel.stopCalled,
        isTrue,
        reason:
            "dispose() must actually call the cached channel's stop() to "
            'release the native camera/tracking session',
      );
    },
  );
}
