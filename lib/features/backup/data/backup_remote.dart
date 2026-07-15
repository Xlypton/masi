import 'dart:typed_data';

import 'package:supabase_flutter/supabase_flutter.dart';

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
  final int schemaVersion;
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

    return RemoteSnapshot(
      snapshot: (row['snapshot'] as Map).cast<String, dynamic>(),
      schemaVersion: row['schema_version'] as int,
      updatedAt: DateTime.parse(row['updated_at'] as String),
    );
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

  @override
  Future<Set<String>> listPhotoObjectPaths(String uid) async {
    final files = await _client.storage.from(_bucket).list(path: uid);
    return {for (final file in files) '$uid/${file.name}'};
  }
}
