// Fallback used when neither `dart:io` nor `dart:js_interop` is available.
//
// Mirrors `../data/photo_files_stub.dart`'s own doc: the analyzer resolves a
// conditional-export facade like `photo_image_source.dart` to THIS
// unconditional branch for static analysis regardless of platform (only the
// real compiler picks the platform-correct native/web branch at build
// time), so this stub's public API must stay signature-identical to the
// real native/web variants (`photo_image_source_native.dart`/
// `photo_image_source_web.dart`) — exactly like this project's other
// conditional-export facades (`lib/core/db/connection/`,
// `lib/features/topo/data/image_ops/`, `lib/features/topo/data/
// photo_files_stub.dart`).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/photo_files.dart';

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
  Widget build(BuildContext context, WidgetRef ref) =>
      throw UnsupportedError('No PhotoImage backend available on this platform.');
}

ImageStream resolvePhotoImageStream(
  String storedPath,
  ImageConfiguration configuration,
  PhotoFiles photoFiles,
) => throw UnsupportedError('No PhotoImage backend available on this platform.');
