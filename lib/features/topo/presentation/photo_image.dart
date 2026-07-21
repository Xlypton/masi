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
/// `cacheWidth`/`cacheHeight` — so a small on-screen tile (e.g. a 52px list
/// thumbnail) doesn't pay the memory/CPU cost of decoding a full-resolution
/// original at its native size. Omitted by default (decode at native size,
/// the pre-existing behavior) so every other call site is unaffected.
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
