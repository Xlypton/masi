import 'package:drift/drift.dart' show Variable;
import 'package:flutter/foundation.dart' show setEquals;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/db/database_provider.dart';
import '../../../core/grades/grade_system.dart';
import '../../../shared/filtering/grade_range.dart';
import '../../account/application/auth_providers.dart';
import '../data/ascents_repository.dart';

/// Display-ready row for the personal Logbook screen (see `LogbookScreen`):
/// an [Ascent] joined with its route's number/name/grade and its wall's
/// name.
///
/// Resolved via a single raw-SQL join (mirrors
/// `LibraryCrudRepository.watchTopos`'s pattern), NOT via
/// `ascentsRepositoryProvider.watchLogbook()` composed with a per-ascent
/// async route/wall lookup: an `asyncMap` chained onto a Drift watch stream
/// is documented (see `watchTopos`'s doc comment in
/// `library_crud_repository.dart`) to wedge the resulting `StreamProvider`
/// under `flutter_test`'s fake clock, hanging any widget test's
/// `pumpAndSettle` forever. A single synchronous mapping pass over one join
/// query sidesteps that entirely and avoids per-row loading states.
class LogbookEntry {
  const LogbookEntry({
    required this.ascentId,
    required this.climbedAt,
    required this.style,
    required this.wallName,
    this.routeNumber,
    this.routeName,
    this.gradeLabel,
    this.gradeBand,
    this.gradeSortKey,
    this.routeStyle,
  });

  final String ascentId;
  final DateTime climbedAt;
  final AscentStyle style;
  final String wallName;

  /// Null only if the route this ascent was logged against can no longer be
  /// joined (data-integrity edge case; the FK is enforced at insert time, so
  /// this should not happen in practice).
  final int? routeNumber;
  final String? routeName;

  /// The route's display grade label ([db.Route.gradeRaw] in
  /// `library_crud_repository.dart`'s terms), or `null` if the route has no
  /// grade set.
  final String? gradeLabel;

  /// [GradeBand] derived from the route's `gradeSortKey` via
  /// [bandForSortKey], always non-null exactly when [gradeLabel] is.
  final GradeBand? gradeBand;

  /// The route's raw numeric `gradeSortKey` (see `core/grades/grade_system.dart`),
  /// always non-null exactly when [gradeBand]/[gradeLabel] are. Exposed
  /// separately (rather than only the derived [gradeBand]) so
  /// `GradeRange.matchesSortKey` — an exact numeric range check — can be
  /// applied to a Logbook entry by `LogbookFilter.matches`.
  final double? gradeSortKey;

  /// The route's free-form style (`'sport'`/`'trad'`/`'boulder'`, see
  /// `TopoRoute.style`), normalized via trim+lowercase for exact-match
  /// filtering against [styleFilterOptions][style_filter_chips.dart]'s
  /// values. Null if the route has no style set OR its stored value is
  /// blank/whitespace-only.
  final String? routeStyle;

  @override
  bool operator ==(Object other) =>
      other is LogbookEntry &&
      other.ascentId == ascentId &&
      other.climbedAt == climbedAt &&
      other.style == style &&
      other.wallName == wallName &&
      other.routeNumber == routeNumber &&
      other.routeName == routeName &&
      other.gradeLabel == gradeLabel &&
      other.gradeBand == gradeBand &&
      other.gradeSortKey == gradeSortKey &&
      other.routeStyle == routeStyle;

  @override
  int get hashCode => Object.hash(
    ascentId,
    climbedAt,
    style,
    wallName,
    routeNumber,
    routeName,
    gradeLabel,
    gradeBand,
    gradeSortKey,
    routeStyle,
  );

  @override
  String toString() =>
      'LogbookEntry(ascentId: $ascentId, climbedAt: $climbedAt, '
      'style: $style, wallName: $wallName, routeNumber: $routeNumber, '
      'routeName: $routeName, gradeLabel: $gradeLabel, '
      'gradeBand: $gradeBand, gradeSortKey: $gradeSortKey, '
      'routeStyle: $routeStyle)';
}

/// Normalizes a raw `routes.style` value (e.g. `' Sport '`) into the
/// trimmed-lowercase form `LogbookEntry.routeStyle`/`LogbookFilter` compare
/// against (e.g. `'sport'`), or `null` if [raw] is null or blank.
String? _normalizeRouteStyle(String? raw) {
  if (raw == null) return null;
  final trimmed = raw.trim().toLowerCase();
  return trimmed.isEmpty ? null : trimmed;
}

/// Live, "own" (see `AscentsRepository`'s ownership-scoping doc comment),
/// non-deleted Logbook rows — each an [Ascent] joined with its route's
/// number/name/gradeRaw/gradeSortKey-derived [GradeBand] and its wall's name
/// — newest [LogbookEntry.climbedAt] first (with an `id DESC` tiebreak for
/// deterministic ordering on same-instant ties). Backs `LogbookScreen`.
///
/// Deliberately re-implements the same own+non-deleted+ordering predicate as
/// `AscentsRepository`'s private `_ownQuery` (rather than composing
/// `watchLogbook()` with a per-ascent async route/wall lookup) so the whole
/// row set resolves in one synchronous mapping pass over a single join
/// query — see [LogbookEntry]'s doc for why an async per-row lookup is
/// unsafe here. `currentUid` is read once at provider-build time, matching
/// `_ownQuery`'s own lazy-read-at-query-time behavior.
///
/// A route/wall row that can't be joined (should not happen — both FKs are
/// enforced at insert time) degrades to a `null`/placeholder display value
/// via [LogbookEntry.routeNumber] etc. rather than throwing.
final logbookEntriesProvider = StreamProvider<List<LogbookEntry>>((ref) {
  final database = ref.watch(appDatabaseProvider);
  final uid = ref.watch(currentUidProvider)();
  final ownerClause = uid == null ? 'a.owner_id IS NULL' : 'a.owner_id = ?';
  final sql =
      '''
      SELECT
        a.id AS ascent_id,
        a.climbed_at AS climbed_at,
        a.style AS ascent_style,
        r.number AS route_number,
        r.name AS route_name,
        r.grade_raw AS grade_raw,
        r.grade_sort_key AS grade_sort_key,
        r.style AS route_style,
        w.name AS wall_name
      FROM ascents a
      LEFT JOIN routes r ON r.id = a.route_id
      LEFT JOIN walls w ON w.id = a.wall_id
      WHERE a.deleted_at IS NULL AND $ownerClause
      ORDER BY a.climbed_at DESC, a.id DESC
      ''';
  final variables = uid == null
      ? const <Variable>[]
      : [Variable<String>(uid)];
  return database
      .customSelect(
        sql,
        variables: variables,
        readsFrom: {database.ascents, database.routes, database.walls},
      )
      .watch()
      .map((rows) {
        return [
          for (final row in rows)
            () {
              final gradeSortKey = row.readNullable<double>('grade_sort_key');
              return LogbookEntry(
                ascentId: row.read<String>('ascent_id'),
                climbedAt: DateTime.fromMillisecondsSinceEpoch(
                  row.read<int>('climbed_at'),
                  isUtc: true,
                ),
                style: AscentStyle.fromDbString(
                  row.read<String>('ascent_style'),
                ),
                wallName: row.readNullable<String>('wall_name') ?? 'Wall',
                routeNumber: row.readNullable<int>('route_number'),
                routeName: row.readNullable<String>('route_name'),
                gradeLabel: row.readNullable<String>('grade_raw'),
                gradeBand: gradeSortKey == null
                    ? null
                    : bandForSortKey(gradeSortKey),
                gradeSortKey: gradeSortKey,
                routeStyle: _normalizeRouteStyle(
                  row.readNullable<String>('route_style'),
                ),
              );
            }(),
        ];
      });
});

/// Filter state for the Logbook screen: three independent, AND-combined
/// facets over [LogbookEntry] — a grade range, a set of route styles
/// (`'sport'`/`'trad'`/`'boulder'`, see `style_filter_chips.dart`), and a set
/// of [AscentStyle]s (see `ascent_type_filter_chips.dart`). Each facet is
/// inactive (matches everything) when empty/default — see [isActive] and
/// [matches].
class LogbookFilter {
  const LogbookFilter({
    this.grade = const GradeRange(),
    this.routeStyles = const {},
    this.ascentTypes = const {},
  });

  final GradeRange grade;
  final Set<String> routeStyles;
  final Set<AscentStyle> ascentTypes;

  /// Whether any facet is currently constraining the list — drives the
  /// Logbook screen's filter-icon active indicator.
  bool get isActive =>
      grade.isActive || routeStyles.isNotEmpty || ascentTypes.isNotEmpty;

  /// Whether [entry] satisfies every active facet (AND semantics); an
  /// inactive facet matches everything, including a null
  /// [LogbookEntry.gradeSortKey]/[LogbookEntry.routeStyle] (see
  /// [GradeRange.matchesSortKey]'s doc for the grade facet's null-handling,
  /// which this mirrors for route style: an active style filter excludes an
  /// unstyled entry, since it can't be known to belong to a selected style).
  bool matches(LogbookEntry entry) {
    if (grade.isActive && !grade.matchesSortKey(entry.gradeSortKey)) {
      return false;
    }
    if (routeStyles.isNotEmpty && !routeStyles.contains(entry.routeStyle)) {
      return false;
    }
    if (ascentTypes.isNotEmpty && !ascentTypes.contains(entry.style)) {
      return false;
    }
    return true;
  }

  LogbookFilter copyWith({
    GradeRange? grade,
    Set<String>? routeStyles,
    Set<AscentStyle>? ascentTypes,
  }) {
    return LogbookFilter(
      grade: grade ?? this.grade,
      routeStyles: routeStyles ?? this.routeStyles,
      ascentTypes: ascentTypes ?? this.ascentTypes,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is LogbookFilter &&
          other.grade == grade &&
          setEquals(other.routeStyles, routeStyles) &&
          setEquals(other.ascentTypes, ascentTypes));

  @override
  int get hashCode => Object.hash(
    grade,
    Object.hashAllUnordered(routeStyles),
    Object.hashAllUnordered(ascentTypes),
  );

  @override
  String toString() =>
      'LogbookFilter(grade: $grade, routeStyles: $routeStyles, '
      'ascentTypes: $ascentTypes)';
}

/// Holds the Logbook screen's live [LogbookFilter], reset to the inactive
/// default on every app start (deliberately not persisted — mirrors this
/// screen's other ephemeral UI state; revisit if users ask for filters to
/// survive a restart).
///
/// [setRouteStyles]/[setAscentTypes] each take the FULL new selection set,
/// matching [StyleFilterChips]/[AscentTypeFilterChips]'s controlled
/// `onChanged(Set<...>)` contract — those widgets already compute the
/// toggled set internally and hand back the complete replacement, so this
/// notifier only needs a plain setter, not a single-value toggle.
class LogbookFilterNotifier extends Notifier<LogbookFilter> {
  @override
  LogbookFilter build() => const LogbookFilter();

  void setGrade(GradeRange grade) => state = state.copyWith(grade: grade);

  void setRouteStyles(Set<String> routeStyles) =>
      state = state.copyWith(routeStyles: routeStyles);

  void setAscentTypes(Set<AscentStyle> ascentTypes) =>
      state = state.copyWith(ascentTypes: ascentTypes);

  void clear() => state = const LogbookFilter();
}

final logbookFilterProvider =
    NotifierProvider<LogbookFilterNotifier, LogbookFilter>(
      LogbookFilterNotifier.new,
    );
