import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// WGS84 coordinates extracted from a photo's EXIF GPS IFD by
/// [extractGpsFromImageBytes].
typedef PhotoGps = ({double latitude, double longitude});

/// Extracts the GPS coordinates baked into [bytes]'s EXIF GPS IFD
/// (`GPSLatitude`/`GPSLatitudeRef`/`GPSLongitude`/`GPSLongitudeRef`),
/// converting EXIF's degrees-minutes-seconds + hemisphere-letter encoding
/// into signed decimal degrees (negative for `S`/`W`).
///
/// Backed by `package:image`'s own EXIF reader (already a direct dependency
/// — see pubspec.yaml — for the AR outline-extraction pipeline's use of
/// `package:image`), which reads a decoded JPEG's GPS IFD cleanly enough
/// that the separate pure-Dart `exif` package was not needed for this. PNG
/// is not a useful source here: this version of `package:image` does not
/// parse PNG `eXIf` chunks (its decoder has that branch commented out as a
/// TODO), so a PNG will always come back with no EXIF and therefore `null`
/// — real camera/gallery photos are effectively always JPEG (or HEIC,
/// which iOS's photo picker re-encodes to JPEG when requested — see
/// `photo_source_sheet.dart`), so this is not a practical limitation.
///
/// Never throws: returns `null` for anything that isn't a clean GPS read —
/// bytes that don't decode as an image at all, a decodable image with no
/// EXIF, EXIF with no GPS sub-IFD, a GPS IFD missing/malformed
/// latitude/longitude tags, a hemisphere-letter ref that isn't EXACTLY one
/// of the two valid letters for that axis, or a decoded value that is
/// NaN/infinite or outside the physically possible range (latitude
/// [-90, 90], longitude [-180, 180]) — see [_decimalDegrees]. A corrupt or
/// unexpected EXIF value is dropped (no coordinates persisted) rather than
/// clamped to a boundary, so it can never masquerade as a real edge
/// coordinate.
PhotoGps? extractGpsFromImageBytes(Uint8List bytes) {
  try {
    final image = img.decodeImage(bytes);
    if (image == null) return null;

    final gps = image.exif.gpsIfd;
    final latitude = _decimalDegrees(
      gps['GPSLatitude'],
      gps['GPSLatitudeRef'],
      positiveRef: 'N',
      negativeRef: 'S',
      limit: 90,
    );
    final longitude = _decimalDegrees(
      gps['GPSLongitude'],
      gps['GPSLongitudeRef'],
      positiveRef: 'E',
      negativeRef: 'W',
      limit: 180,
    );
    if (latitude == null || longitude == null) return null;

    return (latitude: latitude, longitude: longitude);
  } catch (_) {
    return null;
  }
}

/// Converts one EXIF GPS coordinate — [value] the tag's 3-element
/// (degrees, minutes, seconds) rational array, [ref] its hemisphere-letter
/// tag — into signed decimal degrees, guarding against a corrupt/unexpected
/// EXIF value ever producing a plausible-but-wrong result:
///
/// - Returns `null` if [value] or [ref] is missing, or [value] doesn't have
///   the expected 3 components.
/// - The hemisphere ref is treated STRICTLY: after trim+uppercase it must
///   be EXACTLY [positiveRef] or EXACTLY [negativeRef] (e.g. `'N'`/`'S'` for
///   latitude, `'E'`/`'W'` for longitude) — anything else (missing, empty,
///   or an unexpected letter) returns `null` rather than defaulting to
///   positive.
/// - Returns `null` if the resulting decimal is `NaN`/infinite, or outside
///   `[-limit, limit]` — never clamped to the boundary, since a bogus value
///   shouldn't masquerade as a real edge coordinate.
double? _decimalDegrees(
  img.IfdValue? value,
  img.IfdValue? ref, {
  required String positiveRef,
  required String negativeRef,
  required double limit,
}) {
  if (value == null || ref == null || value.length < 3) return null;
  final degrees = value.toDouble(0);
  final minutes = value.toDouble(1);
  final seconds = value.toDouble(2);
  final decimal = degrees + minutes / 60 + seconds / 3600;

  final hemisphere = ref.toString().trim().toUpperCase();
  final bool negative;
  if (hemisphere == positiveRef) {
    negative = false;
  } else if (hemisphere == negativeRef) {
    negative = true;
  } else {
    return null;
  }

  final signed = negative ? -decimal : decimal;
  if (signed.isNaN || signed.isInfinite) return null;
  if (signed < -limit || signed > limit) return null;
  return signed;
}
