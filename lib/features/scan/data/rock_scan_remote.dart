import 'dart:typed_data';

import 'package:supabase_flutter/supabase_flutter.dart';

/// Storage bucket holding scan source videos and their reconstructions.
///
/// Deliberately NOT `topo-photos`. A scan video is one to two orders of
/// magnitude larger than a photo, and the two have opposite retention
/// stories: the user's photos are irreplaceable and are never evicted
/// (decision D-5), while a source video is regenerable by walking back to the
/// crag. Sharing a bucket would make that distinction a filename convention,
/// and filename conventions are not enforceable.
const String kRockScanBucket = 'rock-scans';

/// Object key of a scan's source video: `<uid>/<scanId>.mp4`.
///
/// The `<uid>/` prefix is load-bearing, not cosmetic — the bucket's RLS
/// policy is `(storage.foldername(name))[1] = auth.uid()::text`, exactly like
/// `topo-photos`. A key built any other way is rejected by the server.
String rockScanVideoObjectPath(String uid, String scanId) =>
    '$uid/$scanId.mp4';

/// Object key of a scan's reconstructed point cloud.
///
/// Written by the worker (as `service_role`, which bypasses RLS), read by the
/// owner through the same prefix policy. The client never uploads here; it
/// only ever reads the path the worker recorded on the row.
String rockScanCloudObjectPath(String uid, String scanId) =>
    '$uid/$scanId/cloud.ply';

/// Everything the scan feature needs from the network, behind one seam.
///
/// Abstract for the same reason `SyncRemote` is: the whole capture and
/// viewing flow is then testable with a fake, against no backend and no
/// network, which is the only way the failure paths (a dead connection
/// mid-upload, a point cloud that 404s) get exercised at all.
abstract class RockScanRemote {
  /// Uploads a scan's source video and returns the object key it landed at.
  ///
  /// Throws on failure — the caller records that as a failed upload on the
  /// row. Deliberately not a nullable return: "it did not work" carries a
  /// reason worth keeping, and swallowing it here would make the message
  /// shown to the user necessarily generic.
  Future<String> uploadVideo({
    required String uid,
    required String scanId,
    required Uint8List bytes,
  });

  /// Downloads a reconstructed point cloud, or `null` when there is nothing
  /// at [objectPath].
  ///
  /// `null` rather than a throw for the missing case specifically, because it
  /// is an ordinary state rather than an error: a row can name a cloud whose
  /// bytes have been pruned, or that a restored backup never had (a snapshot
  /// carries rows, not Storage objects).
  Future<Uint8List?> downloadCloud(String objectPath);
}

/// The real [RockScanRemote], backed by Supabase Storage.
class SupabaseRockScanRemote implements RockScanRemote {
  const SupabaseRockScanRemote(this._client);

  final SupabaseClient _client;

  @override
  Future<String> uploadVideo({
    required String uid,
    required String scanId,
    required Uint8List bytes,
  }) async {
    final objectPath = rockScanVideoObjectPath(uid, scanId);
    await _client.storage
        .from(kRockScanBucket)
        .uploadBinary(
          objectPath,
          bytes,
          // `upsert` so a retry of the SAME scan overwrites its own partial
          // or stale object instead of colliding with it. The scan id is a
          // uuid, so this can never overwrite a different scan.
          fileOptions: const FileOptions(
            upsert: true,
            contentType: 'video/mp4',
          ),
        );
    return objectPath;
  }

  @override
  Future<Uint8List?> downloadCloud(String objectPath) async {
    try {
      return await _client.storage.from(kRockScanBucket).download(objectPath);
    } on StorageException catch (error) {
      // 404 is "not there", which is a state, not a failure — see the
      // interface doc. Anything else is a real error and must not be
      // disguised as an empty result.
      if (error.statusCode == '404' || error.statusCode == '400') return null;
      rethrow;
    }
  }
}
