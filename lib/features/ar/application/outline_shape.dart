import 'package:image/image.dart' as img;

/// Converts [src] into a sparse, transparent-background line drawing suitable
/// for an AR alignment overlay: opaque (solid [lineR]/[lineG]/[lineB], alpha
/// 255) exactly where a strong edge was detected, fully transparent (alpha 0)
/// everywhere else.
///
/// [src] is first downscaled (preserving aspect ratio, never upscaled) so its
/// larger side is at most [maxDim], converted to grayscale, blurred slightly
/// to suppress fine texture noise, then run through Sobel edge detection.
/// Each edge pixel's luminance/magnitude is compared against [threshold]: at
/// or below it the output pixel is fully transparent; above it the output
/// pixel is fully opaque in the requested line color. There are no partial
/// alphas, so flat/textured-but-weak regions are genuinely transparent (no
/// color wash) and only clean, strong edges survive (a sparse line drawing
/// rather than noisy fine detail). The returned RGBA image is the same size
/// as the (resized) edge map.
///
/// Pure and synchronous — does no file or platform I/O, and never mutates
/// [src] (resizing always produces an independent copy before any further
/// processing). Safe to run on a background isolate (see `extractOutline` in
/// `outline_extractor_native.dart`).
///
/// Platform-agnostic (only `package:image`, pure Dart) — lives in its own
/// file so both the native and web `outline_extractor_*.dart` variants can
/// export it unchanged; only `extractOutline`'s file-reading/isolate
/// plumbing differs by platform, not this pixel-processing core.
img.Image outlineFromImage(
  img.Image src, {
  int maxDim = 800,
  int lineR = 0,
  int lineG = 0,
  int lineB = 0,
  int threshold = 60,
}) {
  final largerSide = src.width > src.height ? src.width : src.height;
  final scale = largerSide > maxDim ? maxDim / largerSide : 1.0;
  final targetWidth = (src.width * scale).round();

  // copyResize always returns a distinct Image (a clone when no resize is
  // actually needed), so `src` is never touched by the grayscale/blur/sobel
  // steps below.
  final resized = img.copyResize(src, width: targetWidth);
  final gray = img.grayscale(resized);
  // Blur before edge detection to suppress fine texture (rock grain, chalk
  // marks, etc.) so only genuine structural edges survive Sobel.
  final blurred = img.gaussianBlur(gray, radius: 2);
  final edges = img.sobel(blurred);

  final out = img.Image(
    width: edges.width,
    height: edges.height,
    numChannels: 4,
  );
  for (final p in edges) {
    final magnitude = p.luminance.round().clamp(0, 255);
    if (magnitude > threshold) {
      out.setPixelRgba(p.x, p.y, lineR, lineG, lineB, 255);
    } else {
      out.setPixelRgba(p.x, p.y, 0, 0, 0, 0);
    }
  }
  return out;
}
