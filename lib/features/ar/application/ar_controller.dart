import 'dart:ui' as ui;
import 'dart:ui' show Offset;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:masi/core/platform/ar_support.dart';
import 'package:masi/features/ar/application/ar_channel.dart';
import 'package:masi/features/ar/application/ar_channel_factory.dart';
import 'package:masi/features/ar/domain/corner_smoother.dart';

/// Supplies the [ArChannel] used by [ArController] to talk to the native AR
/// platform channel. Overridable in tests (e.g. to inject an [ArChannel]
/// backed by mock/fake `MethodChannel`/`EventChannel` instances). Backed by
/// [createArChannel] so this resolves to a real native-backed [ArChannel]
/// on iOS/Android/desktop and a web-safe [ArChannel.noop] on web (see
/// `ar_channel_factory.dart`) — no code path invokes a real platform channel
/// on a platform that doesn't have a native `masi/ar` handler.
final arChannelProvider = Provider<ArChannel>((ref) => createArChannel());

/// Whether AR is supported on this platform at all (see
/// `ar_support.dart`'s [isArSupported]). Overridable in tests.
final arSupportedProvider = Provider<bool>((ref) => isArSupported());

/// Whether this platform's AR implementation supports continuous
/// (`ArMode.auto`) tracking, as opposed to only a manual/static alignment
/// (see `ar_support.dart`'s [arSupportsAutoTracking]). Overridable in tests.
final arAutoTrackingProvider = Provider<bool>(
  (ref) => arSupportsAutoTracking(),
);

/// The AR feature's UI-facing state: the current [ArMode], the most recent
/// [ArAlignment] pushed from native (or null before the first update), and
/// whether the AR session is currently active (started on native).
class ArState {
  const ArState({
    required this.mode,
    this.latest,
    required this.active,
    this.rockQuadPercent,
    this.rockMask,
  });

  final ArMode mode;
  final ArAlignment? latest;
  final bool active;

  /// The native-reported rock/crop quad from the most recent `channel.start`
  /// result (see `ar_channel.dart`'s `ArChannel.start` doc for the wire
  /// contract): 4 fractional (0..1) corners of the ORIENTED full reference
  /// photo, TL/TR/BR/BL. `null` means either no session has started yet, or
  /// native found no confident segmentation — `ArAlignmentStage` treats both
  /// the same way (fall back to the full-photo rect as the `fromQuad` source
  /// quad). Set via [ArController.setRockSegmentation]; reset to `null` on
  /// every AR-screen re-entry/wall switch (see `ar_screen.dart`'s
  /// `_resetArViewState`) so a prior session's crop can never leak into a
  /// new session that returns none.
  final List<Offset>? rockQuadPercent;

  /// The native-reported per-pixel rock mask from the most recent
  /// `channel.start` result, expanded to a paint-ready [ui.Image] (see
  /// `rock_mask_codec.dart`'s [decodeRockMaskAlpha] / `ar_channel.dart`'s
  /// `ArChannel.start` doc for the wire contract). `null` means either no
  /// session has started yet, or native found no confident segmentation.
  /// Set via [ArController.setRockSegmentation]; reset to `null` on every
  /// AR-screen re-entry/wall switch (see `ar_screen.dart`'s
  /// `_resetArViewState`) alongside [rockQuadPercent], so a prior session's
  /// mask can never leak into a new session that returns none. Surfaced by
  /// the "highlight rock" toggle ([arRockHighlightProvider]) as a glowing
  /// silhouette over the tracked wall.
  final ui.Image? rockMask;

  ArState copyWith({
    ArMode? mode,
    ArAlignment? latest,
    bool? active,
    List<Offset>? rockQuadPercent,
    ui.Image? rockMask,
  }) {
    return ArState(
      mode: mode ?? this.mode,
      latest: latest ?? this.latest,
      active: active ?? this.active,
      rockQuadPercent: rockQuadPercent ?? this.rockQuadPercent,
      rockMask: rockMask ?? this.rockMask,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is ArState &&
        other.mode == mode &&
        other.latest == latest &&
        other.active == active &&
        other.rockMask == rockMask &&
        _quadEqual(other.rockQuadPercent, rockQuadPercent);
  }

  static bool _quadEqual(List<Offset>? a, List<Offset>? b) {
    if (a == null || b == null) return a == b;
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(
    mode,
    latest,
    active,
    rockQuadPercent == null ? null : Object.hashAll(rockQuadPercent!),
    rockMask,
  );

  @override
  String toString() =>
      'ArState(mode: $mode, latest: $latest, active: $active, '
      'rockQuadPercent: $rockQuadPercent, rockMask: $rockMask)';
}

/// Holds [ArState] and mediates mode changes/alignment updates for the AR
/// feature.
///
/// This controller is deliberately thin: it does NOT itself start/stop the
/// native session or subscribe to [ArChannel.alignments] — the AR screen
/// (which owns the widget lifecycle) is responsible for calling
/// [ArChannel.start]/[ArChannel.stop] and forwarding each [ArAlignment] from
/// the stream into [onAlignment]. This keeps the controller synchronously
/// testable without a running platform channel/stream.
class ArController extends Notifier<ArState> {
  /// EMA low-pass filter applied to each incoming alignment's raw
  /// `screenCorners` before they're stored in [state] (see [onAlignment]) —
  /// this is what feeds `Homography.fromQuad` in `ArAlignmentStage`, so
  /// smoothing happens once here rather than being duplicated at every
  /// consumer. A single instance lives for as long as this controller does
  /// (an app-lifetime singleton, like [ArController] itself), reset at each
  /// discontinuity — see [resetCornerSmoothing] and its call sites.
  final CornerSmoother _cornerSmoother = CornerSmoother();

  @override
  ArState build() => const ArState(mode: ArMode.auto, active: false);

  /// Switches the alignment mode: updates [ArState.mode] and forwards the
  /// change to native via [ArChannel.setMode]. Always resets
  /// [arLockedProvider] back to unlocked, so switching modes never leaves a
  /// stale lock from a previous mode's session behind. Also resets the
  /// corner-smoothing filter (an AR mode change is one of the three
  /// documented discontinuities — see [CornerSmoother]'s class doc) so the
  /// new mode's first corner sample is never blended against corners from
  /// the mode just left.
  void setMode(ArMode mode) {
    state = state.copyWith(mode: mode);
    ref.read(arChannelProvider).setMode(mode);
    ref.read(arLockedProvider.notifier).reset();
    _cornerSmoother.reset();
  }

  /// Records the latest alignment update pushed from native (see the AR
  /// screen's subscription to [ArChannel.alignments]), after passing its raw
  /// `screenCorners` (when present) through the EMA [_cornerSmoother] —
  /// [ArState.latest] always holds the SMOOTHED corners, never the raw ones,
  /// so every consumer (`ArAlignmentStage`) gets low-pass-filtered data for
  /// free.
  ///
  /// Resets [_cornerSmoother] whenever this update is NOT a healthy
  /// tracked-with-corners frame (tracking false, or corners absent/
  /// malformed) — this is the "tracking loss" discontinuity from
  /// [CornerSmoother]'s class doc: it guarantees that whenever tracking
  /// later resumes, the filter has no stale pre-loss state left to blend
  /// the newly-reacquired corners against.
  void onAlignment(ArAlignment alignment) {
    final List<Offset>? rawCorners = alignment.screenCorners;
    if (!alignment.tracking || rawCorners == null) {
      _cornerSmoother.reset();
      state = state.copyWith(latest: alignment);
      return;
    }
    final List<Offset> smoothed = _cornerSmoother.smooth(rawCorners);
    state = state.copyWith(
      latest: alignment.copyWith(screenCorners: smoothed),
    );
  }

  /// Marks whether the native AR session is currently active (started).
  void markActive(bool active) {
    state = state.copyWith(active: active);
  }

  /// Records the native-reported rock segmentation from the most recent
  /// `channel.start` result — both the crop [quadPercent] (see
  /// [ArState.rockQuadPercent]) and the per-pixel [mask] (see
  /// [ArState.rockMask]) — or clears BOTH back to `null` (called with no
  /// args by `ar_screen.dart`'s `_resetArViewState` on every AR-screen
  /// re-entry/wall switch).
  ///
  /// Deliberately builds a fresh [ArState] directly rather than through
  /// [ArState.copyWith]: copyWith's `newValue ?? this.field` pattern (the
  /// same idiom every other nullable field on this class uses) can never
  /// null out an already-set field, since passing `null` for [quadPercent]/
  /// [mask] just falls through to the CURRENT value. These two fields
  /// specifically must be resettable to `null` on demand (both together, on
  /// a wall switch, or independently when native returns only one of them),
  /// so they need a real reset path rather than that shared (and, for every
  /// other field, harmless) limitation.
  void setRockSegmentation({List<Offset>? quadPercent, ui.Image? mask}) {
    state = ArState(
      mode: state.mode,
      latest: state.latest,
      active: state.active,
      rockQuadPercent: quadPercent,
      rockMask: mask,
    );
  }

  /// Resets the corner-smoothing filter so the next [onAlignment] call is
  /// treated as a fresh first sample rather than blended against whatever
  /// came before. Called on a fresh manual lock (see `ar_screen.dart`'s
  /// `ArAlignmentStage.onToggleLock`) and on every AR-screen entry (see
  /// `ar_screen.dart`'s `_resetArViewState`) — the third of the three
  /// documented discontinuities ([setMode] and [onAlignment]'s own
  /// tracking-loss handling cover the other two).
  void resetCornerSmoothing() => _cornerSmoother.reset();
}

final arControllerProvider = NotifierProvider<ArController, ArState>(
  ArController.new,
);

/// Whether the manual alignment is currently locked: while locked, the
/// manual pan/scale/rotate gesture layer is hidden (routes render frozen at
/// whatever homography [manualAlignProvider] last held) and the outline-
/// guide ghost overlay is hidden too, since there's nothing left to line up.
///
/// An app-lifetime singleton like [arControllerProvider]/[manualAlignProvider]
/// — reset per AR-screen-entry by [ArLockedController.reset], mirroring how
/// the AR screen resets those other two providers on every wall entry (see
/// `ar_screen.dart`'s `_resetArViewState`).
final arLockedProvider = NotifierProvider<ArLockedController, bool>(
  ArLockedController.new,
);

class ArLockedController extends Notifier<bool> {
  @override
  bool build() => false;

  /// Flips locked <-> unlocked (the Lock/Unlock FAB's action).
  void toggle() => state = !state;

  /// Returns to the unlocked default. Called on every AR-screen entry.
  void reset() => state = false;
}

/// Whether the "highlight rock" overlay is currently on: while on, the AR
/// overlay paints the native-reported rock mask ([ArState.rockMask]) as a
/// flat glowing silhouette over the tracked wall, so the user can see exactly
/// which surface AR segmented the route onto. Defaults to off.
///
/// An app-lifetime singleton mirroring [arLockedProvider] — flipped by the
/// "highlight rock" FAB ([_ArControls]'s `ar-highlight-rock-toggle`).
final arRockHighlightProvider =
    NotifierProvider<ArRockHighlightController, bool>(
      ArRockHighlightController.new,
    );

class ArRockHighlightController extends Notifier<bool> {
  @override
  bool build() => false;

  /// Flips the rock-highlight overlay on <-> off (the highlight FAB's action).
  void toggle() => state = !state;
}
