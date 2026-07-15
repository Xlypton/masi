import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show StandardMessageCodec;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:climbtopo/core/db/database_provider.dart';
import 'package:climbtopo/features/ar/application/ar_channel.dart';
import 'package:climbtopo/features/ar/application/ar_controller.dart';
import 'package:climbtopo/features/ar/application/manual_align_controller.dart';
import 'package:climbtopo/features/ar/application/outline_extractor.dart';
import 'package:climbtopo/features/ar/domain/homography.dart';
import 'package:climbtopo/features/ar/presentation/ar_overlay_painter.dart';
import 'package:climbtopo/features/topo/data/photo_repository.dart';
import 'package:climbtopo/features/topo/domain/topo_route.dart';
import 'package:climbtopo/features/topo/presentation/grade_colors.dart';
import 'package:climbtopo/features/topo/presentation/route_palette.dart';

/// The `PlatformView` type used for the native camera/AR surface on iOS.
/// Kept as a top-level constant string (rather than sprinkled as a literal)
/// so [ArScreen] and any future native-side wiring agree on the exact
/// channel/view-type name.
const String _kArPlatformViewType = 'climbtopo/ar';

/// Encodes [routes] as the `routesJson` payload handed to
/// [ArChannel.start]. Kept intentionally simple (number/colorIndex/
/// visible/points, points as `{x,y}` percent-space pairs) — the native side
/// only needs route geometry to seed its own alignment/rendering, and this
/// screen is the sole producer of this JSON, so there's no shared contract
/// to keep in sync with (unlike `route_mapper.dart`'s DB-column encoding).
String _encodeRoutesForAr(List<TopoRoute> routes) {
  return jsonEncode([
    for (final route in routes)
      {
        'number': route.number,
        'colorIndex': route.colorIndex,
        'visible': route.visible,
        'points': [
          for (final p in route.points) {'x': p.dx, 'y': p.dy},
        ],
      },
  ]);
}

/// Whether the native AR camera view (a `UiKitView`) is available on this
/// platform. Only iOS ships the native implementation; every other platform
/// (Android, web, desktop, and — critically — the platform `flutter test`
/// runs widget tests under) must never attempt to instantiate a
/// `UiKitView`, which would throw.
///
/// `!kIsWeb &&` guards the [Platform] lookup itself: `dart:io`'s [Platform]
/// getters are unsupported when compiled for web.
bool _isArPlatformSupported() => !kIsWeb && Platform.isIOS;

/// The AR live-alignment screen for a wall: overlays that wall's routes
/// (warped through the current camera-alignment [Homography]) on top of a
/// live camera feed.
///
/// ## Testability structure (read this before touching platform-gating code)
///
/// The *only* iOS-gated piece of this screen is the native `UiKitView`
/// camera surface itself. Everything else — the overlay painter, the
/// auto/manual mode toggle, and the manual pan/scale/rotate gesture layer —
/// lives in [ArAlignmentStage], a plain [ConsumerWidget] with NO platform
/// checks of its own. [ArScreen] only ever *constructs* [ArAlignmentStage]
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

  StreamSubscription<ArAlignment>? _alignmentSubscription;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final photo = await ref
        .read(photoRepositoryProvider)
        .loadOriginal(widget.wallId);
    final routes = await ref
        .read(routeRepositoryProvider)
        .loadRoutes(widget.wallId);
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

    // Kick off the ghost-outline extraction without blocking the camera/
    // routes above — they render immediately; the outline (when it
    // succeeds) fades in a moment later via this second setState.
    //
    // Gated on a synchronous existence check first: `extractOutline` spawns
    // a real background isolate (via `compute()`) to read + decode the file,
    // which is real OS-level async work that never completes under a
    // widget test's fake-async pump loop (the same hazard `photo_files.dart`
    // 's `resolvePhotoPath` documents for `File.exists()` vs `existsSync()`)
    // — without this guard, any wall whose persisted photo path doesn't
    // resolve to a real file on THIS host (e.g. a test seeding a placeholder
    // path with no `path_provider` platform fake registered, so
    // `PhotoRepository.loadOriginal` can't resolve it to an absolute path)
    // hangs `tester.pumpAndSettle()` forever trying to spawn+await that
    // isolate. `existsSync()` is a cheap local stat (synchronous, no event-
    // loop turn) so it's safe to call unconditionally; on a real device the
    // photo file genuinely exists, so this never skips real extraction.
    if (photo != null && File(photo.localPath).existsSync()) {
      final outline = await extractOutline(photo.localPath);
      if (!mounted) return;
      setState(() => _outline = outline);
    }
  }

  /// Resets the AR view state to a clean per-wall-entry default: every AR
  /// session starts in [ArMode.auto] (ARKit image-tracking is the primary
  /// alignment mode) with [manualAlignProvider] back at [Homography.identity]
  /// and [arLockedProvider] back to unlocked.
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
  /// iOS (or wherever `climbtopo/ar` is mocked, as in this feature's own
  /// tests), but unnecessary work for a mode that's already correct, and a
  /// call this screen has no reason to make on every single entry when
  /// there's nothing to actually reset.
  ///
  /// Note: this matches [ArController.build]'s own default (also
  /// [ArMode.auto]) — manual remains reachable at any time via the
  /// mode-toggle FAB as a fallback when ARKit tracking isn't available/good
  /// enough.
  void _resetArViewState() {
    ref.read(manualAlignProvider.notifier).reset();
    ref.read(arLockedProvider.notifier).reset();
    if (ref.read(arControllerProvider).mode != ArMode.auto) {
      ref.read(arControllerProvider.notifier).setMode(ArMode.auto);
    }
  }

  /// Kicks off [_startSession] once the native `UiKitView` (and therefore
  /// its `climbtopo/ar` MethodChannel handler) has actually mounted — see
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
    await channel.start(
      referenceImagePath: photo.localPath,
      refWidth: photo.width,
      refHeight: photo.height,
      routesJson: _encodeRoutesForAr(routes),
    );
    if (!mounted) return;
    ref.read(arControllerProvider.notifier).markActive(true);
    _alignmentSubscription = channel.alignments().listen(
      ref.read(arControllerProvider.notifier).onAlignment,
    );
  }

  @override
  void dispose() {
    _alignmentSubscription?.cancel();
    if (_sessionStarted) {
      ref.read(arChannelProvider).stop();
      ref.read(arControllerProvider.notifier).markActive(false);
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

    if (!_isArPlatformSupported()) {
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

    return Scaffold(
      appBar: AppBar(title: const Text('AR view')),
      body: ArAlignmentStage(
        cameraView: UiKitView(
          viewType: _kArPlatformViewType,
          creationParamsCodec: const StandardMessageCodec(),
          onPlatformViewCreated: (_) => _maybeStartSession(),
        ),
        routes: routes,
        refSize: Size(photo.width.toDouble(), photo.height.toDouble()),
        outline: _outline,
      ),
    );
  }

  Widget _buildUnsupportedPlaceholder(BuildContext context) {
    return Center(
      child: Column(
        key: const Key('ar-unsupported-placeholder'),
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.phonelink_off_outlined,
            size: 72,
            color: Theme.of(context).colorScheme.outline,
          ),
          const SizedBox(height: 16),
          Text(
            'AR live view is iOS-only',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              color: Theme.of(context).colorScheme.outline,
            ),
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
    return Center(
      child: Column(
        key: const Key('ar-missing-data'),
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.image_not_supported_outlined,
            size: 72,
            color: Theme.of(context).colorScheme.outline,
          ),
          const SizedBox(height: 16),
          Text(
            'This wall needs a photo and at least one route before AR '
            'alignment is available',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              color: Theme.of(context).colorScheme.outline,
            ),
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
///   `screenCorners`), the homography is solved fresh via
///   [Homography.fromQuad] — mapping the reference photo's 4 corners onto
///   the 4 on-screen corners ARKit reports the tracked anchor at — with
///   confidence pinned to `1.0` (routes are glued to the wall; no outline
///   guide is shown, there's nothing to line up). While not yet tracking (no
///   update yet, or the latest update reports `tracking: false`), the
///   homography falls back to a centered "ghost" placement
///   ([Homography.fitInto]) with confidence `0.0`, again with no outline
///   guide.
/// - **Manual mode** ([ArMode.manual], the fallback): the homography comes
///   from [manualAlignProvider], hand-adjustable via the pan/scale/rotate
///   gesture layer shown over the overlay; confidence is pinned to `1.0`
///   (there's nothing to be "unsure" about — the user placed it there).
///
/// See [ArScreen]'s class doc for why this widget carries no platform
/// checks of its own: [cameraView] is supplied by the caller, so this
/// widget is exactly as testable as any other [ConsumerWidget].
class ArAlignmentStage extends ConsumerWidget {
  const ArAlignmentStage({
    super.key,
    required this.cameraView,
    required this.routes,
    required this.refSize,
    this.outline,
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

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final arState = ref.watch(arControllerProvider);
    final manualHomography = ref.watch(manualAlignProvider);
    final locked = ref.watch(arLockedProvider);
    final isManual = arState.mode == ArMode.manual;
    final latest = arState.latest;
    final tracking = latest?.tracking ?? false;
    // The outline-guide ghost is only useful while the user is actively
    // lining things up by hand in manual mode: auto mode never shows it —
    // when tracked, routes are glued to the wall (nothing to guide); when
    // not yet tracked, the ghost placement isn't something to line up either.
    final showOutline = isManual && !locked;

    return LayoutBuilder(
      builder: (context, constraints) {
        final viewSize = constraints.biggest;
        final fit = Homography.fitInto(refSize, viewSize);
        final manualComposite = manualHomography.multiply(fit);

        Future<void> onToggleLock() async {
          final channel = ref.read(arChannelProvider);
          final currentlyLocked = ref.read(arLockedProvider);
          if (currentlyLocked) {
            channel.unlockManual();
            ref.read(arLockedProvider.notifier).toggle();
            return;
          }
          final ok = await channel.lockManual(<Offset>[
            manualComposite.warp(Offset.zero),
            manualComposite.warp(Offset(refSize.width, 0)),
            manualComposite.warp(Offset(refSize.width, refSize.height)),
            manualComposite.warp(Offset(0, refSize.height)),
          ]);
          if (!context.mounted) return;
          if (ok) {
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
        if (isManual && !locked) {
          // manualHomography starts at identity -> composite starts fitted;
          // every pan/scale/rotate gesture accumulates on top of that fit.
          homography = manualComposite;
          confidence = 1.0;
        } else {
          // Auto mode OR manual-and-locked: both render from the native
          // world/ARKit-tracked corners — once locked, manual mode's
          // overlay is driven the same way auto's is, since the native side
          // now owns the pinned world anchor.
          final corners = latest?.screenCorners;
          if (tracking && corners != null) {
            // ARKit is tracking: solve the homography that maps the
            // reference photo's 4 corners directly onto the 4 on-screen
            // points ARKit reports the tracked anchor's corners project to
            // this frame — no intermediate camera-frame space involved.
            homography = Homography.fromQuad(
              [
                Offset.zero,
                Offset(refSize.width, 0),
                Offset(refSize.width, refSize.height),
                Offset(0, refSize.height),
              ],
              corners,
            );
            confidence = 1.0;
          } else {
            // Not tracking yet (or no update yet) — show a fitted "ghost"
            // overlay instead of an unwarped, likely off-screen one.
            homography = fit;
            confidence = 0.0;
          }
        }

        final overlay = IgnorePointer(
          child: CustomPaint(
            painter: ArOverlayPainter(
              routes: routes,
              refSize: refSize,
              homography: homography,
              palette: kRoutePalette,
              confidence: confidence,
              routeColorResolver: topoRouteColor,
              outline: showOutline ? outline : null,
            ),
            child: const SizedBox.expand(),
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
            cameraView,
            if (gestureEnabled) _ManualGestureLayer(child: overlay) else overlay,
            Positioned(
              top: 12,
              left: 12,
              child: _ArStatus(
                mode: arState.mode,
                locked: locked,
                tracking: tracking,
              ),
            ),
            Positioned(
              top: 12,
              right: 12,
              child: _ArControls(
                mode: arState.mode,
                locked: locked,
                onToggleLock: onToggleLock,
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
  });

  final ArMode mode;
  final bool locked;

  /// Whether ARKit is currently tracking the reference photo (only
  /// meaningful in [ArMode.auto] — ignored in manual mode).
  final bool tracking;

  @override
  Widget build(BuildContext context) {
    final isManual = mode == ArMode.manual;
    final String label;
    final String hint;
    if (isManual && locked) {
      label = 'Locked';
      hint = tracking
          ? 'Routes anchored to the wall'
          : 'Move slowly to find the wall';
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
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 200),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: Colors.black54,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              key: const Key('ar-mode-label'),
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
              ),
            ),
            Text(
              hint,
              key: const Key('ar-hint'),
              style: const TextStyle(color: Colors.white, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}

/// The mode toggle (always shown), "reset alignment" button (unlocked
/// manual mode only), the Lock/Unlock button (manual mode only), and the
/// Re-scan button (auto mode only), floating over the top-right of
/// [ArAlignmentStage].
class _ArControls extends ConsumerWidget {
  const _ArControls({
    required this.mode,
    required this.locked,
    required this.onToggleLock,
  });

  final ArMode mode;
  final bool locked;

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

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isManual = mode == ArMode.manual;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (mode == ArMode.auto)
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FloatingActionButton.small(
              key: const Key('ar-rescan'),
              tooltip: 'Re-scan the wall',
              onPressed: () => ref.read(arChannelProvider).rescan(),
              child: const Icon(Icons.center_focus_strong),
            ),
          ),
        if (isManual && !locked)
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FloatingActionButton.small(
              key: const Key('ar-reset'),
              tooltip: 'Reset alignment',
              onPressed: () =>
                  ref.read(manualAlignProvider.notifier).reset(),
              child: const Icon(Icons.restart_alt),
            ),
          ),
        if (isManual)
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FloatingActionButton.small(
              key: const Key('ar-lock'),
              tooltip: locked ? 'Unlock alignment' : 'Lock alignment',
              onPressed: () {
                onToggleLock();
              },
              child: Icon(locked ? Icons.lock : Icons.lock_outline),
            ),
          ),
        FloatingActionButton.small(
          key: const Key('ar-mode-toggle'),
          tooltip: isManual ? 'Switch to auto alignment' : 'Switch to manual alignment',
          onPressed: () => ref
              .read(arControllerProvider.notifier)
              .setMode(isManual ? ArMode.auto : ArMode.manual),
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
