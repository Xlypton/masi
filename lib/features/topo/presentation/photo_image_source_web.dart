// Web backend for `photo_image.dart`'s `PhotoImage`/`PhotoImageProvider`.
//
// There is no filesystem to point `Image.file`/`FileImage` at on web —
// photo/thumbnail bytes live in IndexedDB (`PhotoByteStore`, via
// `PhotoFiles.readPhotoBytes`). Rendering therefore goes bytes -> `Blob` ->
// object URL (via the shared `PhotoImageCache`, so the same photo referenced
// from more than one place at once — e.g. a canvas background AND its own
// dimension probe — shares one cached URL and one IndexedDB read) ->
// `Image.network`, letting the browser decode the object URL off Flutter's
// own image-codec path rather than piping raw bytes through `Image.memory`.
//
// Wasm-clean: only `dart:js_interop`/`package:web` (via `PhotoImageCache`)
// and plain Flutter APIs — no `dart:html`.
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/db/database_provider.dart';
import '../data/missing_photo_byte_resolver.dart';
import '../data/photo_files.dart';
import '../data/photo_image_cache_web.dart';
import 'photo_image_self_heal_guard.dart';

/// Web rendering: shows [PhotoImageCache]'s cached object URL for
/// [storedPath] via `Image.network` the moment it's available — synchronously
/// (no placeholder flash) if already cached, otherwise the [placeholder]
/// (or, if given, [loadingPlaceholder] — see #56 below) while a background
/// IndexedDB read populates the cache.
///
/// #56: [loadingPlaceholder], when given, shows while resolution is still
/// PENDING (the cache-through IndexedDB read hasn't completed yet — tracked
/// by [_PlatformPhotoImageState._resolved]); once resolution completes,
/// whether to a real URL (renders the photo) or to `null` (bytes genuinely
/// not found), the pending window is over and a `null` result falls through
/// to [placeholder] instead — so a missing photo never shows
/// [loadingPlaceholder] forever. Omitting [loadingPlaceholder] preserves the
/// exact pre-existing behavior: [placeholder] alone covers the whole
/// pending-or-missing `_url == null` window. [cacheWidth]/[cacheHeight] pass
/// straight through to `Image.network`'s decode size hints.
class PlatformPhotoImage extends ConsumerStatefulWidget {
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
  ConsumerState<PlatformPhotoImage> createState() =>
      _PlatformPhotoImageState();
}

class _PlatformPhotoImageState extends ConsumerState<PlatformPhotoImage> {
  String? _key;
  String? _url;

  /// #56: `true` once resolution has completed for the CURRENT [_key] —
  /// whether it landed on a real URL or confirmed-missing (`null`). `false`
  /// means still pending: [_url] is `null` but that's not yet a verdict, so
  /// [loadingPlaceholder] (not [placeholder]) is what should show. Reset to
  /// `false` whenever [_key] changes in [_ensureUrl], alongside [_url]
  /// itself and [_failedUrl].
  bool _resolved = false;

  /// Non-null once we've attempted a self-heal re-resolve for the CURRENT
  /// [_key] (see [_handleLoadError]) — the URL that triggered that attempt.
  /// Reset to `null` whenever [_key] changes in [_ensureUrl]. Its only job
  /// is to cap self-heal at one attempt per key: [PhotoImageCache] can evict
  /// and `URL.revokeObjectURL` an object URL a still-mounted widget (e.g. an
  /// inactive `IndexedStack` tab) is holding in [_url], which makes
  /// `Image.network` fail with no built-in retry; the first such failure
  /// re-resolves through the cache (which re-reads the still-present
  /// IndexedDB bytes into a fresh Blob/URL) and swaps it in, but a second
  /// failure for the same key — genuinely-missing bytes, or a re-resolved
  /// URL that fails again — falls straight through to the placeholder
  /// instead of retrying forever.
  String? _failedUrl;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _ensureUrl();
  }

  @override
  void didUpdateWidget(PlatformPhotoImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.storedPath != widget.storedPath) _ensureUrl();
  }

  /// Resolves [PlatformPhotoImage.storedPath] to its cache key and, if it
  /// changed, either adopts the cache's already-known URL synchronously (the
  /// fast path — see [PhotoImageCache.photoUrlSync]'s doc) or kicks the async
  /// cache-through read and swaps `_url` in once it resolves.
  void _ensureUrl() {
    final photoFiles = ref.read(photoFilesProvider);
    final key = photoFiles.resolvePhotoPathSync(widget.storedPath).path;
    if (key == _key) return;
    _key = key;
    _failedUrl = null; // New key: any earlier self-heal attempt is moot.
    _resolved = false;

    final cached = PhotoImageCache.instance.photoUrlSync(key);
    if (cached != null) {
      _url = cached;
      _resolved = true;
      return;
    }
    _url = null;
    unawaited(
      PhotoImageCache.instance
          .resolveUrl(key, () => _readOrFetchBytes(photoFiles, key))
          .then((url) {
            if (!mounted || _key != key) return;
            setState(() {
              _url = url;
              _resolved = true;
            });
          }),
    );
  }

  /// The byte source both [PhotoImageCache.resolveUrl] calls in this class read
  /// through: this device's own copy first, and — only when it does not have
  /// one — ONE on-demand fetch of the shared copy via
  /// [missingPhotoByteResolverProvider].
  ///
  /// This is the render-path half of the bounded public-photo pull. A pull
  /// downloads at most a byte budget of OTHER climbers' photos and
  /// `PublicPhotoPruneService` evicts foreign bytes again under storage
  /// pressure, so a public `Photos` row can legitimately exist locally as
  /// metadata with NO bytes — which without this renders as a permanent
  /// placeholder with no path back (see `missing_photo_byte_resolver.dart`).
  /// Fetching from the widget build path is safe because the resolver
  /// de-duplicates concurrent requests per photo id, keeps a one-minute
  /// negative cache, and NEVER throws (offline answers `null`); and because
  /// [PhotoImageCache.resolveUrl] itself caches and de-dups per key, so at most
  /// one fetch is ever in flight for a key no matter how many widgets show it.
  ///
  /// A `null` result is unchanged from before: [PhotoImageCache.resolveUrl]
  /// resolves to `null`, [_resolved] flips true, and [build] falls through to
  /// the static `placeholder` — so a genuinely-absent photo still stops looking
  /// like a loading one, while a fetch in progress keeps showing
  /// `loadingPlaceholder` for as long as it runs.
  Future<Uint8List?> _readOrFetchBytes(PhotoFiles photoFiles, String key) async {
    final local = await photoFiles.readPhotoBytes(key);
    if (local != null) return local;
    return ref.read(missingPhotoByteResolverProvider).resolve(key);
  }

  /// Called from [Image.network]'s `errorBuilder` when [failedUrl] — the URL
  /// currently in [_url] — fails to load. The common web-only cause: this
  /// widget stayed mounted (e.g. its tab went inactive under the nav shell's
  /// `IndexedStack`) while [PhotoImageCache] revoked that object URL as part
  /// of its byte-budget LRU eviction, out from under us. Since the
  /// underlying IndexedDB bytes are still there, re-resolving through the
  /// cache mints a fresh Blob + object URL and heals the display.
  ///
  /// Guarded against looping: bails out (leaving the placeholder from this
  /// failed frame in place) if the error is stale (no longer for the
  /// current [_url]/[_key]), if a self-heal was already attempted for this
  /// key ([_failedUrl] non-null), or if re-resolution comes back `null`
  /// (bytes genuinely gone) or throws. At most one re-resolve attempt is
  /// ever made per key.
  void _handleLoadError(String failedUrl) {
    if (!mounted) return;
    final key = _key;
    if (key == null ||
        !shouldAttemptPhotoSelfHeal(
          failedUrl: failedUrl,
          currentUrl: _url,
          alreadyAttemptedUrl: _failedUrl,
        )) {
      return;
    }
    _failedUrl = failedUrl;

    final photoFiles = ref.read(photoFilesProvider);
    unawaited(
      PhotoImageCache.instance
          .resolveUrl(key, () => _readOrFetchBytes(photoFiles, key))
          .then((url) {
            if (!mounted || _key != key) return;
            if (!isSuccessfulPhotoSelfHeal(
              resolvedUrl: url,
              failedUrl: failedUrl,
            )) {
              return; // Bytes genuinely gone (or a defensive same-URL echo)
              // — leave the placeholder from the failed frame in place.
            }
            setState(() => _url = url);
          })
          .catchError((_) {
            // Re-resolution itself never throws per its own contract, but
            // guard anyway: fall through to the placeholder, don't loop.
          }),
    );
  }

  @override
  Widget build(BuildContext context) {
    final url = _url;
    if (url == null) {
      // #56: still pending (not yet resolved either way) shows
      // loadingPlaceholder when given; a CONFIRMED-missing result
      // (_resolved true, url still null) always falls through to the
      // static placeholder, so a genuinely missing photo never shimmers
      // forever.
      if (!_resolved) {
        return widget.loadingPlaceholder?.call() ??
            widget.placeholder?.call() ??
            const SizedBox.shrink();
      }
      return widget.placeholder?.call() ?? const SizedBox.shrink();
    }
    return Image.network(
      url,
      fit: widget.fit,
      width: widget.width,
      height: widget.height,
      cacheWidth: widget.cacheWidth,
      cacheHeight: widget.cacheHeight,
      errorBuilder: (context, error, stackTrace) {
        _handleLoadError(url);
        return widget.placeholder?.call() ?? const SizedBox.shrink();
      },
    );
  }
}

/// Web dimension-probe: mirrors `FileImage(...).resolve(configuration)`'s
/// contract (an [ImageStream] that eventually reports an [ImageInfo] with
/// real `image.width`/`image.height`) by resolving the cached/loaded object
/// URL and delegating to a real `NetworkImage` for the actual decode —
/// [OneFrameImageStreamCompleter] handles both the success and error path
/// (a `null` URL, i.e. no bytes found, surfaces as a stream error, matching
/// what a genuinely-missing file would do via `FileImage`'s own decode
/// failure).
ImageStream resolvePhotoImageStream(
  String storedPath,
  ImageConfiguration configuration,
  PhotoFiles photoFiles,
) {
  final key = photoFiles.resolvePhotoPathSync(storedPath).path;
  final stream = ImageStream();
  stream.setCompleter(
    OneFrameImageStreamCompleter(
      _loadImageInfo(key, configuration, photoFiles),
    ),
  );
  return stream;
}

Future<ImageInfo> _loadImageInfo(
  String key,
  ImageConfiguration configuration,
  PhotoFiles photoFiles,
) async {
  final url =
      PhotoImageCache.instance.photoUrlSync(key) ??
      await PhotoImageCache.instance.resolveUrl(
        key,
        () => photoFiles.readPhotoBytes(key),
      );
  if (url == null) {
    throw StateError('PhotoImage: no bytes found for "$key"');
  }

  final completer = Completer<ImageInfo>();
  final innerStream = NetworkImage(url).resolve(configuration);
  late final ImageStreamListener listener;
  listener = ImageStreamListener(
    (info, synchronousCall) {
      if (!completer.isCompleted) completer.complete(info);
      innerStream.removeListener(listener);
    },
    onError: (error, stackTrace) {
      if (!completer.isCompleted) completer.completeError(error, stackTrace);
      innerStream.removeListener(listener);
    },
  );
  innerStream.addListener(listener);
  return completer.future;
}
