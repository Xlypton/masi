// Native (iOS/Android/desktop) backend for `photo_image.dart`'s
// `PhotoImage`/`PhotoImageProvider`: a thin pass-through to `Image.file`/
// `FileImage`, preserving those widgets' exact rendering/error semantics —
// this migration's whole point is to move `dart:io` OUT of shared/
// presentation code without changing native behavior at all.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/db/database_provider.dart';
import '../data/photo_files.dart';

/// Native rendering: resolves [storedPath] via
/// [PhotoFiles.resolvePhotoPathSync] (a no-op for callers that already pass
/// an absolute, already-resolved path — see `photo_image.dart`'s doc) and
/// renders it with plain `Image.file`, byte-for-byte the same widget every
/// migrated call site used before this migration.
///
/// #56: [loadingPlaceholder], when given, is wired to `Image.file`'s own
/// `frameBuilder` — `frame == null` (and not synchronously loaded, e.g. an
/// already-decoded/cached image reappearing) means the decode genuinely
/// hasn't produced a frame yet, distinct from `errorBuilder`'s "this photo
/// can't be shown at all" (still [placeholder]). Omitting
/// [loadingPlaceholder] leaves `frameBuilder` `null`, i.e. `Image`'s own
/// default (instant) behavior — unchanged from before this param existed.
/// [cacheWidth]/[cacheHeight] pass straight through to `Image.file`'s decode
/// size hints.
class PlatformPhotoImage extends ConsumerWidget {
  const PlatformPhotoImage({
    super.key,
    required this.storedPath,
    required this.fit,
    this.width,
    this.height,
    this.placeholder,
    this.loadingPlaceholder,
    this.cacheWidth,
    this.cacheHeight,
  });

  final String storedPath;
  final BoxFit fit;
  final double? width;
  final double? height;
  final Widget Function()? placeholder;
  final Widget Function()? loadingPlaceholder;
  final int? cacheWidth;
  final int? cacheHeight;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final photoFiles = ref.watch(photoFilesProvider);
    final resolvedPath = photoFiles.resolvePhotoPathSync(storedPath).path;
    return Image.file(
      File(resolvedPath),
      fit: fit,
      width: width,
      height: height,
      cacheWidth: cacheWidth,
      cacheHeight: cacheHeight,
      frameBuilder: loadingPlaceholder == null
          ? null
          : (context, child, frame, wasSynchronouslyLoaded) {
              if (wasSynchronouslyLoaded || frame != null) return child;
              return loadingPlaceholder!.call();
            },
      errorBuilder: (context, error, stackTrace) =>
          placeholder?.call() ?? const SizedBox.shrink(),
    );
  }
}

/// Native dimension-probe: identical to the old direct
/// `FileImage(File(path)).resolve(configuration)` call sites used, just
/// resolved through [PhotoFiles.resolvePhotoPathSync] first (again, a no-op
/// for an already-resolved [storedPath]).
ImageStream resolvePhotoImageStream(
  String storedPath,
  ImageConfiguration configuration,
  PhotoFiles photoFiles,
) {
  final resolvedPath = photoFiles.resolvePhotoPathSync(storedPath).path;
  return FileImage(File(resolvedPath)).resolve(configuration);
}
