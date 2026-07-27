import 'dart:async';
import 'dart:math' show min;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show StandardMessageCodec;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:masi/app/theme.dart';
import 'package:masi/core/db/database_provider.dart';
import 'package:masi/core/platform/ar_support.dart';
import 'package:masi/features/ar/application/ar_channel.dart';
import 'package:masi/features/ar/application/ar_controller.dart';
import 'package:masi/features/ar/application/ar_segmentation_channel.dart';
import 'package:masi/features/ar/application/manual_align_controller.dart';
import 'package:masi/features/ar/application/outline_extractor.dart';
import 'package:masi/features/ar/domain/homography.dart';
import 'package:masi/features/ar/domain/rock_box.dart';
import 'package:masi/features/ar/presentation/ar_camera_view.dart';
import 'package:masi/features/ar/presentation/ar_overlay_painter.dart';
import 'package:masi/features/topo/data/photo_repository.dart';
import 'package:masi/features/topo/domain/topo_route.dart';
import 'package:masi/features/topo/presentation/canvas_chrome.dart';
import 'package:masi/features/topo/presentation/grade_colors.dart';
import 'package:masi/features/topo/presentation/route_palette.dart';
import 'package:masi/shared/presentation/masi_icon.dart';

/// The `PlatformView` type used for the native camera/AR surface on iOS.
/// Kept as a top-level constant string (rather than sprinkled as a literal)
/// so [ArScreen] and any future native-side wiring agree on the exact
/// channel/view-type name.
const String _kArPlatformViewType = 'masi/ar';

/// Confidence cap applied whenever [ArAlignmentStage] renders a HELD
/// homography instead of a freshly-solved one -- either the stale last
/// known-good pose (the current frame's `Homography.fromQuad` solve was
/// rejected by [Homography.isDegenerateQuadSolve]) or the generic centered
/// [Homography.fitInto] ghost (no known-good pose exists yet). Both are
/// genuinely uncertain about the CURRENT frame's real alignment, so
/// rendering either at full derived confidence would present a stale-or-
/// placeholder placement as fully trustworthy -- a solid "confidently
/// wrong" overlay. `min`-ed against the real
/// [ArAlignment.derivedConfidence] (never raised upward) so an
/// already-lower ARKit-reported confidence is never overridden; kept
/// comfortably below [kLowConfidenceThreshold] so `ArOverlayPainter`
/// always renders it in its faint "searching" treatment.
const double _kHeldFrameConfidenceCap = 0.2;

/// The AR live-alignment screen for a wall: overlays that wall's routes
/// (warped through the current camera-alignment [Homography]) on top of a
/// live camera feed.
///
/// ## Testability structure (read this before touching platform-gating code)
///
/// The *only* iOS-gated piece of this screen is the native `UiKitView`
/// camera surface itself. Everything else — the overlay painter, the
/// auto/manual mode toggle, and the manual pan/scale/rotate gesture layer —
/// lives in [ArAlignmentStage], a plain [ConsumerStatefulWidget] with NO
/// platform checks of its own (its private State merely caches the last
/// known-good homography across frames — see that class's doc). [ArScreen]
/// only ever *constructs* [ArAlignmentStage]
/// from its iOS branch (handing it a real `UiKitView` as [ArAlignmentStage
/// .cameraView]), but nothing stops a test from pumping [ArAlignmentStage]
/// directly — on ANY platform — with a harmless placeholder [Widget] (e.g.
/// a plain `Container`) standing in for the camera surface. That's exactly
/// how this feature's toggle/gesture contract (auto vs. manual homography
/// selection, manual pan/scale/rotate) is exercised in
/// `test/features/ar/presentation/ar_screen_test.dart`: real
/// [ArOverlayPainter]/[ArController]/[ManualAlignController] wiring, zero
/// native view, zero platform gating to work around.
class ArScreen extends ConsumerStatefulWidget {
  const ArScreen({super.key, required this.wallId});

  /// The wall whose original photo + routes this AR session aligns against.
  final String wallId;

  @override
  ConsumerState<ArScreen> createState() => _ArScreenState();
}

class _ArScreenState extends ConsumerState<ArScreen> {
  PhotoRef? _photo;
  List<TopoRoute>? _routes;
  bool _loading = true;

  /// The reference photo's edge-only "ghost" outline, used by the guided-
  /// manual alignment stage as a lining-up aid (see [ArAlignmentStage]).
  /// Computed asynchronously in [_load] (via [extractOutline]) so it never
  /// blocks the camera/routes from appearing first; stays `null` if
  /// extraction fails or hasn't finished yet.
  ui.Image? _outline;

  /// Set once [ArChannel.start] has actually been invoked, so [dispose]
  /// only calls [ArChannel.stop] (and clears [ArController.markActive]) for
  /// a session that was really started — never on a platform where AR was
  /// never supported in the first place.
  bool _sessionStarted = false;

  /// Set (to a short, tap-to-retry message) when [_startSession]'s
  /// `channel.start(...)` call throws — e.g. the user denied the camera
  /// permission natively. `null` while there's no start failure to show.
  /// Surfaced by [_ArStatus] in place of its usual mode/tracking readout;
  /// tapping it calls [_retryStartSession]. See #7b.
  String? _startError;

  /// Bumped by [_retryStartSession]'s web branch to force the web camera
  /// view ([buildArCameraView]) to remount on retry — see that method's
  /// doc. Only ever read by [build]'s `KeyedSubtree` key in the
  /// `!autoTracking` branch; native retries never touch it.
  int _webCameraAttempt = 0;

  StreamSubscription<ArAlignment>? _alignmentSubscription;

  /// Cached copies of [arChannelProvider]/[arControllerProvider.notifier],
  /// resolved once here in [initState] (where `ref.read` is safe — the
  /// element is freshly mounted) rather than read fresh in [dispose].
  ///
  /// Flutter's `StatefulElement.unmount()` calls `super.unmount()` (which
  /// marks the element `defunct`) BEFORE calling `state.dispose()`, and
  /// Riverpod 3.3.2's `WidgetRef.read`/`watch` each start with an
  /// unconditional `_assertNotDisposed()` check against exactly that flag
  /// (see `flutter_riverpod`'s `consumer.dart`) — so a `ref.read` called
  /// directly in `dispose()`'s body throws a `StateError` there on every
  /// real teardown, silently skipping whatever cleanup came after the first
  /// such call ever since (`FlutterError` catches and reports it, which is
  /// why this never surfaced as an on-device crash). Both providers are
  /// plain (non-autoDispose) app-lifetime singletons — see
  /// `arChannelProvider`/`arControllerProvider`'s docs in
  /// `ar_controller.dart` — so caching the resolved instances here is safe:
  /// they aren't torn down when this screen is, only when the whole
  /// `ProviderContainer` is.
  late final ArChannel _arChannel;
  late final ArController _arController;

  @override
  void initState() {
    super.initState();
    _arChannel = ref.read(arChannelProvider);
    _arController = ref.read(arControllerProvider.notifier);
    _load();
  }

  Future<void> _load() async {
    final photo = await ref
        .read(photoRepositoryProvider)
        .loadOriginal(widget.wallId);
    final routes = photo == null
        ? <TopoRoute>[]
        : await ref
            .read(routeRepositoryProvider)
            .loadRoutes(widget.wallId, photo.id);
    debugPrint(
      'AR_DBG _load photo=${photo != null} routeCount=${routes.length} '
      'visibleCount=${routes.where((r) => r.visible).length}',
    );
    if (!mounted) return;

    // Cross-wall state leak fix: reset the AR view state to a clean
    // per-entry default BEFORE anything below (in particular, before
    // _startSession) ever runs — see _resetArViewState's doc. Placed here,
    // after the two awaits above rather than synchronously in initState,
    // for the same reason _startSession's own markActive/onAlignment calls
    // further down are never wrapped in a Future.microtask: `await`
    // unconditionally defers to a microtask even when the awaited future is
    // already complete, so by the time execution resumes here the widget
    // tree's build phase for this frame is already done and Riverpod's
    // "modify a provider while the widget tree was building" guard no
    // longer applies (see topo_canvas_screen.dart's initState doc for the
    // fuller explanation of this same timing argument).
    _resetArViewState();

    setState(() {
      _photo = photo;
      _routes = routes;
      _loading = false;
    });

    // Kick off the native rock-segmentation pass alongside the ghost-outline
    // extraction below — neither blocks the camera/routes above, and this
    // one doesn't block (or wait on) the outline either: this is the
    // per-pixel crop tier for the ghost outline (see
    // ArOverlayPainter.rockMask's doc); the route-hull rockBoxFromRoutes
    // rectangle covers the ghost crop until/unless this resolves (or on
    // platforms where it never runs at all).
    if (photo != null) {
      unawaited(_segmentRock(photo, routes));
    }

    // Kick off the ghost-outline extraction without blocking the camera/
    // routes above — they render immediately; the outline (when it
    // succeeds) fades in a moment later via this second setState.
    //
    // Gated on `isArSupported()` first: this whole path only ever matters on
    // the one platform AR actually runs on (iOS); everywhere else (Android,
    // web, desktop, and the test host) it must never touch a `File` at all —
    // both because there's no ghost-outline UI to feed on those platforms,
    // and because a `dart:io` `File` reference must never even be reachable
    // from web-compiled code (see `lib/core/platform/ar_support.dart`).
    //
    // Then a synchronous existence check: `extractOutline` spawns a real
    // background isolate (via `compute()`) to read + decode the file, which
    // is real OS-level async work that never completes under a widget
    // test's fake-async pump loop (the same hazard `photo_files.dart`'s
    // `resolvePhotoPath` documents for `File.exists()` vs `existsSync()`) —
    // without this guard, any wall whose persisted photo path doesn't
    // resolve to a real file on THIS host (e.g. a test seeding a placeholder
    // path with no `path_provider` platform fake registered, so
    // `PhotoRepository.loadOriginal` can't resolve it to an absolute path)
    // hangs `tester.pumpAndSettle()` forever trying to spawn+await that
    // isolate. `photoFileExistsSync` is a cheap local stat (synchronous, no
    // event-loop turn) so it's safe to call unconditionally; on a real
    // device the photo file genuinely exists, so this never skips real
    // extraction.
    if (photo != null &&
        isArSupported() &&
        photoFileExistsSync(photo.localPath)) {
      final outline = await extractOutline(photo.localPath);
      if (!mounted) return;
      setState(() => _outline = outline);
    }
  }

  /// Runs a one-shot native Core ML rock segmentation of [photo] (clipped to
  /// [routes]' geometry via `flattenRoutesNorm`) and stores the resulting
  /// per-pixel mask via [ArController.setRockMask]. Best-effort: any failure
  /// (including running on a platform/session where segmentation isn't
  /// supported) just leaves the mask `null`, so `ArOverlayPainter` falls back
  /// to the route-hull `rockBoxFromRoutes` rectangle crop instead.
  Future<void> _segmentRock(PhotoRef photo, List<TopoRoute> routes) async {
    if (!isArSupported()) return; // web/unsupported → no Core ML; box-crop fallback covers it
    try {
      final result = await ref
          .read(arSegmentationChannelProvider)
          .segmentPreview(photo.localPath, routesNorm: flattenRoutesNorm(routes));
      if (!mounted) {
        result.mask?.dispose();
        return;
      }
      _arController.setRockMask(result.mask);
    } catch (_) {
      // Segmentation is best-effort; the route-hull box crop is the fallback.
    }
  }

  /// Resets the AR view state to a clean per-wall-entry default: every AR
  /// session starts in [ArMode.auto] on native (ARKit image-tracking is the
  /// primary alignment mode there) or [ArMode.manual] on web (no continuous
  /// tracking session exists in a browser — see [arAutoTrackingProvider]),
  /// with [manualAlignProvider] back at [Homography.identity] and
  /// [arLockedProvider] back to unlocked.
  ///
  /// [arControllerProvider], [manualAlignProvider], and [arLockedProvider]
  /// are app-lifetime singletons — never reset per wall on their own.
  /// Without this, opening wall A's AR, hand-adjusting/locking the overlay,
  /// switching to manual, backing out, then opening wall B's AR would leave
  /// wall B's session already in manual/locked with wall A's leftover
  /// homography warped over wall B's (completely different) routes/feed.
  ///
  /// [manualAlignProvider]'s and [arLockedProvider]'s resets are always
  /// state-only — no native channel involved. [arControllerProvider]'s mode
  /// is only touched via [ArController.setMode] when it isn't already
  /// [ArMode.auto]: `setMode` also fires a (fire-and-forget) native
  /// `setMode` platform-channel call via [arChannelProvider] — harmless on
  /// iOS (or wherever `masi/ar` is mocked, as in this feature's own
  /// tests), but unnecessary work for a mode that's already correct, and a
  /// call this screen has no reason to make on every single entry when
  /// there's nothing to actually reset.
  ///
  /// Note: on native, this matches [ArController.build]'s own default (also
  /// [ArMode.auto]) — manual remains reachable at any time via the
  /// mode-toggle FAB as a fallback when ARKit tracking isn't available/good
  /// enough. On web, this deliberately steps AWAY from that default (auto)
  /// straight to manual, since there's no mode-toggle FAB there at all (see
  /// `_ArControls`) — auto would otherwise be an unreachable dead mode.
  void _resetArViewState() {
    ref.read(manualAlignProvider.notifier).reset();
    ref.read(arLockedProvider.notifier).reset();
    // Corner-smoothing is an app-lifetime singleton's internal filter (see
    // ArController._cornerSmoother) — reset unconditionally (unlike the mode
    // check just below) so a fresh wall entry never blends its first tracked
    // corners against a previous wall's leftover filter state.
    ref.read(arControllerProvider.notifier).resetCornerSmoothing();
    // Same app-lifetime-singleton concern as corner-smoothing just above:
    // rockBox (the route-derived rock box from the PREVIOUS session — see
    // ArState.rockBox's doc) must never leak into a new wall's session,
    // since _startSession only overwrites it once _routes for the NEW wall
    // has loaded — a wall whose own routes have no geometry to derive a box
    // from would otherwise keep rendering the PRIOR wall's box/highlight
    // instead of falling back to null (full-photo rect / no highlight).
    ref.read(arControllerProvider.notifier).setRockBox(null);
    // Same rationale as rockBox just above: the per-pixel rock mask (see
    // ArState.rockMask's doc) is a fresh-per-session native segmentation
    // result — it must never leak into a new wall's session either.
    ref.read(arControllerProvider.notifier).setRockMask(null);
    // arAutoTrackingProvider (not a direct arSupportsAutoTracking() call) so
    // this is overridable in tests, same as arSupportedProvider elsewhere in
    // this file.
    //
    // Manual is the target ONLY for a platform that genuinely supports AR
    // but has no continuous tracking session — i.e. real web. Everywhere
    // AR isn't supported at all (arSupportedProvider false — Android,
    // desktop, and this suite's own non-iOS `flutter test` host, see A1's
    // doc above) keeps the pre-existing unconditional auto default: on
    // those platforms ArScreen never even reaches ArAlignmentStage (build's
    // arSupportedProvider gate shows the unsupported placeholder instead),
    // so the mode is moot there, but leaving it at auto preserves this
    // method's prior (platform-unaware) behavior for every test that
    // asserts about it without touching either provider.
    final targetMode =
        ref.read(arAutoTrackingProvider) || !ref.read(arSupportedProvider)
        ? ArMode.auto
        : ArMode.manual;
    if (ref.read(arControllerProvider).mode != targetMode) {
      // setMode also fires a (fire-and-forget) native `setMode` platform-
      // channel call via arChannelProvider — harmless on web too, since
      // arChannelProvider resolves to ArChannel.noop() there (see
      // ar_channel_factory.dart).
      ref.read(arControllerProvider.notifier).setMode(targetMode);
    }
  }

  /// Whether the native AR camera view (a `UiKitView`) is available on this
  /// platform. Reads [arSupportedProvider] (see `ar_controller.dart`) —
  /// which itself just delegates to [isArSupported] (see
  /// `lib/core/platform/ar_support.dart`) by default — rather than calling
  /// [isArSupported] directly, so this gate is overridable in tests. This
  /// method's only caller is [_maybeStartSession], which is itself only
  /// ever reached from a native `UiKitView`'s `onPlatformViewCreated` (see
  /// [build]); web's manual-alignment path never mounts a `UiKitView` at
  /// all, so it never calls this.
  bool _isArPlatformSupported() => ref.read(arSupportedProvider);

  /// Kicks off [_startSession] once the native `UiKitView` (and therefore
  /// its `masi/ar` MethodChannel handler) has actually mounted — see
  /// [build]'s `onPlatformViewCreated` wiring. Calling [ArChannel.start]
  /// any earlier (e.g. straight out of [_load]) sends it before the native
  /// handler is registered, so the native side never receives it and the
  /// camera never starts.
  void _maybeStartSession() {
    if (!mounted) return;
    if (_sessionStarted) return;
    final photo = _photo;
    final routes = _routes;
    if (photo == null || routes == null || routes.isEmpty) return;
    final hasVisibleRoute = routes.any((r) => r.visible);
    debugPrint('AR_DBG _maybeStartSession gate hasVisibleRoute=$hasVisibleRoute');
    if (!hasVisibleRoute || !_isArPlatformSupported()) {
      debugPrint('AR_DBG _maybeStartSession BAILED (no start call)');
      return;
    }
    unawaited(_startSession(photo, routes));
  }

  Future<void> _startSession(PhotoRef photo, List<TopoRoute> routes) async {
    _sessionStarted = true;
    final channel = ref.read(arChannelProvider);
    debugPrint('AR_DBG _startSession calling channel.start');
    try {
      await channel.start(
        referenceImagePath: photo.localPath,
        refWidth: photo.width,
        refHeight: photo.height,
      );
    } catch (error) {
      // Native start threw (e.g. camera permission denied, or no camera on
      // this device) — leave the session as never-started so a retry (via
      // the status pill, see _retryStartSession) can attempt it again,
      // rather than getting permanently stuck behind `_sessionStarted`.
      debugPrint('AR_DBG _startSession channel.start threw: $error');
      _sessionStarted = false;
      if (mounted) {
        setState(() => _startError = "Couldn't start AR — tap to retry");
      }
      return;
    }
    if (!mounted) return;
    if (_startError != null) {
      setState(() => _startError = null);
    }
    ref.read(arControllerProvider.notifier).markActive(true);
    // Ship 1 of the #68 AR overhaul: the rock "highlight"/tracking box is no
    // longer a native Vision-segmentation result (which selected PEOPLE
    // instead of the rock) — it's derived directly from the wall's own drawn
    // route geometry, which is always on the rock. See rock_box.dart.
    ref.read(arControllerProvider.notifier).setRockBox(rockBoxFromRoutes(routes));
    _alignmentSubscription = channel.alignments().listen(
      ref.read(arControllerProvider.notifier).onAlignment,
    );
  }

  /// Retries after a failed start (see [_startError] and #7b).
  ///
  /// On web (`!arAutoTrackingProvider`), there is no native session to
  /// retry — [_startError] there came from [_ArWebCameraViewState]'s
  /// `getUserMedia()` call throwing (e.g. the user denying the camera
  /// permission), and that call only ever runs once, in that State's
  /// `initState`. [ArChannel.noop().start] (what `channel.start` resolves
  /// to on web — see `ar_channel_factory.dart`) returns successfully
  /// without throwing and without ever touching the camera, so routing a
  /// web retry through [_startSession] would clear [_startError] and
  /// `markActive(true)` while the camera surface is still the same failed,
  /// frozen widget underneath — a fake success. Instead, bump
  /// [_webCameraAttempt]: [build]'s `KeyedSubtree` key embeds it, so a
  /// changing value forces Flutter to dispose the old
  /// `_ArWebCameraViewState` (releasing whatever half-open stream it held)
  /// and mount a fresh one, whose `initState` re-attempts `getUserMedia()`
  /// — a real retry, ending in either its `onReady` (real success) or
  /// `onError` (a fresh, real failure pill) callback.
  ///
  /// On native, the `masi/ar` channel handler stays registered on the
  /// already-mounted `UiKitView` across retries, so — unlike the very
  /// first call, gated on `onPlatformViewCreated` in [build] — this can
  /// call [_startSession] directly without waiting for another mount.
  void _retryStartSession() {
    if (!ref.read(arAutoTrackingProvider)) {
      // Web: "start" is a one-shot getUserMedia in the camera widget's
      // initState, not a native session. Remount it (bump the KeyedSubtree
      // key) so the permission prompt / camera acquisition is re-attempted.
      if (mounted) {
        setState(() {
          _startError = null;
          _webCameraAttempt++;
        });
      }
      return;
    }
    final photo = _photo;
    final routes = _routes;
    if (photo == null || routes == null || routes.isEmpty) return;
    unawaited(_startSession(photo, routes));
  }

  @override
  void dispose() {
    _alignmentSubscription?.cancel();
    if (_sessionStarted) {
      // Cached fields (see their doc above) — NOT ref.read: by the time
      // dispose() runs, this element is already defunct and any ref.read
      // here would throw a StateError, silently skipping everything after
      // the first such call (this is exactly the bug those fields fix).
      //
      // channel.stop() is the load-bearing call: it releases the native
      // camera/ARKit session, which otherwise leaks across AR-screen entries.
      // _arController.markActive(false) is comparatively low-stakes —
      // arControllerProvider is an app-lifetime singleton (see its doc in
      // ar_controller.dart) that outlives this screen, so skipping it merely
      // leaves ArState.active stale as true until the next _startSession
      // (or _resetArViewState's own reset, if the next AR entry doesn't
      // start a session at all) — never a leaked resource. Still called
      // here (best-effort) so ArState.active reflects reality immediately
      // rather than waiting on the next entry.
      _arChannel.stop();
      _arController.markActive(false);
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return Scaffold(
        appBar: AppBar(title: const Text('AR view')),
        body: const Center(
          key: Key('ar-loading'),
          child: CircularProgressIndicator(),
        ),
      );
    }

    // ref.watch (unlike the ref.read _isArPlatformSupported() helper above,
    // used only from _maybeStartSession) so an override of
    // arSupportedProvider (e.g. in a test) rebuilds this gate.
    if (!ref.watch(arSupportedProvider)) {
      return Scaffold(
        appBar: AppBar(title: const Text('AR view')),
        body: _buildUnsupportedPlaceholder(context),
      );
    }

    final photo = _photo;
    final routes = _routes;
    if (photo == null || routes == null || routes.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: const Text('AR view')),
        body: _buildMissingDataPlaceholder(context),
      );
    }

    // Whether this platform has a continuous (ARKit-style) tracking session
    // — native (iOS) does, web doesn't (see arAutoTrackingProvider's doc in
    // ar_controller.dart). Drives which camera surface to build below, and
    // is forwarded to ArAlignmentStage so it can force web into
    // always-manual alignment.
    final autoTracking = ref.watch(arAutoTrackingProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('AR view')),
      body: ArAlignmentStage(
        cameraView: autoTracking
            ? UiKitView(
                viewType: _kArPlatformViewType,
                creationParamsCodec: const StandardMessageCodec(),
                onPlatformViewCreated: (_) => _maybeStartSession(),
              )
            : KeyedSubtree(
                // Keyed on _webCameraAttempt (see _retryStartSession's doc)
                // so a retry after a failed getUserMedia() forces Flutter
                // to dispose the old _ArWebCameraViewState and mount a
                // fresh one — otherwise (same runtimeType, both keys null)
                // Flutter reuses the existing State and initState (where
                // getUserMedia() is actually called) never re-runs, so a
                // retry would silently never re-attempt camera acquisition.
                key: ValueKey('ar-web-camera-$_webCameraAttempt'),
                child: buildArCameraView(
                  onReady: () {
                    // There's no native `masi/ar` session to sequence a
                    // start call for on web (arChannelProvider resolves to
                    // ArChannel.noop() there) — the live getUserMedia feed
                    // becoming ready IS the AR session starting, so mark
                    // active directly instead of going through
                    // _maybeStartSession/_startSession (which exist purely to
                    // sequence the native channel.start call after the
                    // UiKitView mounts). _sessionStarted is set too so
                    // dispose's markActive(false) still fires symmetrically
                    // when this screen is left.
                    _sessionStarted = true;
                    ref.read(arControllerProvider.notifier).markActive(true);
                  },
                  onError: (message) {
                    if (mounted) setState(() => _startError = message);
                  },
                ),
              ),
        routes: routes,
        refSize: Size(photo.width.toDouble(), photo.height.toDouble()),
        outline: _outline,
        startError: _startError,
        onRetryStart: _startError == null ? null : _retryStartSession,
        autoTracking: autoTracking,
      ),
    );
  }

  Widget _buildUnsupportedPlaceholder(BuildContext context) {
    final colors = MasiColors.of(context);
    return Center(
      child: Column(
        key: const Key('ar-unsupported-placeholder'),
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          MasiIcon('phone_off', size: 72, color: colors.ink3),
          const SizedBox(height: 16),
          Text(
            'AR live view is iOS-only',
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(color: colors.ink2),
          ),
          const SizedBox(height: 16),
          OutlinedButton(
            key: const Key('ar-unsupported-back'),
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Back'),
          ),
        ],
      ),
    );
  }

  Widget _buildMissingDataPlaceholder(BuildContext context) {
    final colors = MasiColors.of(context);
    return Center(
      child: Column(
        key: const Key('ar-missing-data'),
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          MasiIcon('image_off', size: 72, color: colors.ink3),
          const SizedBox(height: 16),
          Text(
            'This wall needs a photo and at least one route before AR '
            'alignment is available',
            textAlign: TextAlign.center,
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(color: colors.ink2),
          ),
          const SizedBox(height: 16),
          OutlinedButton(
            key: const Key('ar-missing-data-back'),
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Back'),
          ),
        ],
      ),
    );
  }
}

/// The platform-agnostic heart of the AR screen: a live camera surface
/// ([cameraView]) with [routes] overlaid on top via [ArOverlayPainter],
/// warped through whichever [Homography] the current alignment mode
/// selects.
///
/// - **Auto mode** ([ArMode.auto], the primary mode): while ARKit is
///   tracking (`arState.latest?.tracking == true` with a non-null
///   `screenCorners`, already EMA-smoothed by `ArController.onAlignment` —
///   see [CornerSmoother]), the homography is solved fresh via
///   [Homography.fromQuad] — mapping the reference photo's 4 corners onto
///   the 4 on-screen corners ARKit reports the tracked anchor at — with
///   confidence derived from `latest.derivedConfidence` (see
///   [ArAlignment.derivedConfidence]), which reflects ARKit's actual
///   tracking-quality state rather than a hardcoded `1.0`. If that solve is
///   degenerate/implausible per [Homography.isDegenerateQuadSolve] (a
///   genuine geometric validity test — e.g. a collinear OR near-collinear
///   corner quad, or any non-finite matrix entry — NOT an exact `==
///   Homography.identity()` comparison, since a wild-but-non-singular solve
///   is never `==` to identity), the last known-good homography is held
///   instead — see [_ArAlignmentStageState._lastGoodHomography] — and the
///   rendered confidence is capped into the low/"searching" band (see
///   `_kHeldFrameConfidenceCap`) regardless of `derivedConfidence`, since
///   the CURRENT frame's alignment was never actually solved. While not yet
///   tracking (no update yet, or the latest update reports `tracking:
///   false`), the homography falls back to a centered "ghost" placement
///   ([Homography.fitInto]) with confidence `0.0`, again with no outline
///   guide.
/// - **Manual mode** ([ArMode.manual], the fallback): the homography comes
///   from [manualAlignProvider], hand-adjustable via the pan/scale/rotate
///   gesture layer shown over the overlay; confidence is pinned to `1.0`
///   (there's nothing to be "unsure" about — the user placed it there).
///   Once locked, rendering switches to the same native-corners path as auto
///   mode (see above), since the native side now owns the pinned world
///   anchor.
///
/// See [ArScreen]'s class doc for why this widget carries no platform
/// checks of its own: [cameraView] is supplied by the caller, so this
/// widget is exactly as testable as any other [ConsumerStatefulWidget].
class ArAlignmentStage extends ConsumerStatefulWidget {
  const ArAlignmentStage({
    super.key,
    required this.cameraView,
    required this.routes,
    required this.refSize,
    this.outline,
    this.startError,
    this.onRetryStart,
    this.autoTracking = true,
  });

  /// The live camera surface to render underneath the overlay. In the real
  /// app this is a `UiKitView`; in tests, any placeholder [Widget] (e.g. a
  /// `Container`) works identically since this widget never inspects it.
  final Widget cameraView;

  /// The wall's routes to overlay, in percent-of-[refSize] space.
  final List<TopoRoute> routes;

  /// The reference photo's pixel dimensions [routes] are relative to.
  final Size refSize;

  /// The reference photo's ghost outline, used as a guided-alignment aid in
  /// unlocked manual mode (see [ArOverlayPainter.outline]). `null` while
  /// extraction hasn't finished (or failed) — the stage simply shows no
  /// ghost yet/at all in that case.
  final ui.Image? outline;

  /// Set (by [ArScreen]) when the native `channel.start` call has thrown —
  /// see #7b. Forwarded to [_ArStatus], which shows a tap-to-retry
  /// affordance instead of its usual mode/tracking readout while non-null.
  final String? startError;

  /// Invoked when the status pill is tapped while [startError] is
  /// non-null. `null` (and thus the pill non-interactive) whenever
  /// [startError] is `null`.
  final VoidCallback? onRetryStart;

  /// Whether this platform has a continuous (ARKit-style) tracking session
  /// to fall back to auto-placement with. Defaults to `true` — the native
  /// (iOS) behavior every existing caller/test relies on — so this widget
  /// stays byte-for-byte behaviorally unchanged wherever it's omitted.
  ///
  /// When `false` (web, via [ArScreen]'s `arAutoTrackingProvider` watch):
  /// there is no native tracking signal to ever fall back on, so alignment
  /// is ALWAYS effectively manual regardless of [ArState.mode] (see
  /// [_ArAlignmentStageState.build]'s `isManual`), locking is a pure-Dart
  /// state flip rather than a native `lockManual` call (see `onToggleLock`),
  /// and [_ArControls] hides the mode-toggle/re-scan FABs (there is no other
  /// mode to toggle to, and nothing to re-scan).
  final bool autoTracking;

  @override
  ConsumerState<ArAlignmentStage> createState() => _ArAlignmentStageState();
}

class _ArAlignmentStageState extends ConsumerState<ArAlignmentStage> {
  /// The most recent NON-degenerate homography `Homography.fromQuad` solved
  /// from ARKit-tracked corners (auto mode, or manual-and-locked). Held so a
  /// transient degenerate/implausible solve (rejected by
  /// [Homography.isDegenerateQuadSolve] — see that method's doc; NOT merely
  /// an exact `== Homography.identity()` collinear-quad sentinel, since a
  /// wild-but-non-singular solve on a near-collinear/oblique quad is never
  /// `==` to identity either) never snaps the overlay to a wild or
  /// implausible placement for a single frame; instead the overlay keeps
  /// rendering at the last known-good placement (at a capped low/
  /// "searching" confidence — see `_kHeldFrameConfidenceCap` — since the
  /// current frame's alignment was never actually solved) until a fresh
  /// non-degenerate solve arrives. Falls back to the centered "ghost" fit
  /// (not identity) if there's no known-good homography yet.
  ///
  /// Deliberately a plain State field, NOT a Riverpod provider: writing it
  /// is a side effect of [build] itself (see below), and mutating a Riverpod
  /// provider synchronously during ANY widget's build trips Riverpod's
  /// "modify a provider while the widget tree was building" guard (see
  /// `_ArScreenState._load`'s doc, elsewhere in this file, for the same
  /// guard referenced from the opposite direction). A plain field has no
  /// such restriction — it's simply memory that survives across this
  /// State's rebuilds, and resets to a clean `null` whenever a brand-new
  /// `ArAlignmentStage` (and thus a brand-new State) is constructed — e.g. a
  /// fresh wall's AR entry, since `ArScreen.build` always constructs a new
  /// one (see `homography.dart`'s math is untouched — this is a
  /// consumer-side guard only, per the A1 AR-stability contract).
  Homography? _lastGoodHomography;

  /// The previous build's `tracking` value, used to detect a true->false
  /// transition (tracking freshly lost) so [_lastGoodHomography] can be
  /// cleared — otherwise a later re-acquisition's first (possibly still-
  /// settling, and thus occasionally degenerate) solve would fall back to a
  /// homography computed from a camera pose from BEFORE the tracking gap,
  /// rather than the safer centered "ghost" fit.
  bool _wasTracking = false;

  /// The previous build's [ArState.mode], used to detect an auto<->manual
  /// mode switch so [_lastGoodHomography] can be cleared. Mirrors
  /// [ArController.setMode]'s own corner-smoother reset (mode change is one
  /// of the three documented `CornerSmoother` discontinuities) — without
  /// this, switching from manual-LOCKED back to auto can re-pin off the same
  /// still-tracked anchor with no intervening `tracking: false`, so a stale
  /// homography from the mode just left would otherwise leak into the new
  /// mode's degenerate-solve fallback. `null` until the first build (a
  /// brand-new [_ArAlignmentStageState] already starts with a clean
  /// [_lastGoodHomography], so there's nothing to clear then).
  ArMode? _lastMode;

  @override
  Widget build(BuildContext context) {
    final arState = ref.watch(arControllerProvider);
    final manualHomography = ref.watch(manualAlignProvider);
    final locked = ref.watch(arLockedProvider);
    // When the "highlight rock" toggle is on AND this session has a
    // route-derived rock box (arState.rockBox — see rock_box.dart), paint
    // that box as a tinted outline over the wall; otherwise pass null (no
    // highlight). See arRockHighlightProvider.
    final highlightRock = ref.watch(arRockHighlightProvider);
    // Web (widget.autoTracking == false) has no continuous tracking session
    // to ever fall back on, so alignment is ALWAYS effectively manual there,
    // regardless of arState.mode (ArState.mode still literally flips
    // between auto/manual on web via ArController.setMode, but nothing in
    // this widget or _ArControls exposes a way back to auto once
    // _resetArViewState has put it in manual — see that method's doc).
    final isManual = !widget.autoTracking || arState.mode == ArMode.manual;
    final latest = arState.latest;
    final tracking = latest?.tracking ?? false;
    if (_lastMode != null && _lastMode != arState.mode) {
      _lastGoodHomography = null;
      _wasTracking = false;
    }
    _lastMode = arState.mode;
    if (_wasTracking && !tracking) {
      _lastGoodHomography = null;
    }
    _wasTracking = tracking;
    // The outline-guide ghost is only useful while the user is actively
    // lining things up by hand in manual mode: auto mode never shows it —
    // when tracked, routes are glued to the wall (nothing to guide); when
    // not yet tracked, the ghost placement isn't something to line up either.
    final showOutline = isManual && !locked;

    return LayoutBuilder(
      builder: (context, constraints) {
        final viewSize = constraints.biggest;
        final fit = Homography.fitInto(widget.refSize, viewSize);
        final manualComposite = manualHomography.multiply(fit);

        Future<void> onToggleLock() async {
          // Defense-in-depth alongside the `ar-lock` FAB's own `active`
          // gate below (#7): the native `masi/ar` handler only exists
          // once the platform view has mounted, so a stray call here
          // before that (or after `active` flips back false, e.g. a
          // rebuild racing a failed retry) must never reach the channel.
          if (!ref.read(arControllerProvider).active) return;
          final currentlyLocked = ref.read(arLockedProvider);
          if (!widget.autoTracking) {
            // Web: there is no native world anchor to pin/release — the
            // `masi/ar` channel is ArChannel.noop() there (see
            // ar_channel_factory.dart) — so locking/unlocking is a pure-Dart
            // state flip, never a channel call.
            if (currentlyLocked) {
              ref.read(arLockedProvider.notifier).toggle();
              return;
            }
            // Mirrors the native fresh-lock reset just below (same
            // discontinuity rationale — see that branch's comment) even
            // though web never actually reports tracked corners: keeps this
            // stage's own _lastGoodHomography/_wasTracking bookkeeping
            // consistent regardless of platform.
            ref.read(arControllerProvider.notifier).resetCornerSmoothing();
            _lastGoodHomography = null;
            _wasTracking = false;
            ref.read(arLockedProvider.notifier).toggle();
            return;
          }
          final channel = ref.read(arChannelProvider);
          if (currentlyLocked) {
            channel.unlockManual();
            ref.read(arLockedProvider.notifier).toggle();
            return;
          }
          final ok = await channel.lockManual(<Offset>[
            manualComposite.warp(Offset.zero),
            manualComposite.warp(Offset(widget.refSize.width, 0)),
            manualComposite.warp(
              Offset(widget.refSize.width, widget.refSize.height),
            ),
            manualComposite.warp(Offset(0, widget.refSize.height)),
          ]);
          if (!context.mounted) return;
          if (ok) {
            // A fresh manual lock is one of the three documented
            // discontinuities for the corner-smoothing filter (see
            // CornerSmoother's class doc) — reset it so the newly-locked
            // world anchor's first corner sample is never blended against
            // whatever came before (e.g. stale auto-mode jitter, or a
            // previous lock).
            ref.read(arControllerProvider.notifier).resetCornerSmoothing();
            // Mirror that same reset onto _lastGoodHomography/_wasTracking:
            // a fresh lock pins a brand-new native world anchor, so a stale
            // homography from whatever this stage last held (e.g. a
            // previous lock, or auto-mode tracking before switching to
            // manual) must never be the fallback for this new lock's first
            // (possibly still-settling) fromQuad solve.
            _lastGoodHomography = null;
            _wasTracking = false;
            ref.read(arLockedProvider.notifier).toggle();
          } else {
            ScaffoldMessenger.maybeOf(context)?.showSnackBar(
              const SnackBar(
                content: Text('Hold steady on the wall, then tap Lock again.'),
                duration: Duration(seconds: 2),
              ),
            );
          }
        }

        final Homography homography;
        final double confidence;
        if (isManual && (!locked || !widget.autoTracking)) {
          // manualHomography starts at identity -> composite starts fitted;
          // every pan/scale/rotate gesture accumulates on top of that fit.
          // The `|| !widget.autoTracking` half keeps web on the manual
          // composite even once locked: unlike native, there's no native
          // world anchor for the native side to take over rendering from
          // (arState.latest never gets a tracked update on web — the
          // channel's alignments() stream is empty, see ArChannel.noop()),
          // so "locked" on web must freeze the manual composite in place
          // rather than falling through to the native-corners branch below,
          // which would otherwise reset the overlay to the fitted ghost.
          homography = manualComposite;
          confidence = 1.0;
        } else {
          // Auto mode OR manual-and-locked (native only): both render from
          // the native world/ARKit-tracked corners — once locked, manual
          // mode's overlay is driven the same way auto's is, since the
          // native side now owns the pinned world anchor.
          final corners = latest?.screenCorners;
          if (tracking && corners != null) {
            // ARKit is tracking: solve the homography that maps the
            // reference photo's 4 corners directly onto the 4 on-screen
            // points ARKit reports the tracked anchor's corners project to
            // this frame (already EMA-smoothed upstream in
            // `ArController.onAlignment`) — no intermediate camera-frame
            // space involved.
            //
            // Ship 1 of the #68 AR overhaul: the SOURCE quad is ALWAYS the
            // full reference-photo rect (the earlier Vision-segmentation
            // crop quad has been removed — it selected PEOPLE instead of the
            // rock; the AR *reference image* itself is the full photo again,
            // and the route-derived rock box (arState.rockBox) is now used
            // only as a highlight, never as this fromQuad source).
            final refCorners = [
              Offset.zero,
              Offset(widget.refSize.width, 0),
              Offset(widget.refSize.width, widget.refSize.height),
              Offset(0, widget.refSize.height),
            ];
            final solved = Homography.fromQuad(refCorners, corners);
            if (Homography.isDegenerateQuadSolve(solved, refCorners, corners)) {
              // Degenerate/implausible solve (see
              // Homography.isDegenerateQuadSolve's doc — this is a genuine
              // geometric validity test, not an exact `== identity()`
              // comparison, so it also catches a wild-but-non-singular
              // solve on a near-collinear/oblique quad) — hold the last
              // known-good homography rather than snapping to a wild or
              // implausible placement for this frame. Never overwrite
              // _lastGoodHomography with a rejected solve — that would
              // poison every subsequent hold-last-good fallback with the
              // same bad placement.
              homography = _lastGoodHomography ?? fit;
              // Honest held-frame confidence (A3): whether we're holding a
              // stale known-good pose or falling back to the generic
              // centered fit (no known-good pose yet), the CURRENT frame's
              // alignment was NOT actually solved this frame — render at a
              // capped low ("searching") confidence rather than the real
              // derived confidence, so a stale/placeholder placement never
              // reads as a solid, fully-trustworthy overlay.
              confidence = min(latest!.derivedConfidence, _kHeldFrameConfidenceCap);
            } else {
              _lastGoodHomography = solved;
              homography = solved;
              confidence = latest!.derivedConfidence;
            }
          } else {
            // Not tracking yet (or no update yet) — show a fitted "ghost"
            // overlay instead of an unwarped, likely off-screen one.
            homography = fit;
            confidence = 0.0;
          }
        }

        // RepaintBoundary: this overlay repaints every alignment frame (a
        // fresh homography warp on every ARKit/manual-gesture update, for
        // the whole life of the AR session) — isolating it into its own
        // compositor layer means those per-frame repaints stay local to
        // this layer instead of forcing the camera view (widget.cameraView
        // -- a real DOM <video> via PlatformView on web, a UiKitView on
        // iOS) and the rest of the Stack to re-composite alongside it every
        // time. Harmless/beneficial on both platforms; painter logic itself
        // is untouched.
        final overlay = RepaintBoundary(
          child: IgnorePointer(
            child: CustomPaint(
              painter: ArOverlayPainter(
                routes: widget.routes,
                refSize: widget.refSize,
                homography: homography,
                palette: kRoutePalette,
                confidence: confidence,
                routeColorResolver: topoRouteColor,
                outline: showOutline ? widget.outline : null,
                rockBox: highlightRock ? arState.rockBox : null,
                rockMask: arState.rockMask,
                cropBox: rockBoxFromRoutes(widget.routes),
              ),
              child: const SizedBox.expand(),
            ),
          ),
        );

        // The drag/pinch/rotate gesture layer only makes sense while the
        // user could still be adjusting alignment by hand: once locked, the
        // routes render frozen (no gesture layer at all) even in manual
        // mode.
        final gestureEnabled = isManual && !locked;

        return Stack(
          fit: StackFit.expand,
          children: [
            widget.cameraView,
            if (gestureEnabled) _ManualGestureLayer(child: overlay) else overlay,
            Positioned(
              top: 12,
              left: 12,
              child: _ArStatus(
                mode: arState.mode,
                locked: locked,
                tracking: tracking,
                trackingState: latest?.trackingState ?? ArTrackingState.normal,
                limitedReason: latest?.limitedReason,
                error: widget.startError,
                onRetry: widget.onRetryStart,
                autoTracking: widget.autoTracking,
              ),
            ),
            Positioned(
              top: 12,
              right: 12,
              child: _ArControls(
                mode: arState.mode,
                locked: locked,
                active: arState.active,
                onToggleLock: onToggleLock,
                autoTracking: widget.autoTracking,
              ),
            ),
          ],
        );
      },
    );
  }
}

/// A small, always-visible status readout ("Auto"/"Manual" + a one-line
/// hint) floating over the top-left of [ArAlignmentStage], so a first-time
/// user immediately understands what mode they're in and what to do next
/// (rather than having to guess from the two unlabeled FABs in
/// [_ArControls]).
class _ArStatus extends StatelessWidget {
  const _ArStatus({
    required this.mode,
    required this.locked,
    required this.tracking,
    this.trackingState = ArTrackingState.normal,
    this.limitedReason,
    this.error,
    this.onRetry,
    required this.autoTracking,
  });

  final ArMode mode;
  final bool locked;

  /// Whether this platform has a continuous (ARKit-style) tracking session
  /// — see [ArAlignmentStage.autoTracking]'s doc. When `false` (web), the
  /// readout below shows a manual-appropriate "Align by hand"/"Locked"
  /// label instead of the auto-mode tracking/confidence copy, since there
  /// is no native tracking/confidence signal to report there at all.
  final bool autoTracking;

  /// Whether ARKit is currently tracking the reference photo (only
  /// meaningful in [ArMode.auto] — ignored in manual mode).
  final bool tracking;

  /// ARKit's coarse tracking-quality state for the latest alignment (see
  /// [ArAlignment.trackingState]). Defaults to [ArTrackingState.normal] when
  /// there's no alignment yet — matching [ArAlignment]'s own
  /// backward-compatible default.
  final ArTrackingState trackingState;

  /// ARKit's reason for degraded tracking (see [ArAlignment.limitedReason]),
  /// only meaningful when [trackingState] is [ArTrackingState.limited].
  /// Mapped to a short user-facing hint via [_limitedReasonHint] below.
  final String? limitedReason;

  /// Set (via [ArAlignmentStage.startError]) when the native `channel.
  /// start` call has thrown — see #7b. Non-null replaces the usual mode/
  /// tracking readout below with a tap-to-retry affordance.
  final String? error;

  /// Invoked when the pill is tapped while [error] is non-null.
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final colors = MasiColors.of(context);
    final isManual = mode == ArMode.manual;
    final bool isLimited = tracking && trackingState == ArTrackingState.limited;
    final String label;
    final String hint;
    if (error != null) {
      label = "Couldn't start AR";
      hint = 'Tap to retry';
    } else if (!autoTracking) {
      // Web: there is no native tracking/confidence signal to report at
      // all (the channel is ArChannel.noop() — see ar_channel_factory
      // .dart) — this branch takes precedence over every mode-based one
      // below regardless of the literal ArMode, since alignment is always
      // effectively manual there (see ArAlignmentStage's isManual doc).
      label = locked ? 'Locked' : 'Align by hand';
      hint = locked
          ? 'Routes frozen in place'
          : 'Line up the outline with the wall, then Lock';
    } else if (isManual && locked) {
      label = 'Locked';
      hint = tracking
          ? 'Routes anchored to the wall'
          : 'Move slowly to find the wall';
    } else if (!isManual && isLimited) {
      // Real confidence (from ARKit's own trackingState, see
      // ArAlignment.derivedConfidence) has dropped below full — surface
      // WHY, rather than the usual "Tracking" readout implying everything
      // is fine.
      label = 'Limited';
      hint = _limitedReasonHint(limitedReason);
    } else if (!isManual && tracking) {
      label = 'Tracking';
      hint = 'Routes locked to the wall';
    } else if (!isManual) {
      label = 'Auto';
      hint = 'Point at the wall you photographed';
    } else {
      label = 'Manual';
      hint = 'Line up the outline with the wall, then Lock';
    }
    // Reuses the same translucent-glass chrome pattern (MasiColors.chrome
    // fill + kMasiAmbientShadow, via GlassChrome) as the topo canvas's own
    // floating chrome, instead of a hardcoded Colors.black54 pill with raw
    // white text — see the UX finding this addresses.
    //
    // Web exception (kIsWeb): on web, whatever sits beneath this pill is a
    // real DOM <video> rendered via a PlatformView (see
    // ar_camera_view_web.dart's HtmlElementView), not a Flutter-painted
    // layer — the camera feed keeps updating for the entire life of the AR
    // session. GlassChrome's BackdropFilter can't cheaply (or correctly)
    // sample a platform view underneath it, so stacking it directly over
    // that live video forces expensive cross-layer compositing work every
    // single frame. On web this renders the SAME rounded shape, padding,
    // and label/hint text styling as a solid, translucent
    // MasiColors.chrome-tinted box instead — border + boxShadow matched to
    // GlassChrome's own tintedCard so the two stay visually as close as
    // possible; the only real difference is the missing frosted blur (and
    // GlassChrome's extra neutral scrim layer, which only exists to tame a
    // *blurred* backdrop and has nothing to mute here). Native (iOS) keeps
    // calling GlassChrome exactly as before — this branch never runs there.
    final statusContent = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          key: const Key('ar-mode-label'),
          style: TextStyle(color: colors.ink, fontWeight: FontWeight.bold),
        ),
        Text(
          hint,
          key: const Key('ar-hint'),
          style: TextStyle(color: colors.ink2, fontSize: 12),
        ),
      ],
    );
    const pillPadding = EdgeInsets.symmetric(horizontal: 10, vertical: 6);
    final pill = ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 200),
      child: kIsWeb
          ? Container(
              padding: pillPadding,
              decoration: BoxDecoration(
                color: colors.chrome,
                borderRadius: BorderRadius.circular(MasiRadii.large),
                border: Border.all(color: colors.separator),
                boxShadow: kMasiAmbientShadow,
              ),
              child: statusContent,
            )
          : GlassChrome(padding: pillPadding, child: statusContent),
    );
    if (onRetry == null) return pill;
    return GestureDetector(
      key: const Key('ar-status-retry'),
      onTap: onRetry,
      child: pill,
    );
  }
}

/// Maps a native ARKit `limitedReason` string (see [ArAlignment
/// .limitedReason]) to a short, human status-pill hint. Covers ARKit's
/// actual `ARCamera.TrackingState.Reason` cases (`excessiveMotion`,
/// `insufficientFeatures`, `initializing`, `relocalizing`); anything
/// unrecognized (including `null`, e.g. native sent `trackingState:
/// "limited"` without a reason) falls back to a generic hint rather than
/// showing nothing or a raw ARKit identifier to the user.
String _limitedReasonHint(String? reason) {
  switch (reason) {
    case 'excessiveMotion':
      return 'Move slower';
    case 'insufficientFeatures':
      return 'Need more light';
    case 'initializing':
      return 'Finding the wall';
    case 'relocalizing':
      return 'Relocating — hold steady';
    default:
      return 'Tracking quality is low';
  }
}

/// The "highlight rock" toggle (always shown), the mode toggle (auto-tracking
/// platforms only — see [autoTracking]), "reset alignment" button (unlocked
/// manual mode only), the Lock/Unlock button (manual mode only), and the
/// Re-scan button (auto mode AND auto-tracking platforms only), floating over
/// the top-right of [ArAlignmentStage].
class _ArControls extends ConsumerWidget {
  const _ArControls({
    required this.mode,
    required this.locked,
    required this.active,
    required this.onToggleLock,
    required this.autoTracking,
  });

  final ArMode mode;
  final bool locked;

  /// Mirrors [ArState.active]: whether the native AR session has actually
  /// started (i.e. `ArChannel.start` has succeeded — see `ar_screen.dart`'s
  /// `_startSession`/`markActive`). Every FAB below fires a `masi/ar`
  /// platform-channel call, either directly ([onToggleLock], re-scan) or
  /// indirectly (the mode toggle, via `ArController.setMode`). Firing any
  /// of them before the native `UiKitView` has mounted and registered its
  /// channel handler is silently dropped (`MissingPluginException`) — so
  /// every `onPressed` below is gated to `null` (Flutter's standard
  /// disabled-button look) until [active] flips true. See #7.
  final bool active;

  /// Invoked by the `ar-lock` FAB's `onPressed`. Built by
  /// [ArAlignmentStage.build] (which has access to [viewSize],
  /// [manualHomography]/[fit]/[refSize] needed to compute the lock corners)
  /// rather than reached for directly here.
  ///
  /// `Future<void> Function()` rather than [VoidCallback]: locking now
  /// awaits native's `lockManual` result before flipping [arLockedProvider]
  /// (see [ArAlignmentStage.build]'s `onToggleLock`), so the FAB's
  /// `onPressed` fires it off without awaiting (an `onPressed` is itself a
  /// synchronous [VoidCallback]).
  final Future<void> Function() onToggleLock;

  /// Whether this platform has a continuous (ARKit-style) tracking session
  /// — see [ArAlignmentStage.autoTracking]'s doc. When `false` (web), the
  /// mode-toggle and re-scan FABs below are hidden entirely: there is no
  /// other mode to toggle to (alignment is always manual there) and nothing
  /// for a "re-scan" to mean without a native tracking session.
  final bool autoTracking;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Mirrors ArAlignmentStage.build's own isManual (see that method's
    // doc): web (!autoTracking) is always effectively manual regardless of
    // the literal mode, so the reset/lock FABs below show correctly there
    // even before _resetArViewState has had a chance to flip mode away from
    // ArController's ArMode.auto default.
    final isManual = !autoTracking || mode == ArMode.manual;
    final highlightRock = ref.watch(arRockHighlightProvider);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.only(right: 8),
          child: FloatingActionButton.small(
            key: const Key('ar-highlight-rock-toggle'),
            tooltip: highlightRock
                ? 'Hide the rock highlight'
                : 'Highlight the tracked rock',
            onPressed: active
                ? () => ref.read(arRockHighlightProvider.notifier).toggle()
                : null,
            child: const MasiIcon('boulder'),
          ),
        ),
        if (autoTracking && mode == ArMode.auto)
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FloatingActionButton.small(
              key: const Key('ar-rescan'),
              tooltip: 'Re-scan the wall',
              onPressed: active
                  ? () => ref.read(arChannelProvider).rescan()
                  : null,
              child: const MasiIcon('scan'),
            ),
          ),
        if (isManual && !locked)
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FloatingActionButton.small(
              key: const Key('ar-reset'),
              tooltip: 'Reset alignment',
              onPressed: active
                  ? () => ref.read(manualAlignProvider.notifier).reset()
                  : null,
              child: const MasiIcon('restart'),
            ),
          ),
        if (isManual)
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FloatingActionButton.small(
              key: const Key('ar-lock'),
              tooltip: locked ? 'Unlock alignment' : 'Lock alignment',
              onPressed: active
                  ? () {
                      onToggleLock();
                    }
                  : null,
              child: MasiIcon(locked ? 'lock' : 'lock_open'),
            ),
          ),
        if (autoTracking)
          FloatingActionButton.small(
            key: const Key('ar-mode-toggle'),
            tooltip: isManual
                ? 'Switch to auto alignment'
                : 'Switch to manual alignment',
            onPressed: active
                ? () => ref
                    .read(arControllerProvider.notifier)
                    .setMode(isManual ? ArMode.auto : ArMode.manual)
                : null,
            child: Text(
              isManual ? 'M' : 'A',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w700,
                color: Theme.of(context).colorScheme.onPrimaryContainer,
              ),
            ),
          ),
      ],
    );
  }
}

/// Converts a raw (cumulative-since-gesture-start) [GestureDetector]
/// scale/rotate/pan stream into the incremental per-frame deltas
/// [ManualAlignController.pan]/[scale]/[rotate] expect (each composes its
/// gesture matrix ON TOP of the current state — see that controller's class
/// doc — so feeding it [ScaleUpdateDetails]' cumulative-since-gesture-start
/// `scale`/`rotation` directly would double-apply every frame).
///
/// A single-finger drag also comes through [GestureDetector]'s
/// `onScale*` callbacks (with `scale == 1.0`, `rotation == 0.0`, and
/// `focalPoint` tracking the one pointer) — no separate `onPanUpdate`
/// wiring is needed for plain panning.
class _ManualGestureLayer extends ConsumerStatefulWidget {
  const _ManualGestureLayer({required this.child});

  final Widget child;

  @override
  ConsumerState<_ManualGestureLayer> createState() =>
      _ManualGestureLayerState();
}

class _ManualGestureLayerState extends ConsumerState<_ManualGestureLayer> {
  Offset _lastFocalPoint = Offset.zero;
  double _lastScale = 1.0;
  double _lastRotation = 0.0;

  void _onScaleStart(ScaleStartDetails details) {
    _lastFocalPoint = details.localFocalPoint;
    _lastScale = 1.0;
    _lastRotation = 0.0;
  }

  void _onScaleUpdate(ScaleUpdateDetails details) {
    final manual = ref.read(manualAlignProvider.notifier);
    final focal = details.localFocalPoint;

    final panDelta = focal - _lastFocalPoint;
    if (panDelta != Offset.zero) {
      manual.pan(panDelta);
    }

    final scaleDelta = details.scale / _lastScale;
    if (scaleDelta != 1.0) {
      manual.scale(scaleDelta, focal);
    }

    final rotationDelta = details.rotation - _lastRotation;
    if (rotationDelta != 0.0) {
      manual.rotate(rotationDelta, focal);
    }

    _lastFocalPoint = focal;
    _lastScale = details.scale;
    _lastRotation = details.rotation;
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      key: const Key('ar-manual-gesture-layer'),
      behavior: HitTestBehavior.translucent,
      onScaleStart: _onScaleStart,
      onScaleUpdate: _onScaleUpdate,
      child: widget.child,
    );
  }
}
