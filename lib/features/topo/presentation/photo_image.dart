// `PhotoImage`/`PhotoImageProvider`: the ONE place presentation code should
// render a stored photo, so no `.dart` file outside `photo_image_source.dart`
// 's conditional-export variants (native/web/stub) needs to import
// `dart:io`/`Image.file`/`FileImage` for that purpose. This is what unblocks
// the web build: `dart:io` doesn't exist under `dart2wasm`, so every display
// site that used to reach for `Image.file(File(...))` directly would crash
// (or fail to compile) on web.
//
// [storedPath] on every migrated call site is already what
// `PhotoRepository`/`LibraryCrudRepository`/`CommunityRepository` hand back
// after resolving a DB row's raw `localPath`/`thumbnailPath` through
// `PhotoFiles.resolvePhotoPathSync` (native: an absolute path; web: an
// opaque `PhotoByteStore` key — resolution is an identity passthrough on
// web, see `PhotoFiles`' web backend). [PlatformPhotoImage]/
// [resolvePhotoImageStream] re-resolve via [PhotoFiles.resolvePhotoPathSync]
// anyway — a no-op for an already-resolved value — purely so a raw,
// unresolved stored value also works if a future call site ever passes one
// directly.
import 'package:flutter/material.dart';

import '../data/photo_files.dart';
import 'photo_image_source.dart';
import 'photo_loading_fill.dart';

/// Renders the stored photo at [storedPath], on whatever platform this is
/// running: `Image.file` on native, a cached browser blob URL via
/// `Image.network` on web (see `photo_image_source.dart`).
///
/// Mirrors the exact `Image.file(...)` call every migrated site used to make
/// directly: [fit]/[width]/[height] map straight through, and [placeholder]
/// covers every case that used to be handled ad hoc per call site —
/// `errorBuilder` (a real decode failure on native) AND the old
/// `File(...).existsSync()` pre-check (now: bytes not found, or not yet
/// loaded from IndexedDB, on web).
///
/// [loadingPlaceholder] (#56) is a SEPARATE, optional slot for a "still
/// loading" visual (e.g. an animated shimmer skeleton) — DISTINCT from
/// [placeholder], which stays reserved for "this photo genuinely cannot be
/// shown" (a decode error, or bytes confirmed not found). Both backends
/// distinguish the two states from the outside now: native drives it off
/// `Image.file`'s own `frameBuilder` (`frame == null` = still loading), web
/// off whether the async IndexedDB byte-read/cache resolution has completed
/// yet. When [loadingPlaceholder] is omitted, behavior is unchanged from
/// before this param existed: [placeholder] alone covers both "loading" and
/// "missing", exactly like a plain network image appearing once it arrives.
///
/// [cacheWidth]/[cacheHeight] (#56) are optional decode-size hints — passed
/// straight through to the underlying `Image.file`/`Image.network`'s own
/// `cacheWidth`/`cacheHeight`, i.e. a `ResizeImage` wrapped around the real
/// provider. Omitted by default (decode at native size, the pre-existing
/// behavior) so every other call site is unaffected.
///
/// WHAT THEY ACTUALLY BUY DIFFERS BY PLATFORM, and the difference matters
/// because web is the primary target. This doc used to claim flatly that a
/// 52px tile "doesn't pay the cost of decoding a full-resolution original".
/// That is true on native and FALSE on web:
///
///  - native: the codec is handed the target size and decodes straight to it,
///    so the full-resolution bitmap is never materialized — peak memory and
///    decode CPU are both bounded.
///  - web: the browser decodes the frame at its native size and the resize is
///    applied to the result, so a full-resolution decode happens either way
///    (twice over, in effect: full frame, then the scaled copy). What these
///    hints bound is what is RETAINED in `imageCache` afterwards. For a LIST
///    that is still the win worth having — N retained thumbnails instead of N
///    retained originals — but it is not a peak-memory fix, and reaching for
///    it as one is how you end up surprised.
///
/// Two rules follow, both learned the hard way:
///
///  - PASS [cacheWidth] ALONE FOR A THUMBNAIL, NEVER BOTH. `ResizeImage`'s
///    default policy is `ResizeImagePolicy.exact`, which with both dimensions
///    set scales the bitmap to exactly those numbers "regardless of whether
///    it matches the source image's intrinsic aspect ratio" — `BoxFit.fill`,
///    performed in the decoder. A portrait photo behind a square tile arrives
///    already squashed (~1.33x for 4:3) and the widget's own `BoxFit.cover`
///    cannot undo it, because by then the bitmap really IS square. With
///    [cacheWidth] alone the height follows the intrinsic ratio and `cover`
///    centre-crops as intended (`topos_row.dart`'s `_Thumbnail` is the fixed
///    precedent).
///  - NEVER ADD ONE TO A SITE THAT ALSO DECODES THE SAME PHOTO UNSIZED. A
///    resized decode is a DIFFERENT `imageCache` key, not a replacement for
///    the unsized one, so both get decoded and both get retained. That is
///    exactly the topo canvas's situation — its dimension probe resolves the
///    unsized image through [PhotoImageProvider] — which is why that call
///    site deliberately passes neither.
class PhotoImage extends StatelessWidget {
  const PhotoImage(
    this.storedPath, {
    super.key,
    this.fit = BoxFit.cover,
    this.width,
    this.height,
    this.placeholder,
    this.loadingPlaceholder,
    this.cacheWidth,
    this.cacheHeight,
  });

  /// The stored photo reference to render — see this file's doc for what
  /// value shape is expected.
  final String storedPath;
  final BoxFit fit;
  final double? width;
  final double? height;

  /// Shown whenever the photo can't be rendered (decode error, or bytes not
  /// found/not yet loaded — unless [loadingPlaceholder] is given, in which
  /// case "not yet loaded" shows that instead). Defaults to an empty box —
  /// every migrated call site that didn't already have its own visual
  /// fallback used `SizedBox.shrink()`, so that stays the default here too.
  final Widget Function()? placeholder;

  /// Shown while the photo is still being resolved/decoded, distinct from
  /// [placeholder]'s "this photo is missing/broken" — see this class's doc.
  /// `null` (the default) preserves the pre-existing behavior exactly:
  /// [placeholder] alone is shown for the entire loading window.
  final Widget Function()? loadingPlaceholder;

  /// Optional decode-size hints in PHYSICAL pixels — see this class's doc.
  final int? cacheWidth;
  final int? cacheHeight;

  @override
  Widget build(BuildContext context) {
    return PlatformPhotoImage(
      storedPath: storedPath,
      fit: fit,
      width: width,
      height: height,
      placeholder: placeholder,
      loadingPlaceholder: loadingPlaceholder,
      cacheWidth: cacheWidth,
      cacheHeight: cacheHeight,
    );
  }
}

/// A stored photo rendered at TILE size: the 512px-max-edge thumbnail written
/// at import time, never the original.
///
/// Use this for every small, repeated rendering of a photo — a rail tile, a
/// face on the plan, a thumbnail riding the layout line. Reaching for
/// [PhotoImage] with the original's path and a `cacheWidth` looks equivalent
/// and is not; it is how the face rail crashed the app on a real library:
///
///  - On WEB the browser decodes the frame at its NATIVE size and applies the
///    resize afterwards, so `cacheWidth` bounds only what is retained, not
///    what is decoded. A rail of four 12-megapixel originals is four
///    full-resolution decodes in one frame, on top of the canvas's own copy of
///    one of them — enough to take the tab out.
///  - A `cacheWidth` that VARIES (a wider tile for the selected face) mints a
///    fresh `imageCache` entry on every selection change, so tapping along the
///    rail accumulates one full decode per tap.
///  - And per [PhotoImage]'s own rule, a sized decode of a photo that is ALSO
///    decoded unsized elsewhere — which is exactly the canvas — is a second
///    cache key, not a replacement: both are decoded and both are retained.
///
/// The thumbnail sidesteps all three. It is a different, permanently small
/// object, shared by every tile that shows this photo, and it needs no size
/// hint to be bounded. Same derivation as
/// `LibraryCrudRepository._resolveThumbnail` and the canvas's own progressive
/// first layer: [thumbKeyFor] on the stored/resolved original, re-resolved
/// through `PhotoFiles` by [PhotoImage] itself.
///
/// A photo with no thumbnail — imported before that tier, or whose
/// best-effort write failed — shows [placeholder] rather than falling back to
/// the original. Falling back would reintroduce the very decode this exists to
/// avoid, on precisely the oldest and largest photos in a library.
class PhotoThumbnail extends StatelessWidget {
  const PhotoThumbnail(
    this.storedPath, {
    super.key,
    this.fit = BoxFit.cover,
    this.width,
    this.height,
    this.placeholder,
  });

  /// The ORIGINAL's stored/resolved path. The thumbnail key is derived from
  /// it here, so callers never have to remember to.
  final String storedPath;
  final BoxFit fit;
  final double? width;
  final double? height;
  final Widget Function()? placeholder;

  @override
  Widget build(BuildContext context) => PhotoImage(
    thumbKeyFor(storedPath),
    fit: fit,
    width: width,
    height: height,
    placeholder: placeholder,
    // [PhotoLoadingFill], not a bare [MasiShimmer]: it freezes after two
    // seconds, so a tree holding one SETTLES. An unbounded sweep turns every
    // `pumpAndSettle` that reaches a tile into a timeout — twenty-one tests
    // at once, the one time it was tried here.
    loadingPlaceholder: () => PhotoLoadingFill(width: width, height: height),
  );
}

/// Dimension-only resolver for a stored photo: `.resolve(configuration)`
/// yields an [ImageStream] whose listener eventually receives an
/// [ImageInfo] with the real `image.width`/`image.height` — the same
/// contract `FileImage(File(path)).resolve(configuration)` has, just
/// web-safe. Used by [TopoCanvasScreen]'s stored-photo dimension probe
/// (the picked-photo probe already goes through `decodeImageSize`, see that
/// call site's doc — this is only for restoring an ALREADY-attached photo).
class PhotoImageProvider {
  const PhotoImageProvider(this.storedPath, {required this.photoFiles});

  final String storedPath;
  final PhotoFiles photoFiles;

  ImageStream resolve(ImageConfiguration configuration) =>
      resolvePhotoImageStream(storedPath, configuration, photoFiles);
}
