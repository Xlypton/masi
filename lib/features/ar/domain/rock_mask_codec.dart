import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'dart:ui' show Offset;

/// The result of a native rock-segmentation pass over a reference photo,
/// shared by both the AR `start` call and the new `segmentPreview` call (see
/// `ar_segmentation_channel.dart`). Two independent, always-optional signals:
///
///  - [quadPercent]: the coarse 4-corner (TL/TR/BR/BL) crop quad, each
///    component a 0..1 fraction of the FULL upright reference photo. `null`
///    when native found no confident quad (or the payload was malformed).
///  - [mask]: a per-pixel rock/not-rock alpha mask, already expanded to a
///    paint-ready [ui.Image] (see [decodeRockMaskAlpha]). `null` when native
///    found nothing / segmentation failed, OR when running against a no-op
///    (web) channel that never calls native.
///
/// Both fields are OMITTED-TOGETHER-as-null on the wire per the existing
/// `rockQuadPercent` convention (see `ar_channel.dart`): a "found nothing"
/// result is a plain absence, never a null sentinel or an error.
class ArSegmentationResult {
  const ArSegmentationResult({this.quadPercent, this.mask});

  /// The 4 fractional (0..1) corners of the crop quad in the FULL upright
  /// reference-photo frame, TL/TR/BR/BL — same frame as `refSize` /
  /// `rockQuadPercent`. `null` when absent/malformed.
  final List<Offset>? quadPercent;

  /// The segmentation mask as a paint-ready RGBA [ui.Image] (constant tint
  /// RGB, per-texel alpha driven by the raw mask byte). Its pixel dimensions
  /// are the DOWNSAMPLED mask dims (long edge <= 256px), NOT the photo's — the
  /// mask lives in the same 0..1 frame as [quadPercent], so a consumer stretches
  /// it over the photo rect with an independent-x/y `drawImageRect` (the stretch
  /// self-corrects any aspect mismatch). `null` when absent/malformed. Owns GPU
  /// memory: dispose it when done.
  final ui.Image? mask;
}

/// Parses the optional `rockQuadPercent` field of a native segmentation
/// [result] map into 4 [Offset]s, or `null`. Byte-for-byte the same
/// malformed-input contract as `ArChannel`'s private `_parseRockQuadPercent`
/// (from which this is lifted so `ar_channel.dart` and the segmentation
/// channel share one parser): `null` when [result] isn't a `Map`; the
/// `rockQuadPercent` key is absent; its value isn't a `List`; that list's
/// length isn't exactly 8; or any entry isn't `num`. Never throws.
List<Offset>? parseRockQuadPercent(Object? result) {
  if (result is! Map) return null;
  final Object? raw = result['rockQuadPercent'];
  if (raw is! List || raw.length != 8) return null;
  final List<double> values = <double>[];
  for (final Object? entry in raw) {
    if (entry is! num) return null;
    values.add(entry.toDouble());
  }
  return <Offset>[
    Offset(values[0], values[1]),
    Offset(values[2], values[3]),
    Offset(values[4], values[5]),
    Offset(values[6], values[7]),
  ];
}

/// The constant RGB tint every mask texel is painted with; only the per-texel
/// alpha varies (0 or 255, straight from the raw mask byte). Cyan reads well
/// as a highlight over most rock/foliage photos.
const int _kMaskTintR = 0x00;
const int _kMaskTintG = 0xE5;
const int _kMaskTintB = 0xFF;

/// Reads the optional raw-alpha mask (`rockMaskAlpha` / `rockMaskWidth` /
/// `rockMaskHeight`) from a native segmentation [result] map and expands it
/// into a paint-ready RGBA [ui.Image], or resolves to `null`.
///
/// Wire contract (all three keys omitted-together when native segmented
/// nothing / failed — mirrors the `rockQuadPercent` omission convention):
///  - `rockMaskAlpha`: a [Uint8List] of raw 8-bit alpha, row-major, one byte
///    per texel (each 0 or 255), length == `rockMaskWidth * rockMaskHeight`.
///  - `rockMaskWidth` / `rockMaskHeight`: positive `int`s, the downsampled
///    mask dims (long edge <= 256px).
///
/// Returns `null` (never throws) when: [result] isn't a `Map`; any of the
/// three keys is absent or the wrong type; the dims aren't positive ints; or
/// the byte length doesn't match `width * height`.
///
/// Each mask byte becomes one RGBA texel — constant tint RGB, `alpha = byte` —
/// then handed to [ui.decodeImageFromPixels] with [ui.PixelFormat.rgba8888],
/// exactly the raw-RGBA (NOT PNG) decode idiom `outline_extractor_native.dart`
/// uses for its edge-detected outline image.
Future<ui.Image?> decodeRockMaskAlpha(Object? result) async {
  if (result is! Map) return null;

  final Object? alphaRaw = result['rockMaskAlpha'];
  final Object? widthRaw = result['rockMaskWidth'];
  final Object? heightRaw = result['rockMaskHeight'];

  if (alphaRaw is! Uint8List) return null;
  if (widthRaw is! int || heightRaw is! int) return null;
  if (widthRaw <= 0 || heightRaw <= 0) return null;

  final int width = widthRaw;
  final int height = heightRaw;
  if (alphaRaw.length != width * height) return null;

  final Uint8List rgba = Uint8List(width * height * 4);
  for (int i = 0; i < alphaRaw.length; i++) {
    final int o = i * 4;
    rgba[o] = _kMaskTintR;
    rgba[o + 1] = _kMaskTintG;
    rgba[o + 2] = _kMaskTintB;
    rgba[o + 3] = alphaRaw[i];
  }

  try {
    final completer = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      rgba,
      width,
      height,
      ui.PixelFormat.rgba8888,
      completer.complete,
    );
    return await completer.future;
  } catch (_) {
    return null;
  }
}
