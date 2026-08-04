import 'dart:typed_data';

import 'package:supabase_flutter/supabase_flutter.dart';

import 'storage_pagination.dart';

/// A cloud-stored backup row for one user: the full snapshot JSON
/// ([BackupRepository.exportSnapshot]'s shape) plus the metadata columns
/// from the `backups` table contract (`schema_version`, `updated_at`).
class RemoteSnapshot {
  const RemoteSnapshot({
    required this.snapshot,
    required this.schemaVersion,
    required this.updatedAt,
  });

  final Map<String, dynamic> snapshot;

  /// The `schema_version` COLUMN's value, or `null` when the row made no
  /// readable claim (the column is absent, SQL `NULL`, or holds something
  /// that is not a Dart `int`).
  ///
  /// Nullable ON PURPOSE, and the policy matches
  /// [BackupRepository.assertRestorable] exactly — the one place in the app
  /// that decides what a version stamp means:
  ///  - a stamp NEWER than this build is refused
  ///    ([SnapshotSchemaDowngradeException]);
  ///  - a MISSING or non-`int` stamp is "no claim was made", which is
  ///    importable.
  ///
  /// This used to be a non-nullable `int` filled by a hard
  /// `row['schema_version'] as int` cast, which threw on exactly the values
  /// the policy says to allow — turning a row that predates the column, or a
  /// column PostgREST decoded as anything but an `int`, into a restore that
  /// fails with a `TypeError` instead of one that simply proceeds. Deciding
  /// the same question two different ways in two files is the drift this
  /// nullability exists to prevent.
  final int? schemaVersion;

  final DateTime updatedAt;
}

/// Seam over the cloud backend the backup engine talks to: one `backups`
/// row per user (`public.backups`, RLS `auth.uid() = user_id`) plus a
/// private `topo-photos` Storage bucket, objects keyed
/// `<uid>/<photoId><ext>` (RLS `(storage.foldername(name))[1] =
/// auth.uid()::text`).
///
/// This is deliberately narrow and free of any Supabase type in its
/// signatures (besides what [RemoteSnapshot] wraps) so tests can supply a
/// pure in-memory fake ([FakeBackupRemote] in
/// `test/features/backup/data/cloud_backup_service_test.dart`) instead of
/// exercising the real network — mirrors how `AuthRepository` isolates
/// Supabase auth in the account feature.
///
/// Every method takes/returns the uid-prefixed convention explicitly (never
/// infers it) so callers — and the RLS policies on the other end — agree on
/// exactly one path shape.
abstract class BackupRemote {
  /// Upserts the `backups` row for [uid] (one row per user, by primary
  /// key), overwriting whatever snapshot/schemaVersion was there before.
  Future<void> upsertSnapshot({
    required String uid,
    required Map<String, dynamic> snapshot,
    required int schemaVersion,
  });

  /// The current `backups` row for [uid], or `null` if this user has never
  /// pushed a backup.
  Future<RemoteSnapshot?> fetchSnapshot(String uid);

  /// Uploads [bytes] to `<uid>/<photoId><ext>` in the `topo-photos` bucket,
  /// overwriting any existing object at that path.
  Future<void> uploadPhoto({
    required String uid,
    required String photoId,
    required String ext,
    required List<int> bytes,
  });

  /// Downloads the object at [objectPath] (already uid-prefixed, e.g.
  /// `<uid>/<photoId><ext>`), or `null` if no such object exists. [uid] is
  /// accepted alongside the already-qualified [objectPath] purely so
  /// implementations can assert the uid-prefix invariant defensively;
  /// callers must still pass the full path.
  Future<List<int>?> downloadPhoto({
    required String uid,
    required String objectPath,
  });

  /// Every object path (uid-prefixed, e.g. `<uid>/<photoId><ext>`) that
  /// currently exists under [uid]'s folder in the `topo-photos` bucket —
  /// used to skip re-uploading a photo that's already there.
  Future<Set<String>> listPhotoObjectPaths(String uid);
}

/// Maps one `public.backups` row, as PostgREST decoded it, onto a
/// [RemoteSnapshot].
///
/// A top-level function rather than an inline expression inside
/// [SupabaseBackupRemote.fetchSnapshot] for one reason: it is the only place
/// the app decodes that row's metadata contract, and it is unit-testable here
/// without a `SupabaseClient` (see `test/features/backup/data/
/// backup_remote_test.dart`) — whereas inside `fetchSnapshot` the only way to
/// exercise it is a real network round trip, which is why the hard
/// `row['schema_version'] as int` cast it replaces was never covered.
RemoteSnapshot remoteSnapshotFromRow(Map<String, dynamic> row) {
  // `is int` rather than `as int`. The test is deliberately IDENTICAL to
  // `BackupRepository.assertRestorable`'s (`declaredVersion is int`), so the
  // two cannot disagree about which values count as a version claim —
  // anything else becomes `null`, i.e. "this row did not say", which
  // `CloudBackupService.pullBackup` then treats as importable rather than
  // fatal. See [RemoteSnapshot.schemaVersion] for why absence must stay
  // importable.
  final declaredVersion = row['schema_version'];
  return RemoteSnapshot(
    snapshot: (row['snapshot'] as Map).cast<String, dynamic>(),
    schemaVersion: declaredVersion is int ? declaredVersion : null,
    updatedAt: DateTime.parse(row['updated_at'] as String),
  );
}

/// Real [BackupRemote], backed by the Supabase client.
///
/// SECURITY: like every other client-side Supabase usage in this app, this
/// only ever touches the publishable/anon [SupabaseClient] — never the
/// privileged/service-role key. Per-user isolation is enforced server-side
/// by RLS (`auth.uid() = user_id` on `backups`, the storage-foldername
/// check on `topo-photos`), not by anything in this class; the uid-prefixed
/// paths here exist so the RLS policies have something to check against,
/// not as the isolation mechanism itself.
class SupabaseBackupRemote implements BackupRemote {
  SupabaseBackupRemote(this._client);

  final SupabaseClient _client;

  static const String _table = 'backups';
  static const String _bucket = 'topo-photos';

  @override
  Future<void> upsertSnapshot({
    required String uid,
    required Map<String, dynamic> snapshot,
    required int schemaVersion,
  }) async {
    await _client.from(_table).upsert({
      'user_id': uid,
      'snapshot': snapshot,
      'schema_version': schemaVersion,
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    });
  }

  @override
  Future<RemoteSnapshot?> fetchSnapshot(String uid) async {
    final row = await _client
        .from(_table)
        .select()
        .eq('user_id', uid)
        .maybeSingle();
    if (row == null) return null;
    return remoteSnapshotFromRow(row);
  }

  @override
  Future<void> uploadPhoto({
    required String uid,
    required String photoId,
    required String ext,
    required List<int> bytes,
  }) async {
    final path = '$uid/$photoId$ext';
    await _client.storage
        .from(_bucket)
        .uploadBinary(
          path,
          Uint8List.fromList(bytes),
          fileOptions: const FileOptions(upsert: true),
        );
  }

  @override
  Future<List<int>?> downloadPhoto({
    required String uid,
    required String objectPath,
  }) async {
    assert(
      objectPath.startsWith('$uid/'),
      'objectPath must be uid-prefixed: $objectPath',
    );
    try {
      return await _client.storage.from(_bucket).download(objectPath);
    } on StorageException {
      // Missing object (or any other storage-side error) — the caller
      // treats this as "skip this file, keep the row" rather than a hard
      // failure.
      return null;
    }
  }

  /// S6: paged, for the identical reason `SupabaseSyncRemote`'s two listings
  /// are — `list()` returns at most 100 objects per request with no signal
  /// that more exist, so an un-paged call truncates the skip-set and makes
  /// [CloudBackupService] re-upload full-resolution bytes already in the
  /// cloud. Fixed here too even though `CloudBackupService` currently has no
  /// caller outside `lib/features/backup/` (decision D-2), because leaving
  /// one of two identical listings unfixed is exactly the divergence risk this
  /// duplication is known for.
  @override
  Future<Set<String>> listPhotoObjectPaths(String uid) async {
    final files = await collectPagedObjects<FileObject>(
      (limit, offset) => _client.storage
          .from(_bucket)
          .list(
            path: uid,
            searchOptions: SearchOptions(limit: limit, offset: offset),
          ),
    );
    return {for (final file in files) '$uid/${file.name}'};
  }
}
