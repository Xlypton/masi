import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:masi/features/backup/data/backup_remote.dart';

/// Covers the `public.backups` row -> [RemoteSnapshot] decode
/// ([remoteSnapshotFromRow]) and the schema.sql/live-schema parity that decode
/// depends on.
///
/// Both halves exist because of the same defect: `fetchSnapshot` used to hard
/// cast `row['schema_version'] as int`, which THROWS on exactly the values the
/// app's own version policy says to allow — while the table it reads was
/// missing from `supabase/schema.sql` entirely, so a fresh project would not
/// even have the column.
void main() {
  /// The two keys every row is guaranteed to carry (the client writes all
  /// four on every upsert), so each test below varies only
  /// `schema_version`.
  Map<String, dynamic> row({
    Map<String, dynamic>? extra,
    Map<String, dynamic> snapshot = const {'tables': <String, dynamic>{}},
  }) => {
    'user_id': 'u1',
    'snapshot': snapshot,
    'updated_at': '2026-08-04T10:00:00.000Z',
    ...?extra,
  };

  group('remoteSnapshotFromRow: schema_version is a CLAIM, not a requirement', () {
    // The policy under test is stated once, in
    // `BackupRepository.assertRestorable` / `SnapshotSchemaDowngradeException`:
    // a version NEWER than this build is refused, a MISSING or non-int one is
    // "no claim was made" and stays importable. `sync_service.dart` calls
    // `importSnapshot` with no version key on every single pull, so treating
    // absence as fatal would break ordinary sync, not just an edge case.
    test('an absent schema_version decodes to null rather than throwing', () {
      final snapshot = remoteSnapshotFromRow(row());

      expect(snapshot.schemaVersion, isNull);
      expect(snapshot.snapshot, {'tables': <String, dynamic>{}});
      expect(snapshot.updatedAt, DateTime.utc(2026, 8, 4, 10));
    });

    test('a SQL NULL schema_version decodes to null rather than throwing', () {
      expect(
        remoteSnapshotFromRow(row(extra: {'schema_version': null}))
            .schemaVersion,
        isNull,
      );
    });

    test(
      'a non-int schema_version decodes to null rather than throwing — the '
      'same "no claim was made" reading assertRestorable applies',
      () {
        // A string is what a `numeric`/`text` column, or a JSON-decoding
        // change, would hand back. The blob's own `schemaVersion` stamp is
        // checked separately and IS a proper JSON int, so nothing is lost by
        // ignoring an unreadable column value here.
        expect(
          remoteSnapshotFromRow(row(extra: {'schema_version': '12'}))
              .schemaVersion,
          isNull,
        );
        expect(
          remoteSnapshotFromRow(row(extra: {'schema_version': 12.5}))
              .schemaVersion,
          isNull,
        );
      },
    );

    test('a real int schema_version is preserved verbatim', () {
      // Load-bearing: the newer-than-build REFUSAL in
      // `CloudBackupService.pullBackup` is driven entirely off this value, so
      // a decode that dropped every version on the floor would be a silent
      // hole in the downgrade guard rather than a fix.
      expect(
        remoteSnapshotFromRow(row(extra: {'schema_version': 12})).schemaVersion,
        12,
      );
    });
  });

  group('supabase/schema.sql declares public.backups', () {
    // Schema drift (a table/column that exists live but not in schema.sql, or
    // vice versa) is this project's recurring bug class — #64/#65/#72. The
    // sibling guard for the row-level sync tables is
    // `test/features/backup/schema_parity_test.dart`; `backups` is not one of
    // those (it is not in `syncTableNames` and its columns are hand-written,
    // not Drift `toJson()` keys), so it needs its own.
    final schemaSql = File('supabase/schema.sql').readAsStringSync();

    test('the CREATE TABLE carries every column the client reads or writes', () {
      final block = RegExp(
        r'CREATE TABLE IF NOT EXISTS public\.backups \(([\s\S]*?)\n\);',
      ).firstMatch(schemaSql);
      expect(
        block,
        isNotNull,
        reason: 'supabase/schema.sql has no CREATE TABLE for public.backups, '
            'so a fresh project provisioned from it would have no backups '
            'table at all and every push/pull would fail.',
      );

      final body = block!.group(1)!;
      // Exactly the four keys `SupabaseBackupRemote.upsertSnapshot` writes and
      // `remoteSnapshotFromRow` reads back.
      for (final column in const [
        'user_id',
        'snapshot',
        'schema_version',
        'updated_at',
      ]) {
        expect(
          RegExp('^\\s*$column\\s+\\S', multiLine: true).hasMatch(body),
          isTrue,
          reason: 'public.backups is missing the "$column" column, which '
              'backup_remote.dart reads or writes on every call.',
        );
      }
    });

    test('row-level security is enabled and scoped to the owner', () {
      // A synced table without RLS is a data leak, and this one is the worst
      // possible case: the blob is the user's ENTIRE library, private topos
      // included.
      expect(
        schemaSql,
        contains('ALTER TABLE public.backups ENABLE ROW LEVEL SECURITY'),
      );
      expect(
        schemaSql,
        contains('CREATE POLICY "backups_owner_all" ON public.backups'),
      );
      expect(
        schemaSql,
        contains('USING (user_id = auth.uid()) WITH CHECK (user_id = auth.uid())'),
      );
    });

    test('the delta migration for already-live projects exists and is idempotent', () {
      final migration = File(
        'supabase/migrations/20260804_backups_table.sql',
      );
      expect(migration.existsSync(), isTrue);

      final sql = migration.readAsStringSync();
      // Every existing migration in this repo is re-runnable; one that is not
      // cannot be safely applied to a live project whose current shape is
      // unknown.
      expect(sql, contains('CREATE TABLE IF NOT EXISTS public.backups'));
      expect(sql, contains('DROP POLICY IF EXISTS "backups_owner_all"'));
      expect(sql, contains('ADD COLUMN IF NOT EXISTS'));
    });
  });
}
