import 'package:drift/drift.dart' show Variable;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/db/database_provider.dart';
import '../../../core/grades/grade_system.dart';
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
      other.gradeBand == gradeBand;

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
  );

  @override
  String toString() =>
      'LogbookEntry(ascentId: $ascentId, climbedAt: $climbedAt, '
      'style: $style, wallName: $wallName, routeNumber: $routeNumber, '
      'routeName: $routeName, gradeLabel: $gradeLabel, '
      'gradeBand: $gradeBand)';
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
            LogbookEntry(
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
              gradeBand: row.readNullable<double>('grade_sort_key') == null
                  ? null
                  : bandForSortKey(
                      row.readNullable<double>('grade_sort_key')!,
                    ),
            ),
        ];
      });
});
