/// Pure, table-driven grade comparison and classification service.
///
/// This file has NO Flutter UI dependency (no `material.dart` /
/// `widgets.dart`) so it can be used from any layer, including tests and
/// non-UI code. Color mapping for [GradeBand] happens later, in the
/// presentation layer.
library;

/// Supported climbing grade systems.
enum GradeSystem { french, uiaa }

/// Coarse difficulty band derived from a [gradeSortKey] value via
/// [bandForSortKey].
enum GradeBand { beginner, intermediate, advanced, hard, elite }

/// The French sport-climbing grade ladder, easiest to hardest.
///
/// This is the exact, documented list (30 tokens). There is no bare `'4'`
/// rung — the historic single-digit grades below 5 are split into
/// `4a`/`4b`/`4c` for consistency with the rest of the ladder; see
/// [bandForSortKey] for how the spec's "French 4" boundary is derived
/// from this.
const List<String> _frenchLadder = [
  '3',
  '4a', '4b', '4c',
  '5a', '5b', '5c',
  '6a', '6a+', '6b', '6b+', '6c', '6c+',
  '7a', '7a+', '7b', '7b+', '7c', '7c+',
  '8a', '8a+', '8b', '8b+', '8c', '8c+',
  '9a', '9a+', '9b', '9b+', '9c',
];

/// The UIAA grade ladder, easiest to hardest.
///
/// Exact, documented list (25 tokens).
const List<String> _uiaaLadder = [
  'III',
  'IV-', 'IV', 'IV+',
  'V-', 'V', 'V+',
  'VI-', 'VI', 'VI+',
  'VII-', 'VII', 'VII+',
  'VIII-', 'VIII', 'VIII+',
  'IX-', 'IX', 'IX+',
  'X-', 'X', 'X+',
  'XI-', 'XI', 'XI+',
];

// --- Shared scale -----------------------------------------------------
//
// The shared axis IS the French ladder's 0-based index: French '3' -> 0.0,
// French '4a' -> 1.0, ... French '9c' -> 29.0.
//
// UIAA is mapped onto that same axis via a single affine (linear)
// transform anchored at two documented, commonly-used correspondences
// between the two systems:
//
//   French 6a (index 7)  <=> UIAA VI+   (index 9)
//   French 7a (index 13) <=> UIAA VIII- (index 13)
//
// slope = (13 - 7) / (13 - 9) = 1.5 shared-scale units per UIAA ladder
// step. Applied to every UIAA index (including outside the anchor
// range, i.e. extrapolated linearly):
//
//   sharedScale(uiaaIndex) = 7 + 1.5 * (uiaaIndex - 9)
//
// This keeps both ladders strictly increasing on one shared double axis
// and makes the two anchor pairs land on IDENTICAL values (0 tolerance
// needed, though callers should still treat cross-system comparisons
// near anchors with a small epsilon since this is an approximation).

const int _anchorFrenchIndexLow = 7; // '6a'
const int _anchorUiaaIndexLow = 9; // 'VI+'
const int _anchorFrenchIndexHigh = 13; // '7a'
const int _anchorUiaaIndexHigh = 13; // 'VIII-'

const double _uiaaSlope =
    (_anchorFrenchIndexHigh - _anchorFrenchIndexLow) /
        (_anchorUiaaIndexHigh - _anchorUiaaIndexLow);

/// Normalizes [raw] for lookup against [system]'s ladder.
///
/// - French: trims whitespace, lowercases (e.g. `'6A'` -> `'6a'`,
///   `' 6a+ '` -> `'6a+'`).
/// - UIAA: trims whitespace, uppercases (e.g. `'vi+'` -> `'VI+'`,
///   `' viii- '` -> `'VIII-'`).
///
/// This does not validate the result — use [isValidGrade] for that.
String normalizeGrade(GradeSystem system, String raw) {
  final trimmed = raw.trim();
  switch (system) {
    case GradeSystem.french:
      return trimmed.toLowerCase();
    case GradeSystem.uiaa:
      return trimmed.toUpperCase();
  }
}

/// Returns the ladder tokens for [system] in ascending (easiest-first)
/// order. See [_frenchLadder] / [_uiaaLadder] for the exact, documented
/// lists.
List<String> gradeOptions(GradeSystem system) {
  switch (system) {
    case GradeSystem.french:
      return List.unmodifiable(_frenchLadder);
    case GradeSystem.uiaa:
      return List.unmodifiable(_uiaaLadder);
  }
}

/// Whether [raw] — after [normalizeGrade] — is a member of [system]'s
/// ladder.
bool isValidGrade(GradeSystem system, String raw) {
  final normalized = normalizeGrade(system, raw);
  return gradeOptions(system).contains(normalized);
}

/// Maps a grade [raw] in [system] onto the shared difficulty scale (see
/// the file-level derivation above).
///
/// [raw] is normalized via [normalizeGrade] before lookup. Both ladders
/// map to strictly increasing values in ladder order, and French/UIAA
/// values are directly comparable to each other on this shared scale.
///
/// Throws [ArgumentError] if [raw] (after normalization) is not a member
/// of [system]'s ladder — callers should check [isValidGrade] first.
double gradeSortKey(GradeSystem system, String raw) {
  final normalized = normalizeGrade(system, raw);
  final ladder = gradeOptions(system);
  final index = ladder.indexOf(normalized);
  if (index == -1) {
    throw ArgumentError.value(raw, 'raw', 'Not a valid $system grade');
  }
  switch (system) {
    case GradeSystem.french:
      return index.toDouble();
    case GradeSystem.uiaa:
      return _anchorFrenchIndexLow +
          _uiaaSlope * (index - _anchorUiaaIndexLow);
  }
}

// --- Bands --------------------------------------------------------------
//
// Spec (expressed on French grades, then converted to shared-scale cut
// points sitting midway between the last token of one band and the
// first token of the next):
//
//   Beginner     <= French 4     (i.e. <= '4c', index 3)
//   Intermediate French 5 - 6a   (indices 4..7)
//   Advanced     French 6a+ - 6c+ (indices 8..12)
//   Hard         French 7a - 7c+  (indices 13..18)
//   Elite        >= French 8a     (index 19..)
//
// The French ladder has no bare '4' token (it is split into 4a/4b/4c),
// so "<= French 4" is interpreted as "<= French 4c" (the hardest grade
// in the "4" tier) — this is the documented choice used throughout this
// file's tests.
//
// Cut points are placed halfway between adjacent tokens' indices so
// each boundary token still falls on the side the spec names it:
const double _beginnerMax = 3.5; // between '4c' (3) and '5a' (4)
const double _intermediateMax = 7.5; // between '6a' (7) and '6a+' (8)
const double _advancedMax = 12.5; // between '6c+' (12) and '7a' (13)
const double _hardMax = 18.5; // between '7c+' (18) and '8a' (19)

/// Classifies a shared-scale [sortKey] (as returned by [gradeSortKey])
/// into a coarse [GradeBand]. See the derivation above for the exact
/// numeric thresholds.
GradeBand bandForSortKey(double sortKey) {
  if (sortKey <= _beginnerMax) return GradeBand.beginner;
  if (sortKey <= _intermediateMax) return GradeBand.intermediate;
  if (sortKey <= _advancedMax) return GradeBand.advanced;
  if (sortKey <= _hardMax) return GradeBand.hard;
  return GradeBand.elite;
}

/// Derives the ordered, deduplicated set of [GradeBand]s spanned by
/// [sortKeys] -- each a shared-scale value as returned by [gradeSortKey]
/// (e.g. `TopoRef.routeGradeKeys`, every live graded route's sort key for a
/// topo). Classifies each key via [bandForSortKey], collapses duplicates
/// (several routes landing in the same band collapse to one entry), and
/// returns the surviving bands in easiest-to-hardest order (mirroring
/// [GradeBand]'s declaration order) regardless of [sortKeys]' own order.
///
/// Used by the Topos-home list row to render one colored dot per distinct
/// difficulty band present on a topo, in place of a single hardest-grade
/// label. Returns an empty list for an empty/no-graded-routes input.
List<GradeBand> gradeBandsFor(List<double> sortKeys) {
  final present = sortKeys.map(bandForSortKey).toSet();
  return GradeBand.values.where(present.contains).toList();
}
