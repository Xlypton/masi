/// Why a photo's BYTES could not be persisted locally, and the plain words to
/// tell the user about it.
///
/// Deliberately IMPORT-FREE and platform-agnostic. Three unrelated layers need
/// this type: the web `PhotoFiles` backend that throws it
/// (`photo_files_web.dart`), the platform-agnostic repository whose INSERT it
/// aborts (`LibraryCrudRepository.attachPhotoToWall`), and the two screens that
/// present it (`topos_screen.dart`'s `_handleNewTopo`,
/// `topo_canvas_screen.dart`'s `_attachPhotoAndLoad`). So it must be importable
/// from a file that touches NEITHER `dart:io` (the web grep gate —
/// the directive-anchored regex at `tool/build_web.sh:40` must find nothing
/// outside `*_native.dart`) NOR `dart:js_interop`/`package:idb_shim`
/// (which would newly drag the browser byte store into the iOS/Android builds).
/// Hence no imports at all, and a STRING-based classifier — see
/// [classifyPhotoWriteFailure].
///
/// Structured exactly like this feature's other shared, platform-agnostic type
/// file (`photo_path_resolution.dart`), and re-exported from the
/// `photo_files.dart` facade the same way.
library;

/// The kind of local byte-write failure a [PhotoWriteException] reports.
enum PhotoWriteFailure {
  /// The browser (or the device) refused the write because the origin is out of
  /// room. On web this is IndexedDB rejecting the request/transaction with a
  /// `DOMException` named `QuotaExceededError`.
  ///
  /// This is the REALISTIC trigger in ordinary use, not an edge case: photo
  /// originals are deliberately kept at FULL resolution (decision D-5 — quota
  /// is handled by failing loudly, never by shrinking the user's photo), and
  /// only the 512px/q80 thumbnail is downscaled.
  quotaExceeded,

  /// Anything else: the store could not be opened, a version-change upgrade is
  /// blocked, private-browsing storage restrictions, an aborted transaction, or
  /// a failed read of the picked source.
  unknown,
}

/// Thrown when a photo's BYTES could not be persisted locally.
///
/// L3 fix (silent data loss): `PhotoFiles.importPhoto` on web used to swallow
/// this and return the logical key anyway, so
/// `LibraryCrudRepository.attachPhotoToWall` went on to insert a `Photos` row
/// whose `localPath` pointed at bytes that were never written — a topo whose
/// photo is permanently a placeholder, with nothing anywhere reporting why.
///
/// `attachPhotoToWall` awaits `importPhoto` BEFORE opening its insert
/// transaction, so this exception reaching a caller GUARANTEES no `Photos` row
/// was created and there is nothing to clean up on the photo side.
class PhotoWriteException implements Exception {
  const PhotoWriteException({
    required this.failure,
    required this.key,
    this.cause,
  });

  /// What went wrong, classified for presentation.
  final PhotoWriteFailure failure;

  /// The logical store key the write was attempted under (e.g.
  /// `photos/<photoId>.jpg`) — diagnostics only, never shown to the user.
  final String key;

  /// The underlying error, kept for logging only. Callers must present
  /// [userMessage], never this.
  final Object? cause;

  /// A short, complete sentence safe to render straight into a `SnackBar`.
  /// Deliberately free of any exception name or store key — the user gets an
  /// actionable sentence, the log gets [toString].
  String get userMessage => switch (failure) {
    PhotoWriteFailure.quotaExceeded =>
      'Out of storage space — this photo was not saved. Free up space on this '
          'device and try again.',
    PhotoWriteFailure.unknown =>
      'This photo could not be saved on this device. Please try again.',
  };

  @override
  String toString() =>
      'PhotoWriteException(${failure.name}, key: $key, cause: $cause)';
}

/// Classifies a raw byte-store error into a [PhotoWriteFailure].
///
/// STRING-based rather than type-based, for two reasons:
///  1. This file may not import `package:idb_shim` or `dart:io` (see the
///     library doc), so `DatabaseError`/`FileSystemException` are unavailable
///     here by construction.
///  2. The browser exception shape is not stable across engines OR across
///     Dart's two web compilers. IndexedDB signals an exhausted origin quota
///     with a `DOMException` whose `name` is `QuotaExceededError`
///     (`code == 22`); older Gecko used `NS_ERROR_DOM_QUOTA_REACHED`.
///     `idb_shim`'s wasm-clean native backend rethrows that as its own
///     `DatabaseErrorNative`, whose `toString()` is `'<name>: <message>'`
///     (`idb_shim/lib/src/native_web/native_error.dart`) — e.g.
///     `'QuotaExceededError: The quota has been exceeded.'` — while under
///     dart2wasm the SAME failure can instead arrive as a plain `DatabaseError`
///     carrying the stringified JS error (that file's `_handleError` has an
///     explicit "Happens on wasm, very unfortunate" branch for it). Every one
///     of those forms carries the marker text, so matching text covers them all
///     with no interop — and keeps the whole thing unit-testable on the plain
///     Dart VM.
PhotoWriteFailure classifyPhotoWriteFailure(Object error) {
  final text = error.toString().toLowerCase();
  for (final marker in _quotaMarkers) {
    if (text.contains(marker)) return PhotoWriteFailure.quotaExceeded;
  }
  return PhotoWriteFailure.unknown;
}

/// Lower-cased substrings that identify an out-of-room failure across engines:
/// Blink/WebKit's `QuotaExceededError`, legacy Gecko's
/// `NS_ERROR_DOM_QUOTA_REACHED`, the DOMException default messages, and POSIX
/// `ENOSPC` (so the same classifier stays correct if a native backend ever
/// calls it).
const List<String> _quotaMarkers = [
  'quotaexceedederror',
  'ns_error_dom_quota_reached',
  'quota has been exceeded',
  'quota exceeded',
  'no space left on device',
];
