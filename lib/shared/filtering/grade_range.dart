/// Pure filter-domain value type: a min/max grade range over one
/// [GradeSystem]'s ladder (see `core/grades/grade_system.dart`).
///
/// This file has NO Flutter dependency (it only imports the pure
/// grade_system.dart), so it can be shared by any screen's filter
/// state/provider and unit-tested without a widget harness.
library;

import 'package:climbtopo/core/grades/grade_system.dart';

/// Sentinel used by [GradeRange.copyWith] to distinguish "leave this bound
/// unchanged" (the default, when the argument is omitted) from "explicitly
/// set this bound to null" (e.g. the user picks "Any" in a
/// `GradeRangePicker`) -- a bare nullable named parameter can't tell those
/// two cases apart.
class _Unset {
  const _Unset();
}

const Object _unset = _Unset();

/// A grade-range filter: a [system] ladder plus optional [minToken]/
/// [maxToken] tokens from that ladder (as returned by `gradeOptions`).
///
/// Both bounds are optional and independent: only [minToken] set means "at
/// or above this grade"; only [maxToken] set means "at or below this
/// grade"; both null means the filter is inactive and matches everything,
/// including routes with no grade at all (see [isActive]/[matchesSortKey]
/// for the exact contract).
///
/// Normalization: this type does NOT reorder or reject an inverted range
/// (a [minToken] harder than [maxToken]) at construction time -- the
/// constructor stays a trivial `const`. Instead [matchesSortKey] treats the
/// pair as swapped: the smaller of the two sort keys is always the
/// effective lower bound and the larger the effective upper bound. This is
/// the single normalization point for the whole type; [minKey]/[maxKey]
/// still expose the raw, unswapped keys for callers that want to know
/// exactly what the user picked (e.g. a picker widget deciding whether to
/// bump the other bound). The picker widget built on top of this type
/// additionally prevents the inversion from ever being entered in the
/// first place (bumping the other bound on change), so in practice this
/// fallback only matters for callers that construct a [GradeRange]
/// directly with already-inverted tokens.
class GradeRange {
  const GradeRange({
    this.system = GradeSystem.french,
    this.minToken,
    this.maxToken,
  });

  /// The grade ladder these tokens belong to.
  final GradeSystem system;

  /// The lower-bound grade token (inclusive), or null for no lower bound.
  final String? minToken;

  /// The upper-bound grade token (inclusive), or null for no upper bound.
  final String? maxToken;

  /// The raw sort key for [minToken] (via `gradeSortKey`), or null if
  /// [minToken] is unset.
  double? get minKey =>
      minToken == null ? null : gradeSortKey(system, minToken!);

  /// The raw sort key for [maxToken] (via `gradeSortKey`), or null if
  /// [maxToken] is unset.
  double? get maxKey =>
      maxToken == null ? null : gradeSortKey(system, maxToken!);

  /// Whether this filter has any bound set. When false, [matchesSortKey]
  /// matches every key, including a null (ungraded) key.
  bool get isActive => minToken != null || maxToken != null;

  /// The effective lower bound after swap-normalizing an inverted range
  /// (see class doc). The swap only applies when BOTH bounds are set --
  /// when only one bound is set, it constrains its own side and the other
  /// side stays unbounded (null), it never "fills in" the missing bound.
  double? get _effectiveMin {
    final lo = minKey;
    final hi = maxKey;
    if (lo == null || hi == null) return lo;
    return lo <= hi ? lo : hi;
  }

  /// The effective upper bound after swap-normalizing an inverted range
  /// (see class doc). See [_effectiveMin] on why a single set bound never
  /// fills in the other, unset one.
  double? get _effectiveMax {
    final lo = minKey;
    final hi = maxKey;
    if (lo == null || hi == null) return hi;
    return lo <= hi ? hi : lo;
  }

  /// Whether a route with the given [key] (its `gradeSortKey`, or null if
  /// the route is ungraded) satisfies this filter.
  ///
  /// - An inactive filter (no bounds set) matches everything, including a
  ///   null [key].
  /// - An active filter excludes a null [key] -- an ungraded route can't
  ///   be known to fall inside a specific grade range.
  /// - Otherwise [key] must fall within the effective [minKey, maxKey]
  ///   range, inclusive on both ends.
  bool matchesSortKey(double? key) {
    if (!isActive) return true;
    if (key == null) return false;
    final lo = _effectiveMin;
    final hi = _effectiveMax;
    if (lo != null && key < lo) return false;
    if (hi != null && key > hi) return false;
    return true;
  }

  /// Returns a copy with the given fields replaced. [minToken]/[maxToken]
  /// default to a sentinel so passing an explicit `null` (clear the bound)
  /// is distinguishable from omitting the argument (keep the current
  /// value) -- see [_Unset].
  GradeRange copyWith({
    GradeSystem? system,
    Object? minToken = _unset,
    Object? maxToken = _unset,
  }) {
    return GradeRange(
      system: system ?? this.system,
      minToken: identical(minToken, _unset)
          ? this.minToken
          : minToken as String?,
      maxToken: identical(maxToken, _unset)
          ? this.maxToken
          : maxToken as String?,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is GradeRange &&
          other.system == system &&
          other.minToken == minToken &&
          other.maxToken == maxToken);

  @override
  int get hashCode => Object.hash(system, minToken, maxToken);

  @override
  String toString() =>
      'GradeRange(system: $system, minToken: $minToken, maxToken: $maxToken)';
}
