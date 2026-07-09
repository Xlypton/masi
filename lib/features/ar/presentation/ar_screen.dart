import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show StandardMessageCodec;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:climbtopo/core/db/database_provider.dart';
import 'package:climbtopo/features/ar/application/ar_channel.dart';
import 'package:climbtopo/features/ar/application/ar_controller.dart';
import 'package:climbtopo/features/ar/application/manual_align_controller.dart';
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

    final hasVisibleRoute = routes.any((r) => r.visible);
    if (photo != null &&
        routes.isNotEmpty &&
        hasVisibleRoute &&
        _isArPlatformSupported()) {
      await _startSession(photo, routes);
    }
  }

  /// Resets the AR view state to a clean per-wall-entry default: every AR
  /// session starts in [ArMode.auto] with [manualAlignProvider] back at
  /// [Homography.identity].
  ///
  /// [arControllerProvider] and [manualAlignProvider] are app-lifetime
  /// singletons — never reset per wall on their own. Without this, opening
  /// wall A's AR, switching to Manual and hand-adjusting the overlay,
  /// backing out, then opening wall B's AR would leave wall B's session
  /// already in Manual mode with wall A's leftover homography warped over
  /// wall B's (completely different) routes/feed.
  ///
  /// [manualAlignProvider]'s reset ([ManualAlignController.reset]) is
  /// always state-only — no native channel involved. [arControllerProvider]
  /// 's mode is only touched via [ArController.setMode] when it isn't
  /// already [ArMode.auto]: `setMode` also fires a (fire-and-forget) native
  /// `setMode` platform-channel call via [arChannelProvider] — harmless on
  /// iOS (or wherever `climbtopo/ar` is mocked, as in this feature's own
  /// tests), but unnecessary work for a mode that's already correct, and a
  /// call this screen has no reason to make on every single entry when
  /// there's nothing to actually reset.
  void _resetArViewState() {
    ref.read(manualAlignProvider.notifier).reset();
    if (ref.read(arControllerProvider).mode != ArMode.auto) {
      ref.read(arControllerProvider.notifier).setMode(ArMode.auto);
    }
  }

  Future<void> _startSession(PhotoRef photo, List<TopoRoute> routes) async {
    _sessionStarted = true;
    final channel = ref.read(arChannelProvider);
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
        cameraView: const UiKitView(
          viewType: _kArPlatformViewType,
          creationParamsCodec: StandardMessageCodec(),
        ),
        routes: routes,
        refSize: Size(photo.width.toDouble(), photo.height.toDouble()),
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
/// - **Auto mode** ([ArMode.auto]): the homography comes from
///   [arControllerProvider]'s [ArState.latest] (the most recent
///   [ArAlignment] pushed from native), falling back to
///   [Homography.identity] before the first update arrives. [ArState
///   .latest]'s confidence drives the overlay's low-confidence treatment.
/// - **Manual mode** ([ArMode.manual]): the homography comes from
///   [manualAlignProvider], hand-adjustable via the pan/scale/rotate
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
  });

  /// The live camera surface to render underneath the overlay. In the real
  /// app this is a `UiKitView`; in tests, any placeholder [Widget] (e.g. a
  /// `Container`) works identically since this widget never inspects it.
  final Widget cameraView;

  /// The wall's routes to overlay, in percent-of-[refSize] space.
  final List<TopoRoute> routes;

  /// The reference photo's pixel dimensions [routes] are relative to.
  final Size refSize;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final arState = ref.watch(arControllerProvider);
    final manualHomography = ref.watch(manualAlignProvider);
    final isManual = arState.mode == ArMode.manual;

    final homography = isManual
        ? manualHomography
        : (arState.latest?.homography ?? Homography.identity());
    final confidence = isManual ? 1.0 : (arState.latest?.confidence ?? 0.0);

    final overlay = IgnorePointer(
      child: CustomPaint(
        painter: ArOverlayPainter(
          routes: routes,
          refSize: refSize,
          homography: homography,
          palette: kRoutePalette,
          confidence: confidence,
          routeColorResolver: topoRouteColor,
        ),
        child: const SizedBox.expand(),
      ),
    );

    return Stack(
      fit: StackFit.expand,
      children: [
        cameraView,
        if (isManual) _ManualGestureLayer(child: overlay) else overlay,
        Positioned(
          top: 12,
          right: 12,
          child: _ArControls(mode: arState.mode),
        ),
      ],
    );
  }
}

/// The mode toggle (always shown) and "reset alignment" button (manual-mode
/// only), floating over the top-right of [ArAlignmentStage].
class _ArControls extends ConsumerWidget {
  const _ArControls({required this.mode});

  final ArMode mode;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isManual = mode == ArMode.manual;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (isManual)
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
        FloatingActionButton.small(
          key: const Key('ar-mode-toggle'),
          tooltip: isManual ? 'Switch to auto alignment' : 'Switch to manual alignment',
          onPressed: () => ref
              .read(arControllerProvider.notifier)
              .setMode(isManual ? ArMode.auto : ArMode.manual),
          child: Icon(isManual ? Icons.pan_tool_alt_outlined : Icons.autorenew),
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
