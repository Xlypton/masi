import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../topo/data/image_ops/image_ops.dart';

/// Longest edge, in pixels, an avatar is stored at.
///
/// It is drawn at radius 24 at the very largest (the Account card), so 512
/// still covers a 3x device with room to spare, while keeping the encoded
/// JPEG in the tens of kilobytes — which is what makes storing it inline in
/// the synced `Profiles.avatarUrl` column reasonable at all.
const int kAvatarMaxEdge = 512;

/// JPEG quality for a stored avatar. Matches the app's thumbnail pipeline.
const int kAvatarJpegQuality = 80;

/// Hard ceiling on the RAW (pre-base64) bytes an avatar may occupy. Anything
/// above this is refused rather than written, so a pathological image can
/// never bloat a row that syncs on every push.
///
/// Sized well above a 512px q80 JPEG (typically 30-60 KB) so it only ever
/// catches a genuine anomaly — a downscaler that silently did nothing, or an
/// image whose content defeats JPEG (huge synthetic noise).
const int kAvatarMaxBytes = 256 * 1024;

/// Thrown by [pickAvatarDataUrl] when a picked image cannot be stored. The
/// [message] is user-facing.
class AvatarPickException implements Exception {
  const AvatarPickException(this.message);
  final String message;

  @override
  String toString() => 'AvatarPickException: $message';
}

/// Picks an image from [source] and normalizes it into a
/// `data:image/jpeg;base64,...` URL suitable for `Profiles.avatarUrl`.
///
/// Returns `null` when the user cancels the picker — the caller must treat
/// that as "nothing happened", not as a failure.
///
/// Two-stage downscale, deliberately:
///  1. `image_picker`'s own `maxWidth`/`maxHeight`/`imageQuality`, which on
///     native is done by the platform (cheap, off the Dart heap) and on web
///     by `image_picker_for_web`'s canvas resize.
///  2. [generateThumbnail], the app's existing cross-platform resize seam,
///     as a belt-and-braces pass. It is a no-op when the image is already
///     within [kAvatarMaxEdge], so on the normal path stage 2 costs a decode
///     and nothing else — but it means a platform where stage 1 silently
///     does nothing still cannot write a multi-megabyte row.
///
/// `requestFullMetadata: false`, unlike `pickPhotoFrom` (which needs EXIF
/// GPS to place a wall): an avatar has no use for EXIF and stripping it
/// keeps the user's home coordinates out of a row that syncs to a table
/// other users can read.
Future<String?> pickAvatarDataUrl(ImageSource source) async {
  final picked = await ImagePicker().pickImage(
    source: source,
    maxWidth: kAvatarMaxEdge.toDouble(),
    maxHeight: kAvatarMaxEdge.toDouble(),
    imageQuality: kAvatarJpegQuality,
    requestFullMetadata: false,
  );
  if (picked == null) return null;

  final raw = await picked.readAsBytes();
  return encodeAvatarDataUrl(
    await generateThumbnail(
      raw,
      maxEdge: kAvatarMaxEdge,
      quality: kAvatarJpegQuality,
    ),
  );
}

/// Wraps already-normalized [bytes] into a base64 `data:` URL, throwing
/// [AvatarPickException] when they exceed [kAvatarMaxBytes].
///
/// Split out of [pickAvatarDataUrl] so the size rule is testable without a
/// picker or an image codec — see CLAUDE.md's standing rule that a widget
/// test must never drive a real decode.
String encodeAvatarDataUrl(Uint8List bytes) {
  if (bytes.isEmpty) {
    throw const AvatarPickException("That image couldn't be read.");
  }
  if (bytes.length > kAvatarMaxBytes) {
    throw const AvatarPickException(
      'That image is too large to use as a profile picture.',
    );
  }
  return 'data:image/jpeg;base64,${base64Encode(bytes)}';
}

/// Injectable seam for [pickAvatarDataUrl] — overridden in widget tests with
/// a fake that returns a canned data URL (or throws), so no test ever opens
/// a native picker or runs a real image decode.
final avatarPickerProvider = Provider<Future<String?> Function(ImageSource)>(
  (ref) => pickAvatarDataUrl,
);
