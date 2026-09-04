import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/config/supabase_providers.dart';
import '../../../core/db/app_database.dart' as db;
import '../../../core/db/database_provider.dart';
import '../../account/application/auth_providers.dart';
import '../data/rock_scan_remote.dart';
import '../data/rock_scan_repository.dart';
import '../domain/rock_scan_status.dart';

/// The [RockScanRepository], wired to the shared database and clock exactly
/// like every other repository provider here.
final rockScanRepositoryProvider = Provider<RockScanRepository>(
  (ref) => RockScanRepository(
    ref.watch(appDatabaseProvider),
    nowMs: ref.watch(nowMsProvider),
    currentUid: ref.watch(currentUidProvider),
  ),
);

/// Network side of the scan feature. Overridden in tests with a fake.
final rockScanRemoteProvider = Provider<RockScanRemote>(
  (ref) => SupabaseRockScanRemote(ref.watch(supabaseClientProvider)),
);

/// Every live scan of a wall, newest first.
final wallScansProvider =
    StreamProvider.family<List<db.RockScanRow>, String>((ref, wallId) {
      return ref.watch(rockScanRepositoryProvider).watchScansForWall(wallId);
    });

/// One scan, watched.
///
/// A stream rather than a one-shot read because the interesting transition
/// happens without any user action: a pull lands the worker's result while
/// the screen is open, and the viewer has to notice.
final rockScanProvider = StreamProvider.family<db.RockScanRow?, String>((
  ref,
  scanId,
) {
  return ref.watch(rockScanRepositoryProvider).watchScan(scanId);
});

/// The reconstructed point cloud's raw bytes for a scan, or `null` when
/// there is nothing to show yet.
///
/// `autoDispose` deliberately: a cloud is measured in megabytes and there is
/// no reason to hold one after the viewer closes. Re-downloading on the next
/// open costs a request; keeping several resident costs the whole app its
/// headroom on a phone.
///
/// Returns `null` rather than throwing for every ordinary "not yet" — no row,
/// no recorded cloud path, or an object that is not there. Only a genuine
/// transport failure propagates as an error, so the viewer can tell "still
/// working" apart from "something broke", which are the two states a user
/// most needs distinguished and the two a bare try/catch would merge.
final rockScanCloudBytesProvider = FutureProvider.autoDispose
    .family<Uint8List?, String>((ref, scanId) async {
      final scan = await ref.watch(rockScanRepositoryProvider).findScan(scanId);
      final objectPath = scan?.cloudObjectPath;
      if (objectPath == null || objectPath.isEmpty) return null;
      return ref.watch(rockScanRemoteProvider).downloadCloud(objectPath);
    });

/// What the capture flow is currently doing. One at a time, deliberately:
/// uploading two 50 MB videos at once from a phone is worse than doing them
/// in sequence, and the UI has nowhere honest to show a second progress
/// indicator.
sealed class RockScanCaptureState {
  const RockScanCaptureState();
}

/// Nothing in flight.
class RockScanCaptureIdle extends RockScanCaptureState {
  const RockScanCaptureIdle();
}

/// A video is being uploaded.
///
/// There is no percentage here on purpose. The Supabase Dart client's
/// `uploadBinary` exposes no progress callback, so any number shown would be
/// invented — and an invented progress bar on a slow phone connection is
/// worse than an honest indeterminate one, because it teaches the user to
/// distrust the real ones.
class RockScanCaptureUploading extends RockScanCaptureState {
  const RockScanCaptureUploading(this.scanId);
  final String scanId;
}

/// The last attempt failed, with a message fit to show a climber.
class RockScanCaptureFailed extends RockScanCaptureState {
  const RockScanCaptureFailed(this.scanId, this.message);
  final String scanId;
  final String message;
}

/// Drives capture: create the row, upload the bytes, record the outcome.
///
/// The row is created BEFORE the upload is attempted, and is left behind when
/// the upload fails. That ordering is the whole design: a scan that exists in
/// a visible failed state can be retried and can be reasoned about, where an
/// upload attempted without a row would vanish on failure with nothing to
/// show the user and nothing for a retry to attach to.
class RockScanCapture extends Notifier<RockScanCaptureState> {
  @override
  RockScanCaptureState build() => const RockScanCaptureIdle();

  /// Creates a scan on [wallId] from [bytes] and uploads it.
  ///
  /// Returns the scan id in every case, failure included — the caller uses it
  /// to navigate to the row that now exists.
  Future<String> capture({
    required String wallId,
    required Uint8List bytes,
    int? durationMs,
  }) async {
    final repository = ref.read(rockScanRepositoryProvider);
    final scanId = await repository.createScan(
      wallId: wallId,
      durationMs: durationMs,
      sizeBytes: bytes.length,
    );

    final uid = ref.read(currentUidProvider)();
    if (uid == null) {
      // Signed out. The row stays, on the device, as `pending` — which is
      // exactly what it is. Not an error state: signing in and retrying is a
      // normal path, and marking it `failed` would imply the capture itself
      // was bad.
      state = const RockScanCaptureIdle();
      return scanId;
    }

    state = RockScanCaptureUploading(scanId);
    await repository.setUploadState(scanId, RockScanUpload.uploading);
    try {
      final objectPath = await ref
          .read(rockScanRemoteProvider)
          .uploadVideo(uid: uid, scanId: scanId, bytes: bytes);
      await repository.setUploadState(
        scanId,
        RockScanUpload.uploaded,
        videoObjectPath: objectPath,
      );
      state = const RockScanCaptureIdle();
    } catch (error) {
      await repository.setUploadState(scanId, RockScanUpload.failed);
      state = RockScanCaptureFailed(scanId, describeScanUploadFailure(error));
    }
    return scanId;
  }

  /// Re-uploads [scanId]'s video from [bytes] after a failure.
  ///
  /// Takes the bytes again rather than reading them back from anywhere: the
  /// video is not stored locally (see the feature's README), so a retry means
  /// re-picking the file. Making that explicit in the signature stops a
  /// caller assuming a retry can happen without one.
  Future<void> retry({
    required String scanId,
    required Uint8List bytes,
  }) async {
    final repository = ref.read(rockScanRepositoryProvider);
    final uid = ref.read(currentUidProvider)();
    if (uid == null) return;

    state = RockScanCaptureUploading(scanId);
    await repository.setUploadState(scanId, RockScanUpload.uploading);
    try {
      final objectPath = await ref
          .read(rockScanRemoteProvider)
          .uploadVideo(uid: uid, scanId: scanId, bytes: bytes);
      await repository.setUploadState(
        scanId,
        RockScanUpload.uploaded,
        videoObjectPath: objectPath,
      );
      state = const RockScanCaptureIdle();
    } catch (error) {
      await repository.setUploadState(scanId, RockScanUpload.failed);
      state = RockScanCaptureFailed(scanId, describeScanUploadFailure(error));
    }
  }

  /// Clears a failure so the banner goes away.
  void dismissError() {
    if (state is RockScanCaptureFailed) state = const RockScanCaptureIdle();
  }
}

final rockScanCaptureProvider =
    NotifierProvider<RockScanCapture, RockScanCaptureState>(
      RockScanCapture.new,
    );

/// Turns an upload exception into something worth showing a climber.
///
/// Kept as a top-level function so it is testable without a container, and
/// deliberately coarse: the useful distinction to a person standing at a crag
/// is "your connection" versus "the file" versus "us", and a finer taxonomy
/// would only produce sentences nobody can act on.
String describeScanUploadFailure(Object error) {
  final text = error.toString().toLowerCase();
  if (text.contains('socket') ||
      text.contains('network') ||
      text.contains('connection') ||
      text.contains('timeout')) {
    return 'Upload failed — check your connection and try again.';
  }
  if (text.contains('exceeded') ||
      text.contains('too large') ||
      text.contains('413')) {
    return 'That video is too large. Try a shorter pass across the face.';
  }
  return 'Upload failed. The video is still on your phone — try again.';
}
