import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../../core/db/app_database.dart' as db;
import '../domain/rock_scan_status.dart';

/// Local reads and writes for rock scans.
///
/// ## It writes the client's half of the row and nothing else
///
/// `RockScans` has two writers (see its table doc): the app owns capture,
/// a reconstruction worker owns the result. Every mutation here touches only
/// client-owned columns. Nothing in this class may set `status`,
/// `progressPct`, `cloudObjectPath`, `manifestJson` or `failureReason` — those
/// arrive by pull and are stripped from every push, so a local write to one
/// would produce a value that looks authoritative on this device, contradicts
/// the server, and silently loses on the next pull.
class RockScanRepository {
  RockScanRepository(this._db, {required this.nowMs, this.currentUid = _noUid});

  final db.AppDatabase _db;

  /// Injected clock, matching every other repository here so tests are not at
  /// the mercy of wall time.
  final int Function() nowMs;

  /// Supabase Auth uid of the signed-in user, read at insert time to stamp
  /// `ownerId` — the column every RLS policy on this table keys on.
  final String? Function() currentUid;

  static String? _noUid() => null;

  static const Uuid _uuid = Uuid();

  /// Creates a scan for [wallId] and returns its id.
  ///
  /// The row starts `uploadState: pending` / `status: pending`: recorded, on
  /// the device, claimed by nobody. Nothing is uploaded here — the caller
  /// drives that and reports back through [markUploading] and friends, so
  /// that a capture and a network round-trip never share a failure path.
  Future<String> createScan({
    required String wallId,
    int? durationMs,
    int? sizeBytes,
  }) async {
    final now = nowMs();
    final id = _uuid.v4();
    await _db
        .into(_db.rockScans)
        .insert(
          db.RockScansCompanion.insert(
            id: id,
            createdAt: now,
            updatedAt: now,
            dirty: const Value(true),
            wallId: wallId,
            ownerId: Value(currentUid()),
            durationMs: Value(durationMs),
            sizeBytes: Value(sizeBytes),
          ),
        );
    return id;
  }

  /// Every live scan of [wallId], newest first, as a live query.
  Stream<List<db.RockScanRow>> watchScansForWall(String wallId) {
    return (_db.select(_db.rockScans)
          ..where((t) => t.wallId.equals(wallId) & t.deletedAt.isNull())
          ..orderBy([(t) => OrderingTerm.desc(t.createdAt)]))
        .watch();
  }

  /// One scan as a live query, or `null` once it is gone. Used by the viewer,
  /// which must react to the worker's result arriving on a pull while the
  /// screen is open — that is the whole "it finished while I was looking at
  /// it" case.
  Stream<db.RockScanRow?> watchScan(String scanId) {
    return (_db.select(
      _db.rockScans,
    )..where((t) => t.id.equals(scanId))).watchSingleOrNull();
  }

  Future<db.RockScanRow?> findScan(String scanId) {
    return (_db.select(
      _db.rockScans,
    )..where((t) => t.id.equals(scanId))).getSingleOrNull();
  }

  /// Moves [scanId] to [state], optionally recording the uploaded object key.
  ///
  /// One method rather than four, because the three things every transition
  /// must do — set the state, bump `updatedAt`, re-dirty the row — are
  /// exactly what a caller forgets when each transition writes its own
  /// update. A row left un-dirtied here never pushes, and with no outbox
  /// there is nothing to notice that it did not.
  Future<void> setUploadState(
    String scanId,
    RockScanUpload state, {
    String? videoObjectPath,
  }) async {
    await (_db.update(_db.rockScans)..where((t) => t.id.equals(scanId))).write(
      db.RockScansCompanion(
        uploadState: Value(state.name),
        // Only ever SET, never cleared: a retry that fails must not erase the
        // key a previous attempt already got onto the server.
        videoObjectPath: videoObjectPath == null
            ? const Value.absent()
            : Value(videoObjectPath),
        updatedAt: Value(nowMs()),
        dirty: const Value(true),
      ),
    );
  }

  /// Soft-deletes [scanId].
  ///
  /// A tombstone rather than a real delete, exactly like every other synced
  /// table here: the row has to reach the other devices as a deletion, and a
  /// vanished row is indistinguishable from one that never synced.
  ///
  /// Note this leaves the Storage objects alone. Reclaiming those belongs to
  /// a sweep that can see the tombstone has actually propagated, not to the
  /// tap that made it.
  Future<void> deleteScan(String scanId) async {
    final now = nowMs();
    await (_db.update(_db.rockScans)..where((t) => t.id.equals(scanId))).write(
      db.RockScansCompanion(
        deletedAt: Value(now),
        updatedAt: Value(now),
        dirty: const Value(true),
      ),
    );
  }
}
