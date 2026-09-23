/// Zoom limits and gesture options shared by every map surface in the app.
///
/// One place, because the two maps (the Map tab and the set-location picker)
/// have to agree, and the failure when one forgets is a crash rather than a
/// style difference.
library;

import 'package:flutter_map/flutter_map.dart';

/// Farthest out a map may zoom. 1 is the whole world, twice over, on a phone.
///
/// Leaving `MapOptions.minZoom` unset lets a pinch-out carry the camera into
/// NEGATIVE zooms, which no tile source serves and nothing in this app needs.
const double kMapMinZoom = 1;

/// Farthest in a map may zoom.
///
/// **Must be set on every `MapOptions`, and this is the bug it fixes.** With
/// `maxZoom` null, flutter_map clamps zoom to `double.infinity`, and its own
/// double-tap-drag ("quick zoom") rule feeds back on itself — see
/// [quickZoomChange]. A drag of a few hundred pixels ran the camera from z11
/// to z74 in half a second and past 10^15 in two, until the projection math
/// hit infinity/NaN and the app went down.
///
/// 20 is well past anything a climber reads a map at (building level). The
/// vector source stops at z14 and overzooms beyond it, so nothing is fetched
/// for the extra levels.
const double kMapMaxZoom = 20;

/// Drag distance, in logical pixels, for one zoom level of quick zoom.
const double kQuickZoomPixelsPerLevel = 100;

/// Zoom change for a double-tap-drag, used in place of flutter_map's default.
///
/// The default is `zoom / 360 * verticalOffset`: it scales by the CURRENT
/// zoom, which that same gesture is changing. flutter_map applies it as
/// `zoomAtStart - change` on every pointer move, so each update grows the next
/// one. Once the finger is more than 360px from where it started, the zoom
/// runs away without limit. [kMapMaxZoom] stops the crash. This makes the
/// gesture behave well: the same drag always means the same number of levels.
double quickZoomChange(double verticalOffset, MapCamera camera) =>
    verticalOffset / kQuickZoomPixelsPerLevel;

/// Interaction options for every map in the app.
///
/// Rotation is off entirely: an accidental two-finger twist must never spin
/// the map. Every other usual pan/zoom gesture stays on; only
/// `InteractiveFlag.rotate` is left out of what would otherwise default to
/// `InteractiveFlag.all`.
const InteractionOptions masiMapInteractionOptions = InteractionOptions(
  flags:
      InteractiveFlag.drag |
      InteractiveFlag.flingAnimation |
      InteractiveFlag.pinchMove |
      InteractiveFlag.pinchZoom |
      InteractiveFlag.doubleTapZoom |
      InteractiveFlag.doubleTapDragZoom |
      InteractiveFlag.scrollWheelZoom,
  doubleTapDragZoomChangeCalculator: quickZoomChange,
);
