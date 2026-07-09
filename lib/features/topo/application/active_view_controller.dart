import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:climbtopo/features/topo/data/photo_repository.dart';

/// Which photo the topo canvas is currently framed to: either the "original"
/// (unsliced) photo, or one of its persisted slices.
///
/// This is a purely presentational choice — it controls how [TopoCanvas]
/// crops/frames the viewport (see [TopoCanvas.activeCropXpct]/
/// [activeCropWidthPct]) — and is deliberately independent of
/// [DrawState.activePhotoId]/[activeWallId], which always continue to
/// reference the ORIGINAL photo: routes are stored in original-image percent
/// space regardless of which slice is being viewed (see
/// [CoordinateTransformer] class doc), so switching the active view never
/// needs to touch persistence.
class ActiveView {
  const ActiveView({required this.photoId, this.cropXpct, this.cropWidthPct});

  /// The id of the photo row being viewed: the original photo's id when
  /// [isOriginal], or a slice's id otherwise.
  final String photoId;

  /// The left edge of the crop band, as a fraction of the original image's
  /// width, or null when viewing the original (uncropped) photo.
  final double? cropXpct;

  /// The width of the crop band, as a fraction of the original image's
  /// width, or null when viewing the original (uncropped) photo.
  final double? cropWidthPct;

  /// True when this view is the original (uncropped) photo, i.e. no crop
  /// band is active.
  bool get isOriginal => cropXpct == null;

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is ActiveView &&
        other.photoId == photoId &&
        other.cropXpct == cropXpct &&
        other.cropWidthPct == cropWidthPct;
  }

  @override
  int get hashCode => Object.hash(photoId, cropXpct, cropWidthPct);

  @override
  String toString() =>
      'ActiveView(photoId: $photoId, cropXpct: $cropXpct, cropWidthPct: '
      '$cropWidthPct)';
}

/// Holds the currently active [ActiveView] for the topo canvas, or null if
/// nothing has been loaded/selected yet (e.g. before a wall's photo/slices
/// have resolved).
class ActiveViewController extends Notifier<ActiveView?> {
  @override
  ActiveView? build() => null;

  /// Switches to viewing the original (uncropped) photo at [originalPhotoId]
  /// — no crop band.
  void showOriginal(String originalPhotoId) {
    state = ActiveView(photoId: originalPhotoId);
  }

  /// Switches to viewing [slice], framing the canvas to its crop band
  /// (`slice.cropXpct`/`slice.cropWidthPct`).
  void showSlice(PhotoRef slice) {
    state = ActiveView(
      photoId: slice.id,
      cropXpct: slice.cropXpct,
      cropWidthPct: slice.cropWidthPct,
    );
  }

  /// Resets to "nothing loaded" (null) — used when switching away from a
  /// photo entirely (see [TopoCanvasScreen]'s photo-switch handling).
  void clear() {
    state = null;
  }
}

final activeViewProvider =
    NotifierProvider<ActiveViewController, ActiveView?>(
      ActiveViewController.new,
    );
