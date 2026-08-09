/// Fetches ONE public photo's bytes on demand, when and only when something is
/// actually trying to show it.
///
/// ## Why this exists
///
/// A pull downloads at most [kSharedPhotoByteBudgetPerPull] of other climbers'
/// photos (see `SyncService._downloadAndRewritePhotos`), and
/// `PublicPhotoPruneService` evicts foreign bytes again under storage pressure.
/// Both are correct — an unbounded first pull costs hundreds of megabytes on a
/// phone browser, and an unbounded cache eventually breaks the user's OWN
/// imports. But both leave the same hole: a `Photos` row whose bytes are absent,
/// which today renders as a permanent gradient placeholder with no path back.
/// The bulk pull is the only caller of `SyncRemote.downloadSharedPhoto` in the
/// app, so nothing ever heals a single photo.
///
/// This is that path. It turns "bounded" from a downgrade into a deferral: the
/// photos the user actually opens arrive, the ones they never scroll to never
/// cost anything, and the working set converges on what is being browsed rather
/// than on the size of the whole community library.
///
/// ## Layering
///
/// Deliberately an interface in the DATA layer with the presentation layer
/// depending only on the interface — the render path must not reach into the
/// sync remote. The Supabase-backed implementation lives here;
/// [NoopMissingPhotoByteResolver] is the default whenever there is no cloud to
/// ask (Supabase never initialised, plain `flutter test`), so a caller can
/// always resolve the provider and always gets a well-behaved `null`.
///
/// ## Safety properties the caller may rely on
///
///  * NEVER throws. A render path cannot afford an exception, and a missing
///    photo is a normal, expected state — see [MissingPhotoByteResolver.resolve].
///  * De-duplicates concurrent requests for the same REMOTE OBJECT, so N
///    widgets showing one photo cause ONE fetch.
///  * Remembers recent failures for [MissingPhotoByteResolver.negativeTtl], so a
///    genuinely absent object (or an offline device) cannot turn a rebuilding
///    widget into a retry storm.
///  * Bounds how many fetches run at once
///    ([SharedMissingPhotoByteResolver.maxConcurrentFetches]), so a screenful
///    of shared rows queues rather than opening one connection per row — and
///    bounds both how long one may HOLD a slot
///    ([SharedMissingPhotoByteResolver.fetchTimeout]) and how long another may
///    WAIT for one ([SharedMissingPhotoByteResolver.slotWaitTimeout]), so a
///    stalled request degrades to one slow photo instead of wedging every
///    photo in the app for the session.
///  * Offline is a clean no-op: the fetch throws, it is swallowed, `null` comes
///    back, and the placeholder stays — no error spew, no state change.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../../core/db/database_provider.dart';
import '../../backup/application/sync_providers.dart';
import '../../backup/data/sync_remote.dart';
import 'photo_files.dart';

/// Fetches the bytes of a single photo this device does not have.
abstract class MissingPhotoByteResolver {
  /// Fetches the bytes for the photo stored (or rather, MEANT to be stored)
  /// under [storedKey] — a `Photos.localPath` value — caches them via
  /// [PhotoFiles.writePhotoBytes], and returns them.
  ///
  /// `null` means "not available, and asking again right now will not help":
  /// no such remote object, offline, no cloud configured, or a very recent
  /// failure for this same key. NEVER throws.
  ///
  /// [storedKey] is interpreted the way `PhotoFiles` builds it — the canonical
  /// photo id is the basename without extension, and the extension is the file
  /// extension (`photos/<photoId><ext>`). That is exactly the form a pulled
  /// cloud row carries, including a row the byte budget skipped: the bulk pull
  /// only rewrites `localPath` when bytes actually arrived, so a skipped row
  /// keeps the publishing device's `photos/<photoId><ext>` and therefore still
  /// names the key its bytes will live under.
  ///
  /// A THUMBNAIL key (`thumbs/<photoId>.jpg`, per `thumbKeyFor` — what every
  /// list row and photo-strip tile actually asks for) resolves the cloud's
  /// small `shared/thumbs/<photoId>.jpg` object, NOT the full-resolution
  /// original. Getting that wrong is what made one 52-pixel tile cost a
  /// multi-megabyte download.
  ///
  /// A SLICE's row points at its ORIGINAL's file (see `photo_files.dart` S1), so
  /// passing a slice's `localPath` resolves the original — which is the right
  /// object, since that is the only one Storage holds.
  Future<Uint8List?> resolve(String storedKey);

  /// How long a failed lookup is remembered before another attempt is allowed.
  Duration get negativeTtl;
}

/// The default: there is no cloud to ask, so nothing can be resolved.
///
/// Used on any platform/session without an initialised Supabase client, and in
/// `flutter test`. Distinct from "the object is missing" only in intent — both
/// answer `null`, which is what keeps every caller identical.
class NoopMissingPhotoByteResolver implements MissingPhotoByteResolver {
  const NoopMissingPhotoByteResolver();

  @override
  Future<Uint8List?> resolve(String storedKey) async => null;

  @override
  Duration get negativeTtl => Duration.zero;
}

/// Fetches one missing photo from the `shared/` prefix of the photo bucket.
///
/// Only the SHARED copy is reachable here, on purpose: the private `<uid>/...`
/// prefix is the owner's own backup, and an own photo missing its bytes is a
/// different problem with a different fix (the unbudgeted own-photo pass of a
/// pull, which already restores it). This path exists for OTHER climbers'
/// photos, which are exactly the ones the byte budget and the pruner leave
/// absent.
class SharedMissingPhotoByteResolver implements MissingPhotoByteResolver {
  SharedMissingPhotoByteResolver({
    required SyncRemote remote,
    required PhotoFiles photoFiles,
    this.negativeTtl = const Duration(minutes: 1),
    this.fetchTimeout = const Duration(seconds: 30),
    this.slotWaitTimeout = const Duration(seconds: 45),
    DateTime Function()? now,
    Future<String?> Function(String photoId)? originalExtFor,
    // Private fields with named params, matching `SyncService`'s and
    // `PublicPhotoPruneService`'s house pattern: a named parameter cannot
    // itself be private, so the initializing formal the lint asks for is not
    // expressible here.
  }) : _remote = remote, // ignore: prefer_initializing_formals
       _photoFiles = photoFiles, // ignore: prefer_initializing_formals
       _now = now ?? DateTime.now,
       // ignore: prefer_initializing_formals
       _originalExtFor = originalExtFor;

  final SyncRemote _remote;
  final PhotoFiles _photoFiles;
  final DateTime Function() _now;

  /// Recovers the ORIGINAL extension of the photo with this canonical id —
  /// the one piece of information a thumbnail key cannot carry (see
  /// [isThumbKey]). Used ONLY for the legacy fallback in [_fetch], and only
  /// after the thumbnail object has already been found absent.
  ///
  /// Optional, and `null` here simply disables that fallback: a resolver built
  /// without a local database (tests, any caller that has no `Photos` table to
  /// consult) still resolves thumbnails and originals correctly, it just can't
  /// rescue a pre-thumbnail-tier publish. Never expected to throw — see
  /// [missingPhotoByteResolverProvider]'s wiring, which swallows.
  final Future<String?> Function(String photoId)? _originalExtFor;

  @override
  final Duration negativeTtl;

  /// How many remote fetches may be in flight at once.
  ///
  /// A screenful of shared list rows mounts in ONE frame, and before this each
  /// row started its own download immediately — a dozen simultaneous requests
  /// competing for the same connection, so every one of them finished late and
  /// the first tile the user was actually looking at finished no sooner than
  /// the last. Three is enough to keep the pipe busy across a mobile RTT while
  /// still finishing the earliest-requested photos first.
  ///
  /// A cap this small is only safe because a slot cannot be held forever — see
  /// [fetchTimeout] and [slotWaitTimeout]. With three slots and no bound on how
  /// long one may be held, three stalled sockets (a captive portal that accepts
  /// the connection and never answers is the realistic one) would stop EVERY
  /// photo in the app from loading for the rest of the session, silently and
  /// with no way back short of a reload.
  static const int maxConcurrentFetches = 3;

  /// Ceiling on a single remote download.
  ///
  /// A request that has not answered in this long is treated exactly like any
  /// other failure: negatively cached, `null` returned, slot released, caller
  /// keeps its placeholder. Generous rather than tight, because the cost of
  /// being wrong in the tight direction is a photo that would have loaded on a
  /// slow connection, while the cost of no bound at all is the wedge described
  /// on [maxConcurrentFetches].
  ///
  /// Injectable for the same reason [negativeTtl] is: a test that had to spend
  /// thirty real seconds proving a stall recovers would never be written.
  final Duration fetchTimeout;

  /// Ceiling on how long a queued fetch waits for one of the
  /// [maxConcurrentFetches] slots before proceeding WITHOUT one.
  ///
  /// The second, independent guard: [fetchTimeout] bounds a slot that is being
  /// held, this bounds a slot that was never handed back — an accounting slip,
  /// a swallowed cancellation, anything that leaks [_activeFetches]. Exceeding
  /// the cap is the deliberate lesser evil: too many connections is a
  /// performance problem, a queue that never drains is a dead screen. Longer
  /// than [fetchTimeout] on purpose, so in the ordinary stalled-download case
  /// the slot is handed over properly rather than through this escape hatch.
  final Duration slotWaitTimeout;

  /// REMOTE OBJECT PATH -> the in-flight fetch for it.
  ///
  /// The whole point of the dedup: a wall's photo strip, its canvas and its feed
  /// card can all mount in the same frame and all ask for the same photo. One
  /// fetch, one write, one set of bytes handed to all three. Entries are removed
  /// once the fetch settles, so a LATER request re-fetches (this is not a
  /// positive cache — `PhotoFiles` is).
  ///
  /// Keyed on the object path rather than the photo id because ONE photo now
  /// has TWO addressable objects (`shared/<id><ext>` and
  /// `shared/thumbs/<id>.jpg`). Under the old id key, a list tile's thumbnail
  /// request and the canvas's full-resolution request for the same photo were
  /// indistinguishable, so whichever arrived second silently received the
  /// other's bytes.
  final Map<String, Future<Uint8List?>> _inFlight = {};

  /// REMOTE OBJECT PATH -> when its last attempt failed. Bounded implicitly by
  /// the number of distinct objects ever asked for in one session, and each
  /// entry is dropped the moment it expires or succeeds.
  ///
  /// Keyed on the object path for a sharper reason than [_inFlight]'s: under
  /// the old id key, a thumbnail probe that 404'd wrote a negative entry that
  /// then suppressed the canvas's request for the SAME photo's original for the
  /// whole [negativeTtl]. That was not slow loading, it was a hard stall — and
  /// it was the common case, because `thumbKeyFor` hard-codes `.jpg` while the
  /// photo's original may well be `.jpeg`, so the probe could not succeed.
  final Map<String, DateTime> _recentFailures = {};

  /// Number of fetches currently holding a slot (see [maxConcurrentFetches]).
  int _activeFetches = 0;

  /// Fetches waiting for a slot, oldest first — so the queue drains in request
  /// order and the row the user scrolled to first is not starved by the ones
  /// below it.
  final List<Completer<void>> _waitingForSlot = [];

  @override
  Future<Uint8List?> resolve(String storedKey) {
    final photoId = p.basenameWithoutExtension(storedKey);
    final ext = p.extension(storedKey);
    // No id means no addressable object. Nothing to ask for.
    if (photoId.isEmpty || ext.isEmpty) return Future<Uint8List?>.value();

    // A thumbnail key's `.jpg` is [thumbKeyFor]'s hard-coded output, NOT the
    // photo's own extension, so it must never be used to address the original.
    final wantsThumbnail = isThumbKey(storedKey);
    final objectPath = wantsThumbnail
        ? sharedThumbPath(photoId)
        : sharedPhotoPath(photoId, ext);

    if (_isNegativelyCached(objectPath)) return Future<Uint8List?>.value();

    final existing = _inFlight[objectPath];
    if (existing != null) return existing;

    final future = _fetch(
      storedKey: storedKey,
      photoId: photoId,
      ext: ext,
      objectPath: objectPath,
      wantsThumbnail: wantsThumbnail,
    );
    _inFlight[objectPath] = future;
    return future;
  }

  /// Whether [objectPath] failed recently enough that asking again now would
  /// not help. Expired entries are dropped as they're read, which is what keeps
  /// [_recentFailures] from growing without bound.
  bool _isNegativelyCached(String objectPath) {
    final failedAt = _recentFailures[objectPath];
    if (failedAt == null) return false;
    if (_now().difference(failedAt) < negativeTtl) return true;
    _recentFailures.remove(objectPath);
    return false;
  }

  Future<Uint8List?> _fetch({
    required String storedKey,
    required String photoId,
    required String ext,
    required String objectPath,
    required bool wantsThumbnail,
  }) async {
    await _acquireSlot();
    try {
      final bytes = await _download(objectPath);
      if (bytes != null) {
        if (!wantsThumbnail) {
          await _cacheOriginal(photoId, ext, bytes);
          return bytes;
        }
        return await _preferIntendedKey(storedKey, bytes);
      }

      if (!wantsThumbnail) return null;

      // LEGACY FALLBACK. Every object published before the thumbnail tier
      // existed has no `shared/thumbs/` companion, and the owner's next push is
      // what backfills it (see [SyncRemote.listSharedPhotoObjectPaths]) — which
      // may be never, for a climber who has moved on. A viewer must not be left
      // staring at a permanent placeholder until then, so fall back to what
      // this path did before the tier existed: fetch the original.
      //
      // The original's extension is the one thing the thumbnail key threw away,
      // hence [_originalExtFor]. Guessing `.jpg` here — which is what the
      // pre-fix code effectively did — is precisely the bug that made a `.jpeg`
      // photo unreachable.
      final originalExt = await _originalExt(photoId);
      if (originalExt == null) return null;

      final originalPath = sharedPhotoPath(photoId, originalExt);
      if (_isNegativelyCached(originalPath)) return null;
      final originalBytes = await _download(originalPath);
      if (originalBytes == null) return null;

      // On WEB — the platform this path actually runs on — writing the original
      // also regenerates the LOCAL thumbnail (`photo_files_web.dart`'s
      // `writePhotoBytes` calls `_writeThumbnailBestEffort`; the native backend
      // deliberately does not), so the re-read below hands the caller the small
      // derived bytes rather than the megabytes just downloaded, and the next
      // render finds the thumbnail locally and never comes here at all. Where
      // no thumbnail gets written the re-read simply misses and the original's
      // bytes are returned — exactly what this path did before the tier
      // existed.
      await _cacheOriginal(photoId, originalExt, originalBytes);
      return await _preferIntendedKey(storedKey, originalBytes);
    } finally {
      _releaseSlot();
      _inFlight.remove(objectPath);
    }
  }

  /// Downloads one shared object, recording a negative entry for it on any
  /// outcome that is not usable bytes. Never throws.
  ///
  /// An EMPTY object counts as absent: it renders nothing and would otherwise
  /// be re-fetched forever.
  ///
  /// Bounded by [fetchTimeout], which is what actually keeps a slot from being
  /// held indefinitely: `downloadSharedPhoto` has no timeout of its own, and a
  /// socket that is accepted but never answered (captive portal, a proxy that
  /// black-holes the request) otherwise never settles at all. A timeout lands
  /// in the `catch` below and is therefore indistinguishable from being
  /// offline — which is exactly right for the caller.
  Future<Uint8List?> _download(String objectPath) async {
    try {
      final bytes = await _remote
          .downloadSharedPhoto(objectPath)
          .timeout(fetchTimeout);
      if (bytes == null || bytes.isEmpty) {
        // A genuinely absent object: the wall was unshared, the owner deleted
        // it, it never uploaded, or (for a thumbnail) it predates the tier.
        // Remember that, or every rebuild re-asks.
        _recentFailures[objectPath] = _now();
        return null;
      }
      return Uint8List.fromList(bytes);
    } catch (_) {
      // Offline, a Storage error, an unavailable remote — all the same to the
      // caller, and all a clean no-op. The negative entry is what keeps an
      // offline device from re-attempting on every frame.
      _recentFailures[objectPath] = _now();
      return null;
    }
  }

  /// Caches a freshly downloaded ORIGINAL under the key `PhotoFiles` would have
  /// written it to. Never throws.
  Future<void> _cacheOriginal(String photoId, String ext, Uint8List data) async {
    try {
      await _photoFiles.writePhotoBytes(photoId, ext, data);
    } catch (_) {
      // The cache write failed (quota exhaustion is the realistic cause, and
      // the pruner is the answer to it). The bytes are in hand either way, so
      // still hand them back — the photo renders this time, and next time
      // this path runs again. Deliberately NOT a negative-cache entry: the
      // fetch succeeded; it is local storage that is full.
    }
  }

  /// The bytes the caller should get for [storedKey], preferring whatever is
  /// now stored UNDER that exact key over [fetched].
  ///
  /// Only ever called for a thumbnail key, where the two can differ:
  ///
  ///  * the legacy fallback downloaded the ORIGINAL, and writing it regenerated
  ///    a local thumbnail — returning [fetched] there would book multiple
  ///    megabytes into `PhotoImageCache` under a key whose byte budget assumes
  ///    a ~30 KB tile, evicting a screenful of real thumbnails to do it;
  ///  * a cloud thumbnail arrived and NOTHING WAS WRITTEN LOCALLY. The read
  ///    misses and [fetched] — already the small object — is handed back, which
  ///    is right for this render but leaves a known gap; see below.
  ///
  /// For an ORIGINAL key the two are the same bytes by construction, so the
  /// caller skips this rather than pay a second multi-megabyte read.
  ///
  /// ## KNOWN GAP — a fetched cloud thumbnail is not persisted
  ///
  /// A foreign row seen only in a LIST is therefore not cached at all: the tile
  /// renders from bytes that are then dropped, so the next cold start re-fetches
  /// it and an offline device shows a placeholder where, before the cloud
  /// thumbnail tier, it showed the photo. (Before the tier this path always
  /// downloaded the ORIGINAL and [_cacheOriginal] wrote it, which on web
  /// regenerated a local thumbnail as a side effect — offline survival paid for
  /// with a multi-megabyte download per 52-pixel tile. Opening the topo still
  /// closes the gap for that photo, because the canvas asks for the ORIGINAL
  /// key and that branch does cache.)
  ///
  /// It is not fixed here because it cannot be: `PhotoFiles` exposes no way to
  /// store bytes at an arbitrary key. `writePhotoBytes(photoId, ext, bytes)`
  /// always writes `photos/<id><ext>`, and putting thumbnail bytes there would
  /// be strictly worse than the gap — `hasPhotoBytes` would then report the
  /// photo present, so the canvas would render the downscaled copy forever with
  /// nothing left to fetch the real original.
  ///
  /// The fix is a new backend method, e.g.
  /// `PhotoFiles.writeThumbnailBytes(String storedKey, Uint8List bytes)`
  /// writing `thumbKeyFor(storedKey)` verbatim (no re-derivation — the cloud
  /// object IS the thumbnail), added to `photo_files_web.dart`,
  /// `photo_files_native.dart` and `photo_files_stub.dart`. This method then
  /// calls it before the re-read below, and the re-read starts hitting.
  Future<Uint8List?> _preferIntendedKey(
    String storedKey,
    Uint8List fetched,
  ) async {
    try {
      return await _photoFiles.readPhotoBytes(storedKey) ?? fetched;
    } catch (_) {
      return fetched;
    }
  }

  /// The original extension for [photoId], or `null` when it cannot be
  /// established. Never throws.
  Future<String?> _originalExt(String photoId) async {
    final lookup = _originalExtFor;
    if (lookup == null) return null;
    try {
      final ext = await lookup(photoId);
      return (ext == null || ext.isEmpty) ? null : ext;
    } catch (_) {
      return null;
    }
  }

  /// Takes one of the [maxConcurrentFetches] slots, waiting in line if they are
  /// all taken. Completes immediately in the common (uncontended) case.
  ///
  /// After [slotWaitTimeout] it stops waiting and proceeds anyway, counting
  /// itself as active so [_releaseSlot] stays balanced. See [slotWaitTimeout]
  /// for why over-running the cap is preferable to blocking.
  Future<void> _acquireSlot() async {
    if (_activeFetches < maxConcurrentFetches) {
      _activeFetches++;
      return;
    }
    final waiter = Completer<void>();
    _waitingForSlot.add(waiter);
    try {
      await waiter.future.timeout(slotWaitTimeout);
    } on TimeoutException {
      _waitingForSlot.remove(waiter);
      // A release that landed in the same microtask turn as the timeout has
      // already TRANSFERRED its slot to this waiter (see [_releaseSlot], which
      // does not decrement), so claiming another one here would double-count.
      if (!waiter.isCompleted) _activeFetches++;
    }
  }

  /// Hands the slot straight to the longest-waiting fetch rather than
  /// decrementing and letting it re-race — which is what keeps [_activeFetches]
  /// an accurate count instead of a high-water mark.
  void _releaseSlot() {
    if (_waitingForSlot.isNotEmpty) {
      _waitingForSlot.removeAt(0).complete();
      return;
    }
    _activeFetches--;
  }
}

/// App-wide [MissingPhotoByteResolver].
///
/// Degrades to [NoopMissingPhotoByteResolver] when [syncRemoteProvider] cannot
/// be read (Supabase never initialised — first-launch-offline, or a test
/// container without Supabase), mirroring `syncServiceProvider`'s guard rather
/// than letting a render path throw at construction.
///
/// ## WEB-ONLY IN PRACTICE — and the native gap that leaves
///
/// This provider is not gated on `kIsWeb` and neither is anything in this file:
/// it is plain data-layer code that would work anywhere. But the only thing that
/// CALLS it is the web display path, `photo_image_source_web.dart`'s
/// `_readOrFetchBytes`. `photo_image_source_native.dart` renders straight from
/// `Image.file` and never asks for a resolve, so on native nothing heals a
/// public photo on demand. That is deliberate, and this paragraph replaces an
/// earlier one which claimed the opposite ("native needs the same healing path")
/// while the wiring never existed — a doc that promised a behaviour the app did
/// not have.
///
/// The gap is real, not hypothetical. The byte budget is NOT web-only: off-web
/// `navigator.storage` does not exist, so `SyncService` reads no pressure and
/// applies the plain count budget of `kSharedPhotoByteBudgetPerPull` foreign
/// photos per pull. So on iOS, a public topo outside the newest budget's worth of
/// foreign photos opens to a canvas with routes drawn over an empty placeholder,
/// and tapping it fetches nothing; it fills in only across successive
/// (30s-throttled, resume-triggered) pulls, a budget's worth at a time. A photo
/// already on the device costs no budget, so it does converge — just slowly, and
/// with no way to ask for the one photo being looked at.
///
/// Why that is accepted rather than fixed here:
///
///  * the app is now WEB-PRIMARY; the native build is deprioritised, and wiring
///    this would mean turning the native display path — whose entire stated
///    contract is "byte-for-byte the same `Image.file` as before this
///    migration" — into a stateful fetch-and-retry widget, verifiable only on a
///    physical device;
///  * the budget is the wrong thing on native anyway. It exists to protect the
///    ORIGIN QUOTA from breaking the user's own imports (`photo_files_web.dart`'s
///    L3 write throws on quota); an iOS documents directory has no such quota and
///    `PublicPhotoPruneService` is a permanent no-op there for exactly that
///    reason. The proportionate native fix is therefore to stop rationing
///    foreign photos on native at all — one condition in
///    `SyncService.pullOwnAndShared`, not a second healing path here.
///
/// If native is ever re-prioritised, do one of those two, and correct this
/// paragraph rather than leaving it describing the old state.
///
/// A plain [Provider] with no `autoDispose`: the in-flight and negative maps ARE
/// the de-duplication, and they only work if every caller shares one instance
/// for the app's lifetime.
final missingPhotoByteResolverProvider = Provider<MissingPhotoByteResolver>((
  ref,
) {
  try {
    return SharedMissingPhotoByteResolver(
      remote: ref.watch(syncRemoteProvider),
      photoFiles: ref.watch(photoFilesProvider),
      // Read LAZILY, inside the callback, rather than watched here: this
      // provider must keep building in a container with no usable database
      // (`flutter test`'s bare `ProviderContainer`), and the lookup is only
      // ever reached on the legacy-fallback path anyway. A throw — disposed
      // container, no database, a query that fails — degrades to "extension
      // unknown", which just declines the fallback.
      originalExtFor: (photoId) async {
        try {
          final database = ref.read(appDatabaseProvider);
          final row =
              await (database.select(database.photos)
                    ..where((t) => t.id.equals(photoId))
                    ..limit(1))
                  .getSingleOrNull();
          final stored = row?.localPath;
          if (stored == null || stored.isEmpty) return null;
          return p.extension(stored);
        } catch (_) {
          return null;
        }
      },
    );
  } catch (_) {
    return const NoopMissingPhotoByteResolver();
  }
});
