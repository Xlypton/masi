import 'dart:typed_data';

import 'package:exif/exif.dart';

/// WGS84 coordinates extracted from a photo's EXIF GPS IFD by
/// [extractGpsFromImageBytes].
typedef PhotoGps = ({double latitude, double longitude});

/// Everything the Face Layout System can learn about WHERE a photo was taken
/// and WHICH WAY the camera was pointed, from its EXIF GPS IFD.
///
/// A superset of [PhotoGps], read in the same single parse. [latitude] and
/// [longitude] are null together or set together; [accuracyMeters] and
/// [bearingDegrees] are independently null, because most cameras write
/// neither and many phones write only one.
typedef PhotoCaptureMetadata = ({
  double? latitude,
  double? longitude,
  double? accuracyMeters,
  double? bearingDegrees,
});

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

/// Reads coordinates, reported accuracy and camera heading in one EXIF parse.
///
/// Same guarantees as [extractGpsFromImageBytes] — pure Dart, header-only, no
/// pixel decode, never throws — and the same strictness: each value is
/// returned only if it is present, well-formed and physically possible, and
/// is otherwise `null` rather than clamped or defaulted. That matters more
/// here than it looks, because the layout engine's whole signal hierarchy
/// rests on being able to tell "no heading" from "heading 0", which is due
/// north.
///
/// `GPSHPositioningError` is the accuracy tag, in metres. Its absence is
/// deliberately NOT treated as "accurate": the engine refuses to position a
/// face along a rock from a fix that will not say how good it is.
///
/// `GPSImgDirection` is the heading, with `GPSImgDirectionRef` saying whether
/// it is true (`T`) or magnetic (`M`) north. Both are accepted and stored
/// as-is: the difference is the local magnetic declination, up to a few
/// degrees in the places this app is used, which is far inside the error the
/// engine already assumes of any heading — and correcting it would need a
/// world magnetic model this app has no reason to carry.
Future<PhotoCaptureMetadata> extractCaptureMetadataFromImageBytes(
  Uint8List bytes,
) async {
  const empty = (
    latitude: null,
    longitude: null,
    accuracyMeters: null,
    bearingDegrees: null,
  );
  try {
    final tags = await readExifFromBytes(bytes);
    if (tags.isEmpty) return empty;

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
    final hasFix = latitude != null && longitude != null;

    return (
      latitude: hasFix ? latitude : null,
      longitude: hasFix ? longitude : null,
      // Accuracy without a fix describes nothing, so it is dropped with it.
      accuracyMeters: hasFix
          ? _positiveScalar(tags['GPS GPSHPositioningError'])
          : null,
      // A heading, unlike accuracy, stands on its own: a photo with a
      // compass reading and no fix still says which way the camera looked,
      // which is enough to order faces round a boulder.
      bearingDegrees: _degrees(tags['GPS GPSImgDirection']),
    );
  } catch (_) {
    return empty;
  }
}

/// A single non-negative, finite EXIF rational, or `null`.
double? _positiveScalar(IfdTag? tag) {
  final value = _scalar(tag);
  if (value == null || value < 0) return null;
  return value;
}

/// A single EXIF rational normalised into `[0, 360)`, or `null`.
///
/// Wrapped rather than rejected out of range: a heading of 360 is due north
/// written the long way, and cameras do write it.
double? _degrees(IfdTag? tag) {
  final value = _scalar(tag);
  if (value == null) return null;
  final wrapped = value % 360.0;
  return wrapped < 0 ? wrapped + 360.0 : wrapped;
}

/// The single numeric component of [tag], or `null` if it has none, has more
/// than one, or is not finite.
double? _scalar(IfdTag? tag) {
  if (tag == null || tag.values.length != 1) return null;
  final raw = tag.values.toList().first;
  final double value;
  if (raw is Ratio) {
    value = raw.toDouble();
  } else if (raw is int) {
    value = raw.toDouble();
  } else if (raw is double) {
    value = raw;
  } else {
    return null;
  }
  return value.isFinite ? value : null;
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
