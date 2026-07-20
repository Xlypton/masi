// Web-only LRU cache mapping a photo's byte-store key to a browser Blob
// object URL, backing `PhotoImage`/`PhotoImageProvider`'s web rendering path
// (see `../presentation/photo_image_source_web.dart`).
//
// Why this exists: on web, a photo's pixels live in IndexedDB
// (`PhotoByteStore`), not on a filesystem `Image.file` can point at
// directly. Rendering therefore means reading bytes out of IndexedDB (async,
// relatively slow) and handing them to the browser via a `Blob` + object URL
// (`URL.createObjectURL`) that `Image.network` can load. Doing that fresh on
// every rebuild would mean: (a) a repeat IndexedDB read for a photo already
// on screen, and (b) leaking one object URL per read — the browser pins the
// referenced bytes in memory until `URL.revokeObjectURL` is called, and
// nothing does that automatically. This cache fixes both: object URLs are
// kept (keyed by the same logical `photos/<id><ext>` / `thumbs/<id>.jpg`
// string every other `PhotoFiles` API uses) until the cache is over budget,
// at which point the LEAST-recently-used entries are evicted and their URLs
// explicitly revoked.
//
// Wasm-clean: built only on `dart:js_interop` + `package:web` (the same
// bindings `image_ops_web.dart` uses for its own Blob/canvas work) — no
// `dart:html`/`dart:indexed_db`.
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

/// Single-instance LRU cache of photo byte-store key -> object URL.
///
/// A single global instance ([instance]) is deliberate: the same photo is
/// typically referenced from more than one place at once (e.g. a topo's
/// canvas background AND its dimension-probe [PhotoImageProvider] resolve
/// the exact same key) and — per this class's whole point — must share one
/// cached URL rather than each maintaining its own.
class PhotoImageCache {
  PhotoImageCache._();

  /// The process-wide cache. Not injectable: there is exactly one browser
  /// document's worth of object URLs to manage, and every caller wants the
  /// same one (see class doc).
  static final PhotoImageCache instance = PhotoImageCache._();

  /// Soft budget, in bytes of cached ENCODED photo bytes (not decoded pixel
  /// buffers — that figure isn't known until each image actually decodes,
  /// and isn't worth tracking separately here). ~96MB comfortably holds
  /// several dozen full-resolution phone photos, or many hundreds of the
  /// 512px-max-edge thumbnails ([thumbKeyFor]'s targets) that dominate most
  /// screens (topo strip, library/community lists).
  static const int maxBytes = 96 * 1024 * 1024;

  /// Insertion-ordered map doubling as the LRU list: [_touch] re-inserts an
  /// entry to move it to the end (most-recently-used), so the LEAST-recently
  /// -used entry is always whatever [Map.keys] yields first.
  final Map<String, _Entry> _entries = <String, _Entry>{};

  /// De-dupes concurrent cold reads of the SAME key (e.g. a widget rebuild
  /// firing a second [resolveUrl] before the first's IndexedDB read has
  /// returned) onto a single in-flight future, rather than issuing two
  /// redundant reads and creating two separate object URLs for one key.
  final Map<String, Future<String?>> _pending = <String, Future<String?>>{};

  int _totalBytes = 0;

  /// Synchronous fast path: the object URL already cached for [key], or
  /// `null` if nothing is cached yet.
  ///
  /// This is the ONLY way to consult the cache from a context that cannot
  /// await — a canvas mount's first build, or a Drift stream's synchronous
  /// row-mapper — mirroring why `PhotoFiles.resolvePhotoPathSync` exists
  /// alongside the awaited `resolvePhotoPath`. Callers that get `null` here
  /// should render a placeholder AND call [resolveUrl] to populate the
  /// cache for next time.
  String? photoUrlSync(String key) {
    final entry = _entries[key];
    if (entry == null) return null;
    _touch(key, entry);
    return entry.url;
  }

  /// Async cache-through: returns [key]'s cached URL immediately if present
  /// (via [photoUrlSync]); otherwise reads bytes via [readBytes] (typically
  /// `PhotoFiles.readPhotoBytes`), wraps them in a `Blob`, mints a fresh
  /// object URL, caches it, and returns it. Returns `null` if [readBytes]
  /// itself returns `null` (photo genuinely missing) — never throws.
  Future<String?> resolveUrl(
    String key,
    Future<Uint8List?> Function() readBytes,
  ) {
    final cached = photoUrlSync(key);
    if (cached != null) return Future<String?>.value(cached);

    final inFlight = _pending[key];
    if (inFlight != null) return inFlight;

    final future = _load(key, readBytes);
    _pending[key] = future;
    return future.whenComplete(() => _pending.remove(key));
  }

  Future<String?> _load(
    String key,
    Future<Uint8List?> Function() readBytes,
  ) async {
    try {
      final bytes = await readBytes();
      if (bytes == null) return null;
      final blob = web.Blob(<web.BlobPart>[bytes.toJS].toJS);
      final url = web.URL.createObjectURL(blob);
      _insert(key, url, bytes.length);
      return url;
    } catch (_) {
      return null;
    }
  }

  void _insert(String key, String url, int size) {
    // Drop any existing entry for this key first (revoking its now-orphaned
    // URL) — a re-insert should never leak the URL it's replacing.
    final previous = _entries.remove(key);
    if (previous != null) {
      _totalBytes -= previous.size;
      if (previous.url != url) web.URL.revokeObjectURL(previous.url);
    }
    _entries[key] = _Entry(url, size);
    _totalBytes += size;
    _evictIfNeeded();
  }

  void _touch(String key, _Entry entry) {
    _entries.remove(key);
    _entries[key] = entry; // re-insert => most-recently-used (at the end).
  }

  void _evictIfNeeded() {
    while (_totalBytes > maxBytes && _entries.isNotEmpty) {
      final oldestKey = _entries.keys.first;
      final oldest = _entries.remove(oldestKey);
      if (oldest == null) break;
      _totalBytes -= oldest.size;
      web.URL.revokeObjectURL(oldest.url);
    }
  }
}

class _Entry {
  _Entry(this.url, this.size);
  final String url;
  final int size;
}
