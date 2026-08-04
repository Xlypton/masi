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
///  * De-duplicates concurrent requests for the same photo, so N widgets
///    showing one photo cause ONE fetch.
///  * Remembers recent failures for [MissingPhotoByteResolver.negativeTtl], so a
///    genuinely absent object (or an offline device) cannot turn a rebuilding
///    widget into a retry storm.
///  * Offline is a clean no-op: the fetch throws, it is swallowed, `null` comes
///    back, and the placeholder stays — no error spew, no state change.
library;

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
    DateTime Function()? now,
    // Private fields with named params, matching `SyncService`'s and
    // `PublicPhotoPruneService`'s house pattern: a named parameter cannot
    // itself be private, so the initializing formal the lint asks for is not
    // expressible here.
  }) : _remote = remote, // ignore: prefer_initializing_formals
       _photoFiles = photoFiles, // ignore: prefer_initializing_formals
       _now = now ?? DateTime.now;

  final SyncRemote _remote;
  final PhotoFiles _photoFiles;
  final DateTime Function() _now;

  @override
  final Duration negativeTtl;

  /// canonical photo id -> the in-flight fetch for it.
  ///
  /// The whole point of the dedup: a wall's photo strip, its canvas and its feed
  /// card can all mount in the same frame and all ask for the same photo. One
  /// fetch, one write, one set of bytes handed to all three. Entries are removed
  /// once the fetch settles, so a LATER request re-fetches (this is not a
  /// positive cache — `PhotoFiles` is).
  final Map<String, Future<Uint8List?>> _inFlight = {};

  /// canonical photo id -> when its last attempt failed. Bounded implicitly by
  /// the number of distinct photos ever asked for in one session, and each entry
  /// is dropped the moment it expires or succeeds.
  final Map<String, DateTime> _recentFailures = {};

  @override
  Future<Uint8List?> resolve(String storedKey) {
    final photoId = p.basenameWithoutExtension(storedKey);
    final ext = p.extension(storedKey);
    // No id means no addressable object. Nothing to ask for.
    if (photoId.isEmpty || ext.isEmpty) return Future<Uint8List?>.value();

    final failedAt = _recentFailures[photoId];
    if (failedAt != null) {
      if (_now().difference(failedAt) < negativeTtl) {
        return Future<Uint8List?>.value();
      }
      _recentFailures.remove(photoId);
    }

    final existing = _inFlight[photoId];
    if (existing != null) return existing;

    final future = _fetch(photoId, ext);
    _inFlight[photoId] = future;
    return future;
  }

  Future<Uint8List?> _fetch(String photoId, String ext) async {
    try {
      final bytes = await _remote.downloadSharedPhoto(
        sharedPhotoPath(photoId, ext),
      );
      if (bytes == null || bytes.isEmpty) {
        // A genuinely absent object: the wall was unshared, the owner deleted
        // it, or it never uploaded. Remember that, or every rebuild re-asks.
        _recentFailures[photoId] = _now();
        return null;
      }
      final data = Uint8List.fromList(bytes);
      try {
        await _photoFiles.writePhotoBytes(photoId, ext, data);
      } catch (_) {
        // The cache write failed (quota exhaustion is the realistic cause, and
        // the pruner is the answer to it). The bytes are in hand either way, so
        // still hand them back — the photo renders this time, and next time
        // this path runs again. Deliberately NOT a negative-cache entry: the
        // fetch succeeded; it is local storage that is full.
      }
      return data;
    } catch (_) {
      // Offline, a Storage error, an unavailable remote — all the same to the
      // caller, and all a clean no-op. The negative entry is what keeps an
      // offline device from re-attempting on every frame.
      _recentFailures[photoId] = _now();
      return null;
    } finally {
      _inFlight.remove(photoId);
    }
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
    );
  } catch (_) {
    return const NoopMissingPhotoByteResolver();
  }
});
