// Pure geometry helpers for slicing a topo image into vertical strips.
//
// This file must remain free of any Flutter UI dependency (no
// `package:flutter/material.dart` or `package:flutter/widgets.dart`) so it
// can be unit tested without the widget bindings and reused from any layer.

/// Tolerance used when comparing/deduping cut positions expressed as
/// fractions of the image width (0.0..1.0). Two cuts within this distance of
/// each other are treated as the same cut, and any slice narrower than this
/// is considered degenerate and dropped.
const double kSliceEpsilon = 1e-6;

/// A single vertical slice of a topo image, expressed as a horizontal crop
/// in percentage-of-width units.
///
/// [cropXpct] is the left edge of the slice (0.0..1.0) and [cropWidthPct] is
/// its width (0.0..1.0), such that `cropXpct + cropWidthPct <= 1.0`.
class SliceSpec {
  final double cropXpct;
  final double cropWidthPct;

  const SliceSpec(this.cropXpct, this.cropWidthPct);

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is SliceSpec &&
        other.cropXpct == cropXpct &&
        other.cropWidthPct == cropWidthPct;
  }

  @override
  int get hashCode => Object.hash(cropXpct, cropWidthPct);

  @override
  String toString() =>
      'SliceSpec(cropXpct: $cropXpct, cropWidthPct: $cropWidthPct)';
}

/// Builds the list of [SliceSpec]s produced by cutting a topo image at the
/// given [cutXs] (fractions of the image width, 0.0..1.0).
///
/// Cuts at or beyond the image boundaries (<= 0 or >= 1), as well as cuts
/// within [kSliceEpsilon] of either boundary, are dropped as non-interior,
/// the remaining cuts are sorted ascending and deduped within
/// [kSliceEpsilon]. The resulting boundaries are `[0.0, ...cleanedCuts,
/// 1.0]`, and each consecutive pair of boundaries becomes one [SliceSpec].
/// Any slice whose width would be <= [kSliceEpsilon] is dropped as
/// degenerate.
///
/// If there are no valid interior cuts, the result is a single slice
/// spanning the whole image: `[SliceSpec(0.0, 1.0)]`.
List<SliceSpec> slicesFromCuts(List<double> cutXs) {
  final interior =
      cutXs.where((x) => x > kSliceEpsilon && x < 1.0 - kSliceEpsilon).toList()
        ..sort();

  final cleaned = <double>[];
  for (final x in interior) {
    if (cleaned.isEmpty || (x - cleaned.last).abs() > kSliceEpsilon) {
      cleaned.add(x);
    }
  }

  final boundaries = <double>[0.0, ...cleaned, 1.0];

  final slices = <SliceSpec>[];
  for (var i = 0; i < boundaries.length - 1; i++) {
    final start = boundaries[i];
    final end = boundaries[i + 1];
    final width = end - start;
    if (width > kSliceEpsilon) {
      slices.add(SliceSpec(start, width));
    }
  }

  if (slices.isEmpty) {
    return [const SliceSpec(0.0, 1.0)];
  }

  return slices;
}
