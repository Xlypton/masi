import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:masi/features/ar/application/ar_segmentation_channel_factory.dart';
import 'package:masi/features/ar/domain/rock_mask_codec.dart';

/// Dart-side handle to the native rock-segmentation platform channel
/// (`masi/arSegmentation`, a [MethodChannel]). Separate from `masi/ar`
/// (`ar_channel.dart`): this one runs a standalone, one-shot segmentation of
/// a reference photo (no live AR session, no event stream) so the crop quad +
/// per-pixel rock mask can be previewed/used independently of an active AR
/// alignment.
///
/// The channel name defaults to `masi/arSegmentation` but accepts an injected
/// [MethodChannel] so tests can supply a mock. Mirrors `ArChannel`'s
/// safety/idioms throughout: a [ArSegmentationChannel.noop] web-safe variant,
/// `_noop` short-circuits, and per-field malformed-input tolerance delegated
/// to the shared parsers in `rock_mask_codec.dart`.
class ArSegmentationChannel {
  ArSegmentationChannel({MethodChannel? method})
    : _method = method ?? const MethodChannel('masi/arSegmentation'),
      _noop = false;

  /// A web-safe no-op [ArSegmentationChannel]: [segmentPreview] resolves
  /// immediately to a const empty [ArSegmentationResult] WITHOUT ever touching
  /// a [MethodChannel] — there is no native `masi/arSegmentation` handler on
  /// web, so invoking one there would throw `MissingPluginException`. See
  /// `ar_segmentation_channel_factory_web.dart`, which wires this in for the
  /// web build via [ArSegmentationChannel.isNoop].
  ArSegmentationChannel.noop()
    : _method = const MethodChannel('masi/arSegmentation'),
      _noop = true;

  final MethodChannel _method;
  final bool _noop;

  /// Whether this is a no-op channel (see [ArSegmentationChannel.noop]) that
  /// never touches a real platform channel. Lets callers/tests distinguish a
  /// web-safe stand-in from a real native-backed channel.
  bool get isNoop => _noop;

  /// Runs a one-shot native segmentation of the reference photo at
  /// [imagePath], returning the crop quad + rock mask as an
  /// [ArSegmentationResult].
  ///
  /// Invokes the native `segmentPreview` method with `{'imagePath': ...}`.
  /// Native's result is the same shape as `ArChannel.start`'s, plus the mask
  /// keys: `{'rockQuadPercent': [Double]?, 'rockMaskAlpha': Uint8List?,
  /// 'rockMaskWidth': Int?, 'rockMaskHeight': Int?}` — every field optional and
  /// omitted-together-as-absent when native segmented nothing (see the shared
  /// [parseRockQuadPercent] / [decodeRockMaskAlpha] parsers for the exact
  /// malformed/absent -> null rules).
  ///
  /// The no-op channel (web) returns a const empty result without ever calling
  /// native.
  Future<ArSegmentationResult> segmentPreview(String imagePath) async {
    if (_noop) return const ArSegmentationResult();
    debugPrint(
      'AR_DBG ar_segmentation_channel.segmentPreview invoking '
      '(imagePath=$imagePath)',
    );
    try {
      final result = await _method.invokeMethod<Object?>(
        'segmentPreview',
        <String, Object?>{'imagePath': imagePath},
      );
      debugPrint('AR_DBG ar_segmentation_channel.segmentPreview returned OK');
      return ArSegmentationResult(
        quadPercent: parseRockQuadPercent(result),
        mask: await decodeRockMaskAlpha(result),
      );
    } catch (e) {
      debugPrint('AR_DBG ar_segmentation_channel.segmentPreview ERROR $e');
      rethrow;
    }
  }
}

/// Supplies the [ArSegmentationChannel] used to run one-shot rock
/// segmentation. Overridable in tests. Backed by
/// [createArSegmentationChannel] so this resolves to a real native-backed
/// channel on iOS/Android/desktop and a web-safe [ArSegmentationChannel.noop]
/// on web (see `ar_segmentation_channel_factory.dart`) — no code path invokes
/// a real platform channel on a platform without a native
/// `masi/arSegmentation` handler. Mirrors `ar_controller.dart`'s
/// `arChannelProvider`.
final arSegmentationChannelProvider = Provider<ArSegmentationChannel>(
  (ref) => createArSegmentationChannel(),
);
