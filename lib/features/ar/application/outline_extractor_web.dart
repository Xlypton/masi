import 'dart:ui' as ui;

export 'outline_shape.dart';

/// Web has no native AR feature (no camera/ARKit — see
/// `lib/core/platform/ar_support.dart`), so ghost-outline extraction never
/// actually needs to run here. Inert no-op: always resolves to `null`,
/// exactly like the native implementation's own "never throws, `null` on
/// failure" contract, just unconditionally. Wasm-clean: no `dart:io`,
/// `package:image` ops, or `compute()` isolate hop.
Future<ui.Image?> extractOutline(String path, {int maxDim = 800}) async => null;
