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
class PlatformPhotoImage extends ConsumerWidget {
  const PlatformPhotoImage({
    super.key,
    required this.storedPath,
    required this.fit,
    this.width,
    this.height,
    this.placeholder,
  });

  final String storedPath;
  final BoxFit fit;
  final double? width;
  final double? height;
  final Widget Function()? placeholder;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final photoFiles = ref.watch(photoFilesProvider);
    final resolvedPath = photoFiles.resolvePhotoPathSync(storedPath).path;
    return Image.file(
      File(resolvedPath),
      fit: fit,
      width: width,
      height: height,
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
