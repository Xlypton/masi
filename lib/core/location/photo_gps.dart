import 'dart:typed_data';

import 'package:exif/exif.dart';

/// WGS84 coordinates extracted from a photo's EXIF GPS IFD by
/// [extractGpsFromImageBytes].
typedef PhotoGps = ({double latitude, double longitude});

/// Extracts the GPS coordinates baked into [bytes]'s EXIF GPS IFD
/// (`GPSLatitude`/`GPSLatitudeRef`/`GPSLongitude`/`GPSLongitudeRef`),
/// converting EXIF's degrees-minutes-seconds + hemisphere-letter encoding
/// into signed decimal degrees (negative for `S`/`W`).
///
/// Backed by the pure-Dart `exif` package's [readExifFromBytes], which walks
/// only the JPEG APP1/TIFF EXIF header directly out of [bytes] — it never
/// decodes a single pixel. This replaced an earlier implementation that ran
/// `package:image`'s full `decodeImage` on the original photo purely to
/// reach these 2 EXIF GPS tags, discarding the decoded pixels immediately
/// after: a multi-megapixel pure-Dart pixel decode that, on web (no worker
/// isolate to offload to), froze the browser's main thread for hundreds of
/// ms to seconds on every photo attach. [readExifFromBytes] parses only the
/// EXIF IFD bytes, so it's orders of magnitude cheaper and safe to run on
/// every platform, web included. `readExifFromBytes`'s own file-backed
/// sibling (`readExifFromFile`) reaches native file I/O internally, but this
/// call only ever uses its bytes-backed path (`FileReader.fromBytes`), which
/// is pure-Dart and never reaches that code — so nothing web-unsafe is
/// pulled in here.
///
/// Never throws: returns `null` for anything that isn't a clean GPS read —
/// bytes with no parseable EXIF at all, parseable EXIF with no GPS sub-IFD,
/// a GPS IFD missing/malformed latitude/longitude tags, a hemisphere-letter
/// ref that isn't EXACTLY one of the two valid letters for that axis, or a
/// decoded value that is NaN/infinite or outside the physically possible
/// range (latitude [-90, 90], longitude [-180, 180]) — see
/// [_decimalDegrees]. A corrupt or unexpected EXIF value is dropped (no
/// coordinates persisted) rather than clamped to a boundary, so it can never
/// masquerade as a real edge coordinate.
Future<PhotoGps?> extractGpsFromImageBytes(Uint8List bytes) async {
  try {
    final tags = await readExifFromBytes(bytes);
    if (tags.isEmpty) return null;

    final latitude = _decimalDegrees(
      tags['GPS GPSLatitude'],
      tags['GPS GPSLatitudeRef'],
      positiveRef: 'N',
      negativeRef: 'S',
      limit: 90,
    );
    final longitude = _decimalDegrees(
      tags['GPS GPSLongitude'],
      tags['GPS GPSLongitudeRef'],
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

/// Converts one EXIF GPS coordinate — [value] the tag holding the 3-element
/// (degrees, minutes, seconds) rational array, [ref] the tag holding its
/// hemisphere-letter — into signed decimal degrees, guarding against a
/// corrupt/unexpected EXIF value ever producing a plausible-but-wrong
/// result:
///
/// - Returns `null` if [value] or [ref] is missing, [value] doesn't have
///   the expected 3 components, or those components aren't rationals
///   (`Ratio`s).
/// - The hemisphere ref is treated STRICTLY: after trim+uppercase it must
///   be EXACTLY [positiveRef] or EXACTLY [negativeRef] (e.g. `'N'`/`'S'` for
///   latitude, `'E'`/`'W'` for longitude) — anything else (missing, empty,
///   or an unexpected letter) returns `null` rather than defaulting to
///   positive.
/// - Returns `null` if the resulting decimal is `NaN`/infinite, or outside
///   `[-limit, limit]` — never clamped to the boundary, since a bogus value
///   shouldn't masquerade as a real edge coordinate.
double? _decimalDegrees(
  IfdTag? value,
  IfdTag? ref, {
  required String positiveRef,
  required String negativeRef,
  required double limit,
}) {
  if (value == null || ref == null || value.values.length < 3) return null;

  final components = value.values.toList();
  final degreesComponent = components[0];
  final minutesComponent = components[1];
  final secondsComponent = components[2];
  if (degreesComponent is! Ratio ||
      minutesComponent is! Ratio ||
      secondsComponent is! Ratio) {
    return null;
  }
  final decimal = degreesComponent.toDouble() +
      minutesComponent.toDouble() / 60 +
      secondsComponent.toDouble() / 3600;

  final hemisphere = ref.printable.trim().toUpperCase();
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
