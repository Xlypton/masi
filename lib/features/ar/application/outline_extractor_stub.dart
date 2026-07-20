import 'dart:ui' as ui;

export 'outline_shape.dart';

/// Fallback used when neither `dart:io` nor `dart:js_interop` is available.
/// AR never runs here (see `lib/core/platform/ar_support.dart`), so this is
/// an inert no-op, matching `outline_extractor_web.dart`.
Future<ui.Image?> extractOutline(String path, {int maxDim = 800}) async => null;
