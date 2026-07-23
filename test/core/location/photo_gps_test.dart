import 'dart:typed_data';

import 'package:masi/core/location/photo_gps.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
// Not exported from `package:image/image.dart`'s barrel (its own
// `ifd_value.dart` uses `Rational` in public signatures like
// `IfdValueRational.list` without re-exporting the type), so this test file
// — the only place that needs to CONSTRUCT a `Rational` to hand-build a
// geotagged JPEG fixture — reaches one level into the package's `src/`
// directly. `photo_gps.dart` itself never needs to name `Rational`: it only
// calls `.toDouble()` on the `IfdValue`s it reads back.
import 'package:image/src/util/rational.dart';

/// Builds real JPEG bytes for a tiny (4x4) image, optionally carrying EXIF
/// GPS tags for [latitude]/[longitude] (encoded the same
/// degrees/minutes/seconds + hemisphere-letter way a real camera would).
/// Leaving both null produces a plain JPEG with no GPS IFD at all.
List<int> _buildJpegBytes({double? latitude, double? longitude}) {
  final image = img.Image(width: 4, height: 4);

  if (latitude != null && longitude != null) {
    final gps = image.exif.gpsIfd;
    _setDms(gps, 'GPSLatitude', latitude, positiveRef: 'N', negativeRef: 'S');
    _setDms(
      gps,
      'GPSLongitude',
      longitude,
      positiveRef: 'E',
      negativeRef: 'W',
    );
  }

  return img.encodeJpg(image);
}

/// Sets a `<tagPrefix>Ref` + `<tagPrefix>` pair on [gps] (e.g.
/// `GPSLatitudeRef`/`GPSLatitude`) from a signed [decimal] degrees value,
/// encoding it as EXIF's standard 3-rational (degrees, minutes, seconds)
/// array with the sign folded into the hemisphere-letter ref tag instead —
/// exactly the encoding [extractGpsFromImageBytes] expects to decode.
void _setDms(
  img.IfdDirectory gps,
  String tagPrefix,
  double decimal, {
  required String positiveRef,
  required String negativeRef,
}) {
  final ref = decimal < 0 ? negativeRef : positiveRef;
  final absolute = decimal.abs();
  final degrees = absolute.floor();
  final minutesFull = (absolute - degrees) * 60;
  final minutes = minutesFull.floor();
  final secondsFull = (minutesFull - minutes) * 60;
  // 4 decimal digits of precision on the seconds component.
  final secondsNumerator = (secondsFull * 10000).round();

  gps['${tagPrefix}Ref'] = img.IfdValueAscii(ref);
  gps[tagPrefix] = img.IfdValueRational.list([
    Rational(degrees, 1),
    Rational(minutes, 1),
    Rational(secondsNumerator, 10000),
  ]);
}

/// Builds real JPEG bytes for a tiny (4x4) image with a normal, in-range
/// (Budapest) GPS reading, then overwrites the raw hemisphere-letter ref
/// tags with whatever the caller supplies -- so the DMS numbers themselves
/// stay valid and only the ref tag(s) are the malformed part of the
/// fixture. Used to test [extractGpsFromImageBytes]'s strict ref handling
/// (a ref that isn't EXACTLY one of the two valid letters for its axis must
/// return null, never silently default to positive).
List<int> _buildJpegBytesWithRawGpsRefs({
  required String latitudeRef,
  required String longitudeRef,
}) {
  final image = img.Image(width: 4, height: 4);
  final gps = image.exif.gpsIfd;
  _setDms(gps, 'GPSLatitude', 47.4979, positiveRef: 'N', negativeRef: 'S');
  _setDms(gps, 'GPSLongitude', 19.0402, positiveRef: 'E', negativeRef: 'W');
  // Overwrite the refs _setDms just wrote with the caller's raw value.
  gps['GPSLatitudeRef'] = img.IfdValueAscii(latitudeRef);
  gps['GPSLongitudeRef'] = img.IfdValueAscii(longitudeRef);
  return img.encodeJpg(image);
}

void main() {
  group('extractGpsFromImageBytes', () {
    test(
      'a JPEG with EXIF GPS tags for Budapest (47.4979 N, 19.0402 E) '
      'decodes back to approximately those coordinates',
      () async {
        final bytes = _buildJpegBytes(latitude: 47.4979, longitude: 19.0402);

        final gps = await extractGpsFromImageBytes(Uint8List.fromList(bytes));

        expect(gps, isNotNull);
        // DMS round-tripping loses a little precision (seconds rounded to
        // 4 decimal digits) — 1e-4 degrees is well under 1m, an ample
        // tolerance for this.
        expect(gps!.latitude, closeTo(47.4979, 1e-4));
        expect(gps.longitude, closeTo(19.0402, 1e-4));
      },
    );

    test(
      'southern/western hemisphere refs (S/W) decode to NEGATIVE decimal '
      'degrees',
      () async {
        final bytes = _buildJpegBytes(latitude: -33.8688, longitude: -70.6483);

        final gps = await extractGpsFromImageBytes(Uint8List.fromList(bytes));

        expect(gps, isNotNull);
        expect(gps!.latitude, closeTo(-33.8688, 1e-4));
        expect(gps.longitude, closeTo(-70.6483, 1e-4));
      },
    );

    test('a JPEG with no GPS EXIF tags at all returns null', () async {
      final bytes = _buildJpegBytes();

      final gps = await extractGpsFromImageBytes(Uint8List.fromList(bytes));

      expect(gps, isNull);
    });

    test('non-image/garbage bytes return null, never throw', () async {
      final garbage = Uint8List.fromList(List<int>.filled(32, 0xFF));

      // Preserves the original two-fold intent (no throw, AND the
      // completed value is null): `completion(isNull)` only matches if the
      // future completes successfully with a null value, so any thrown
      // error still fails the test just as `returnsNormally` would have.
      await expectLater(extractGpsFromImageBytes(garbage), completion(isNull));
    });

    test('empty bytes return null, never throw', () async {
      final empty = Uint8List.fromList(const []);

      await expectLater(extractGpsFromImageBytes(empty), completion(isNull));
    });

    test(
      'an out-of-range latitude (> 90 degrees) returns null (no coords), '
      'even though the longitude is a normal in-range value',
      () async {
        // 95 degrees is well outside a real latitude's [-90, 90] range but
        // is a perfectly representable DMS value (nothing in the DMS
        // encoding itself constrains the degrees component), so this is
        // exactly the kind of "plausible-but-wrong" corrupt EXIF this guard
        // exists to reject.
        final bytes = _buildJpegBytes(latitude: 95.0, longitude: 19.0402);

        final gps = await extractGpsFromImageBytes(Uint8List.fromList(bytes));

        expect(gps, isNull);
      },
    );

    test(
      'an out-of-range longitude (> 180 degrees) returns null (no coords), '
      'even though the latitude is a normal in-range value',
      () async {
        final bytes = _buildJpegBytes(latitude: 47.4979, longitude: 200.0);

        final gps = await extractGpsFromImageBytes(Uint8List.fromList(bytes));

        expect(gps, isNull);
      },
    );

    test(
      'an empty GPSLatitudeRef (present tag, empty string) returns null, '
      'never defaults to the positive (N) hemisphere',
      () async {
        final bytes = _buildJpegBytesWithRawGpsRefs(
          latitudeRef: '',
          longitudeRef: 'E',
        );

        final gps = await extractGpsFromImageBytes(Uint8List.fromList(bytes));

        expect(gps, isNull);
      },
    );

    test(
      'an unexpected GPSLongitudeRef letter (neither E nor W) returns '
      'null, never defaults to the positive (E) hemisphere',
      () async {
        final bytes = _buildJpegBytesWithRawGpsRefs(
          latitudeRef: 'N',
          longitudeRef: 'Q',
        );

        final gps = await extractGpsFromImageBytes(Uint8List.fromList(bytes));

        expect(gps, isNull);
      },
    );
  });
}
