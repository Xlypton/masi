import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Per-photo controller behind [rockHighlightControllerProvider]: a plain
/// on/off toggle for the "highlight the rock" overlay button (the
/// `topo-highlight-rock-toggle` button in `topo_canvas_screen.dart`). Its
/// value drives whether `topo_canvas.dart` paints a `RockBoxPainter` box
/// (see `rock_box.dart`'s `rockBoxFromRoutes`) over the active photo.
///
/// Ship 1 of the route-derived rock box (#68) replaced native Vision-based
/// foreground segmentation -- which sometimes selected PEOPLE instead of the
/// rock, see the AR overhaul doc -- with a box derived directly from the
/// routes already drawn on the photo: `rockBoxFromRoutes` is a pure,
/// synchronous function of `DrawState.routes`, so unlike the old
/// segmentation flow there is nothing here to await, cache, or dispose --
/// this controller is just a bool.
///
/// Family-keyed by [photoId] (mirrors `legendExpandedProvider`'s
/// `LegendExpandedController(this.wallId)`), so each photo's highlight
/// toggles independently.
class RockHighlightController extends Notifier<bool> {
  RockHighlightController(this.photoId);

  /// The family key [rockHighlightControllerProvider] was looked up with --
  /// the active photo's id. Kept for instance identity/debugging parity with
  /// `LegendExpandedController.wallId`.
  final String photoId;

  @override
  bool build() => false;

  /// Flips the highlight for this photo on/off.
  void toggle() => state = !state;
}

/// Per-photo rock-highlight on/off state. `autoDispose.family` keyed by
/// photoId, mirroring `legendExpandedProvider` -- each photo tracks its own
/// toggle independently, and it resets once no widget is watching this
/// photo's highlight anymore.
final rockHighlightControllerProvider = NotifierProvider.autoDispose
    .family<RockHighlightController, bool, String>(
      RockHighlightController.new,
    );
