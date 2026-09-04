/// The two independent state machines a rock scan runs through, and the
/// vocabulary shared by the app, the Supabase row and the reconstruction
/// worker.
///
/// They are deliberately separate enums rather than one merged status,
/// because they have different OWNERS and the sync engine treats them
/// differently — see `RockScans`' table doc. The client drives
/// [RockScanUpload] and pushes it; the worker drives [RockScanStatus] and the
/// client only ever receives it.
///
/// Pure Dart: no Flutter import, so both are usable from the data layer and
/// testable without a widget binding.
library;

/// How far a scan's source video has got toward the cloud. CLIENT-OWNED.
enum RockScanUpload {
  /// Recorded and stored locally; nothing sent yet. Also where a scan lands
  /// when it is created offline at the crag, which is the common case.
  pending,

  /// Bytes are in flight right now.
  uploading,

  /// The whole video is in Storage. This — combined with a `pending`
  /// [RockScanStatus] — is what makes the scan claimable by a worker.
  uploaded,

  /// The upload failed and will be retried. NOT terminal: with no outbox
  /// (decision D-4), the retry is simply the next attempt re-reading the same
  /// local row, which is what makes a lost connection at the crag
  /// self-correcting rather than something needing a queue.
  failed;

  /// Parses the stored/wire string, falling back to [pending].
  ///
  /// Unknown input resolves to [pending] rather than throwing because this
  /// value arrives from a database row that a NEWER build may have written:
  /// an old client meeting a state it has never heard of should offer to
  /// upload again, not crash on the library screen.
  static RockScanUpload fromWire(Object? raw) {
    for (final value in RockScanUpload.values) {
      if (value.name == raw) return value;
    }
    return RockScanUpload.pending;
  }
}

/// How far reconstruction has got. SERVER-OWNED — a client never writes this.
enum RockScanStatus {
  /// No worker has claimed it. Either the video is not up yet, or one is up
  /// and nothing has picked it off the queue.
  pending,

  /// A worker is reconstructing right now.
  processing,

  /// A point cloud exists and can be opened.
  ready,

  /// Reconstruction was attempted and did not produce a usable map. See
  /// `RockScans.failureReason` for the words to show.
  failed;

  /// Parses the stored/wire string, falling back to [pending] — same
  /// forward-compatibility reasoning as [RockScanUpload.fromWire].
  static RockScanStatus fromWire(Object? raw) {
    for (final value in RockScanStatus.values) {
      if (value.name == raw) return value;
    }
    return RockScanStatus.pending;
  }
}

/// What the UI should actually say about a scan, collapsing the two machines
/// above into the one thing a climber cares about.
///
/// The collapse is not symmetric, and the order of the checks below is the
/// whole point: a FAILED UPLOAD outranks a pending reconstruction (the user
/// can act on it — retry), while a finished reconstruction outranks
/// everything (once the map exists, how its bytes got there stopped
/// mattering).
enum RockScanPhase {
  /// Recorded, still on the phone. Actionable: upload it.
  onDevice,

  /// Bytes in flight.
  uploading,

  /// The upload did not complete. Actionable: retry.
  uploadFailed,

  /// Uploaded, waiting for or undergoing reconstruction.
  reconstructing,

  /// There is a point cloud to look at.
  ready,

  /// Reconstruction failed.
  reconstructionFailed;

  /// True when nothing will change without the user doing something.
  bool get needsUser =>
      this == RockScanPhase.onDevice ||
      this == RockScanPhase.uploadFailed ||
      this == RockScanPhase.reconstructionFailed;
}

/// Collapses [upload] and [status] into the single [RockScanPhase] to show.
RockScanPhase rockScanPhase({
  required RockScanUpload upload,
  required RockScanStatus status,
}) {
  // A finished (or definitively failed) reconstruction is the last word:
  // whatever the upload column still says, the bytes demonstrably arrived.
  // This also covers the row that syncs down to a SECOND device, which never
  // uploaded anything and whose `uploadState` is therefore whatever the
  // capturing phone last pushed.
  if (status == RockScanStatus.ready) return RockScanPhase.ready;
  if (status == RockScanStatus.failed) {
    return RockScanPhase.reconstructionFailed;
  }
  if (status == RockScanStatus.processing) {
    return RockScanPhase.reconstructing;
  }

  switch (upload) {
    case RockScanUpload.uploaded:
      return RockScanPhase.reconstructing;
    case RockScanUpload.uploading:
      return RockScanPhase.uploading;
    case RockScanUpload.failed:
      return RockScanPhase.uploadFailed;
    case RockScanUpload.pending:
      return RockScanPhase.onDevice;
  }
}
