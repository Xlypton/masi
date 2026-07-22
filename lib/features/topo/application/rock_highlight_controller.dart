import 'dart:ui' as ui;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:masi/features/ar/application/ar_segmentation_channel.dart';

/// UI state for the per-photo "highlight the rock" overlay toggle (the
/// `topo-highlight-rock-toggle` button in `topo_canvas_screen.dart`). Drives
/// whether `RockMaskPainter` paints the segmentation mask over the photo in
/// `topo_canvas.dart`.
///
///  - [enabled]: the user has toggled the highlight ON. The overlay only
///    actually paints when [mask] is also non-null (a "found nothing" /
///    web-noop segmentation leaves [enabled] true but [mask] null — nothing
///    to draw).
///  - [loading]: a one-shot native `segmentPreview` is in flight (first
///    enable for this photo, before any mask is cached).
///  - [mask]: the paint-ready RGBA segmentation image (see
///    `decodeRockMaskAlpha`), or null when off / not-yet-loaded / nothing
///    found. Not owned by the state itself — see
///    [RockHighlightController]'s cache disposal.
class RockHighlightState {
  const RockHighlightState({
    this.enabled = false,
    this.loading = false,
    this.mask,
  });

  final bool enabled;
  final bool loading;
  final ui.Image? mask;
}

/// Per-photo controller behind [rockHighlightControllerProvider]. Owns a
/// one-shot native rock-segmentation pass (via [ArSegmentationChannel
/// .segmentPreview]) and caches its decoded [ui.Image] so re-enabling the
/// highlight after toggling it off is instant (no second native call).
///
/// Family-keyed by [photoId] (mirrors `legendExpandedProvider`'s
/// `LegendExpandedController(this.wallId)`), so each photo gets its own
/// independent highlight state + cached mask.
class RockHighlightController extends Notifier<RockHighlightState> {
  RockHighlightController(this.photoId);

  /// The family key [rockHighlightControllerProvider] was looked up with — the
  /// active photo's id. Kept for instance identity/debugging parity with
  /// `LegendExpandedController.wallId`.
  final String photoId;

  /// The decoded mask, cached across on/off toggles so a re-enable reuses it
  /// instead of re-running native segmentation. Held SEPARATELY from
  /// [RockHighlightState.mask] (which goes null while the overlay is off) so
  /// the cache survives an off toggle. Disposed on provider teardown — it
  /// owns GPU memory (see `decodeRockMaskAlpha`).
  ui.Image? _cachedMask;

  /// Set true once this provider is disposed, so a `segmentPreview` result
  /// resolving after teardown never writes [state] on a dead notifier.
  bool _disposed = false;

  @override
  RockHighlightState build() {
    ref.onDispose(() {
      _disposed = true;
      _cachedMask?.dispose();
      _cachedMask = null;
    });
    return const RockHighlightState();
  }

  /// Toggles the rock highlight for the photo at [imagePath].
  ///
  ///  - Currently ON -> turn OFF (clears the overlay; the decoded mask stays
  ///    cached for a fast re-enable).
  ///  - OFF with a cached mask -> turn ON immediately with the cached mask.
  ///  - OFF with no cached mask -> show the loading state, run a one-shot
  ///    native `segmentPreview`, then turn ON with (and cache) its mask. A
  ///    "found nothing" / web-noop result leaves the highlight enabled with a
  ///    null mask (nothing to paint).
  ///
  /// A `segmentPreview` failure resets to the plain OFF state rather than
  /// leaving the button stuck in [RockHighlightState.loading].
  Future<void> toggle(String imagePath) async {
    if (state.enabled) {
      state = const RockHighlightState();
      return;
    }

    final cached = _cachedMask;
    if (cached != null) {
      state = RockHighlightState(enabled: true, mask: cached);
      return;
    }

    state = const RockHighlightState(loading: true);
    try {
      final result = await ref
          .read(arSegmentationChannelProvider)
          .segmentPreview(imagePath);
      if (_disposed) {
        result.mask?.dispose();
        return;
      }
      _cachedMask = result.mask;
      state = RockHighlightState(enabled: true, mask: result.mask);
    } catch (_) {
      if (_disposed) return;
      state = const RockHighlightState();
    }
  }
}

/// Per-photo rock-highlight state. `autoDispose.family` keyed by photoId,
/// mirroring `legendExpandedProvider` — each photo tracks its own
/// enabled/loading/mask independently, and the cached mask is torn down when
/// no widget is watching this photo's highlight anymore.
final rockHighlightControllerProvider =
    NotifierProvider.autoDispose
        .family<RockHighlightController, RockHighlightState, String>(
      RockHighlightController.new,
    );
