import 'dart:io';

import 'package:masi/core/db/app_database.dart';
import 'package:masi/features/backup/data/sync_remote.dart'
    show syncTableNames;
import 'package:flutter_test/flutter_test.dart';

/// Hardening guard against the bug class where a Drift-synced column has NO
/// matching column in `supabase/schema.sql`.
///
/// `SyncService`'s push (`lib/features/backup/data/sync_service.dart:234-
/// 246`) sends an unfiltered `row.toJson()` for every table in
/// [syncTableNames]. If a `toJson()` key has no matching Supabase column,
/// PostgREST rejects the WHOLE upsert and sync silently breaks — this is
/// exactly what happened with the photos/routes columns. This test parses
/// both sides and asserts `toJsonKeys ⊆ schemaColumns` for every synced
/// table (subset, not equality: Supabase may carry extra server-managed
/// columns, which is fine).
///
/// APPROACH for toJsonKeys: construct each generated Drift Data row class
/// with dummy values for its required (non-nullable, no-default)
/// constructor params and call `.toJson()` — exact (no regex over generated
/// code), and it doubles as a tripwire: a future added NON-nullable column
/// breaks the constructor call below at compile time, while an added
/// nullable column shows up as an extra (null-valued) key that `toJson()`
/// still emits.
void main() {
  // Synchronous file read — no async setUpAll needed, and this must be
  // available before the (also synchronous, top-level) schemaColumnsFor
  // calls below run.
  final schemaSql = File('supabase/schema.sql').readAsStringSync();

  /// Extracts the column-name set of the `CREATE TABLE IF NOT EXISTS
  /// public.<table> ( ... );` block for [table], scoped to just that block
  /// so a same-named column in a different table's block can't leak in.
  ///
  /// A line counts as a column iff, after leading whitespace, it starts
  /// with a quoted identifier followed by a type token
  /// (`^\s*"([A-Za-z0-9_]+)"\s+\S`). This naturally excludes constraint
  /// lines (`PRIMARY KEY (...)`, `CONSTRAINT ...`, `FOREIGN KEY (...)`,
  /// `UNIQUE (...)` — all start unquoted) and the inline
  /// `REFERENCES public.ascents("id")` on e.g. the comments/likes
  /// `"ascentId"` column line — that `"id"` is the REFERENCED table's
  /// column, sitting mid-line, not at the start of a line, so it's never
  /// matched as a column of the CURRENT table.
  Set<String> schemaColumnsFor(String table) {
    final blockMatch = RegExp(
      'CREATE TABLE IF NOT EXISTS public\\.$table \\(([\\s\\S]*?)\\n\\);',
    ).firstMatch(schemaSql);
    // Plain throw, not `expect` — this helper runs at top-level `main()`
    // scope (building the by-table maps below), outside any test body,
    // where `expect()` is illegal (`OutsideTestException`).
    if (blockMatch == null) {
      throw StateError(
        'supabase/schema.sql has no CREATE TABLE for "$table"',
      );
    }
    final body = blockMatch.group(1)!;
    final columnLine = RegExp(r'^\s*"([A-Za-z0-9_]+)"\s+\S');
    return body
        .split('\n')
        .map((line) => columnLine.firstMatch(line)?.group(1))
        .whereType<String>()
        .toSet();
  }

  final schemaColumnsByTable = <String, Set<String>>{
    for (final table in syncTableNames) table: schemaColumnsFor(table),
  };

  // toJson() key sets, one Data-row construction per synced table. Dummy
  // values are throwaway — only the resulting toJson() *key set* matters.
  final toJsonKeysByTable = <String, Set<String>>{
    'profiles': const Profile(
      id: 'u1',
      createdAt: 0,
      updatedAt: 0,
      dirty: false,
    ).toJson().keys.toSet(),
    'areas': const Area(
      id: 'a1',
      createdAt: 0,
      updatedAt: 0,
      dirty: false,
      name: 'n',
    ).toJson().keys.toSet(),
    'sectors': const Sector(
      id: 's1',
      createdAt: 0,
      updatedAt: 0,
      dirty: false,
      areaId: 'a1',
      name: 'n',
      sortOrder: 0,
    ).toJson().keys.toSet(),
    'walls': const Wall(
      id: 'w1',
      createdAt: 0,
      updatedAt: 0,
      dirty: false,
      sectorId: 's1',
      name: 'n',
      sortOrder: 0,
      visibility: 'private',
    ).toJson().keys.toSet(),
    'photos': const Photo(
      id: 'p1',
      createdAt: 0,
      updatedAt: 0,
      dirty: false,
      wallId: 'w1',
      localPath: '/x.jpg',
      kind: 'original',
      width: 1,
      height: 1,
      sortOrder: 0,
      isPrimary: false,
    ).toJson().keys.toSet(),
    'routes': const Route(
      id: 'r1',
      createdAt: 0,
      updatedAt: 0,
      dirty: false,
      wallId: 'w1',
      photoId: 'p1',
      number: 1,
      colorIndex: 0,
      pointsJson: '[]',
      symbolsJson: '[]',
      sortOrder: 0,
      visible: true,
    ).toJson().keys.toSet(),
    'route_lines': const RouteLine(
      id: 'rl1',
      createdAt: 0,
      updatedAt: 0,
      dirty: false,
      routeId: 'r1',
      photoId: 'p1',
      pointsJson: '[]',
      symbolsJson: '[]',
    ).toJson().keys.toSet(),
    'rock_scans': const RockScanRow(
      id: 'scan1',
      createdAt: 0,
      updatedAt: 0,
      dirty: false,
      wallId: 'w1',
      uploadState: 'pending',
      status: 'pending',
    ).toJson().keys.toSet(),
    'ascents': const Ascent(
      id: 'as1',
      createdAt: 0,
      updatedAt: 0,
      dirty: false,
      routeId: 'r1',
      wallId: 'w1',
      climbedAt: 0,
      style: 'redpoint',
      visibility: 'private',
    ).toJson().keys.toSet(),
    'comments': const Comment(
      id: 'c1',
      createdAt: 0,
      updatedAt: 0,
      dirty: false,
      body: 'nice',
    ).toJson().keys.toSet(),
    'likes': const Like(
      id: 'l1',
      createdAt: 0,
      updatedAt: 0,
      dirty: false,
    ).toJson().keys.toSet(),
  };

  test(
    'toJsonKeysByTable covers exactly syncTableNames (no silently-omitted '
    'table)',
    () {
      expect(toJsonKeysByTable.keys.toSet(), syncTableNames.toSet());
      expect(schemaColumnsByTable.keys.toSet(), syncTableNames.toSet());
    },
  );

  for (final table in syncTableNames) {
    test('$table: every toJson() key has a matching schema.sql column', () {
      final schemaColumns = schemaColumnsByTable[table]!;
      final toJsonKeys = toJsonKeysByTable[table]!;

      // Non-vacuous guards: a parser bug returning an empty set (either
      // side) must not let the subset check below pass trivially.
      expect(
        schemaColumns,
        isNotEmpty,
        reason: 'Parsed zero schema.sql columns for "$table" — parser bug?',
      );
      expect(
        toJsonKeys,
        isNotEmpty,
        reason: 'Got zero toJson() keys for "$table" — construction bug?',
      );

      final missing = toJsonKeys.difference(schemaColumns);
      expect(
        missing,
        isEmpty,
        reason:
            'Table "$table": toJson() key(s) $missing have NO matching '
            'column in supabase/schema.sql. SyncService pushes row.toJson() '
            'unfiltered (see sync_service.dart:234-246) — PostgREST will '
            'reject the WHOLE upsert for this table. Add the missing '
            'column(s) to supabase/schema.sql (and apply the migration '
            'live) or remove the field from the Drift table.',
      );
    });
  }
}
