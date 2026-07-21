import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/db/database_provider.dart';
import '../../account/application/auth_providers.dart';
import '../../topo/domain/topo_route.dart';
import '../data/comments_repository.dart';
import 'comments_providers.dart';
import 'likes_providers.dart';
import 'shared_wall_hydration_providers.dart';

// NOTE: routes are now scoped per-photo (a wall/topo can carry several
// photos, each with its own route overlay — see `RouteRepository`'s class
// doc). `routeEntriesForWallProvider` isn't multi-photo-aware yet (the
// Community topo-detail screen only ever shows ONE embedded canvas per
// wall today), so it resolves the wall's PRIMARY photo via
// `PhotoRepository.loadOriginal` and reads that photo's routes — the same
// photo `TopoCanvasScreen` opens by default for this wall.

/// A single non-deleted route on a wall, paired with its real DB row id.
///
/// [TopoRoute.id] is a locally-reassigned sequential int (see that class's
/// doc) — not a stable identity another table can reference —
/// [AscentsRepository.logAscent]'s `routeId` needs the route's real,
/// stable DB `id` instead. [RouteRepository.routeDbIdsByNumber] is what
/// resolves it, keyed by [TopoRoute.number] (stable per wall).
typedef RouteEntry = ({TopoRoute route, String dbId});

/// Every non-deleted route on [wallId], each paired with its real DB row
/// id (see [RouteEntry]) — backs `CommunityTopoDetailScreen`'s "log ascent"
/// list.
///
/// Deliberately reads straight from [routeRepositoryProvider] rather than
/// depending on `drawControllerProvider` (the app-lifetime-global canvas
/// state the embedded read-only `TopoCanvasScreen` populates): that global
/// is keyed to "whichever wall's canvas was opened last," and this screen
/// must show the right wall's routes regardless of that global's state or
/// load timing.
final routeEntriesForWallProvider =
    FutureProvider.family<List<RouteEntry>, String>((ref, wallId) async {
      final photo = await ref.watch(photoRepositoryProvider).loadOriginal(wallId);
      if (photo == null) return const [];

      final routeRepo = ref.watch(routeRepositoryProvider);
      final routes = await routeRepo.loadRoutes(wallId, photo.id);
      // Scope to the SAME photo as `loadRoutes` above (mirrors
      // `topo_canvas_screen.dart`'s call) — on a multi-photo wall, routes
      // are numbered independently per photo (see `RouteRepository`'s class
      // doc), so an unscoped lookup here could resolve `number` against a
      // DIFFERENT photo's route and attribute a logged ascent to the wrong
      // route entirely.
      final dbIds = await routeRepo.routeDbIdsByNumber(wallId, photo.id);
      return [
        for (final route in routes)
          if (dbIds[route.number] != null)
            (route: route, dbId: dbIds[route.number]!),
      ];
    });

/// Live count of ACTIVE likes on [wallId] — a thin `StreamProvider.family`
/// wrapper around [LikesRepository.watchLikeCountForWall] so
/// `CommunityTopoDetailScreen` can watch it directly.
final likeCountForWallProvider = StreamProvider.family<int, String>(
  (ref, wallId) =>
      ref.watch(likesRepositoryProvider).watchLikeCountForWall(wallId),
);

/// Whether the current owner (or this device, if signed out) has an ACTIVE
/// like on [wallId] right now.
///
/// A one-shot read (not a stream: [LikesRepository] exposes no
/// `watchHasLiked`) — `CommunityTopoDetailScreen` invalidates this family
/// member via `ref.invalidate` immediately after every
/// [LikesRepository.toggleLike] call so the heart glyph flips right away.
final hasLikedWallProvider = FutureProvider.family<bool, String>(
  (ref, wallId) => ref.watch(likesRepositoryProvider).hasLiked(wallId),
);

/// Live list of non-deleted comments on [wallId] — a thin
/// `StreamProvider.family` wrapper around
/// [CommentsRepository.watchCommentsForWall].
final commentsForWallProvider = StreamProvider.family<List<Comment>, String>(
  (ref, wallId) =>
      ref.watch(commentsRepositoryProvider).watchCommentsForWall(wallId),
);

/// The `ownerId` stamped on wall [wallId]'s row (or `null` if it's unowned,
/// doesn't exist, or has been soft-deleted). Backs `CommunityTopoDetailScreen`'s
/// "by `<author>`" byline via [profileDisplayNameProvider] — Feature #15 Wave
/// 3's whole point is a cold/signed-out visitor landing on a shared topo,
/// who has no other way to tell whose it is. Mirrors
/// `community_feed_screen.dart`'s `_FeedRow`/`_AscentFeedRow` owner-name
/// resolution (same `profileDisplayNameProvider` + "Unknown climber"-style
/// fallback convention), just resolving the wall's owner directly rather
/// than reading it off an already-loaded feed row.
final wallOwnerIdProvider = FutureProvider.autoDispose.family<String?, String>(
  (ref, wallId) async {
    final db = ref.watch(appDatabaseProvider);
    final row = await (db.select(db.walls)
          ..where((t) => t.id.equals(wallId) & t.deletedAt.isNull())
          ..limit(1))
        .getSingleOrNull();
    return row?.ownerId;
  },
);

/// Live count of ACTIVE likes on the ascent log [ascentId] — ascent-targeted
/// mirror of [likeCountForWallProvider] (Feature #12: public opt-in ascent
/// logs can be liked like shared topos), wrapping
/// [LikesRepository.watchLikeCountForAscent].
final likeCountForAscentProvider = StreamProvider.family<int, String>(
  (ref, ascentId) =>
      ref.watch(likesRepositoryProvider).watchLikeCountForAscent(ascentId),
);

/// Whether the current owner (or this device, if signed out) has an ACTIVE
/// like on the ascent log [ascentId] right now — ascent-targeted mirror of
/// [hasLikedWallProvider]. A one-shot read, same invalidate-after-toggle
/// pattern as [hasLikedWallProvider] — see its doc.
final hasLikedAscentProvider = FutureProvider.family<bool, String>(
  (ref, ascentId) =>
      ref.watch(likesRepositoryProvider).hasLikedAscent(ascentId),
);

/// Live list of non-deleted comments on the ascent log [ascentId] —
/// ascent-targeted mirror of [commentsForWallProvider], wrapping
/// [CommentsRepository.watchCommentsForAscent].
final commentsForAscentProvider =
    StreamProvider.family<List<Comment>, String>(
      (ref, ascentId) => ref
          .watch(commentsRepositoryProvider)
          .watchCommentsForAscent(ascentId),
    );

/// Display name derived from the signed-in user's email (the local part,
/// before '@'), or `'Anonymous'` when signed out / no email is known.
///
/// Used to stamp new comments' `authorName`. Deliberately a separate
/// derivation from `email_initials.dart`'s `emailInitials` (which produces
/// 1-2 uppercase initials for an avatar glyph, not a display name) — a
/// different consumer, a different shape.
///
/// Reading [authStateProvider] rather than [currentUidProvider] (used by
/// the repositories themselves for `ownerId` stamping) because only the
/// former carries the human-readable email; [currentUidProvider] only
/// exposes the opaque Supabase Auth uid.
final currentAuthorNameProvider = Provider<String>((ref) {
  final email = ref.watch(authStateProvider).asData?.value.email;
  if (email == null) return 'Anonymous';
  final at = email.indexOf('@');
  return at > 0 ? email.substring(0, at) : email;
});

/// Feature #15 Wave 3: gates `CommunityTopoDetailScreen`'s cold-visitor
/// hydration. Resolves to `true` once wall [wallId] is (or already was)
/// present in local Drift, or `false` if hydration ran and it's STILL not
/// there — meaning the link doesn't point at a real, currently-shared topo
/// (not found, or exists but `visibility != 'shared'`; anon RLS makes those
/// two indistinguishable — see [SharedWallHydrator.ensureSharedWallLocal]'s
/// doc). The screen renders a graceful "not found" state for `false` rather
/// than crashing or hanging on an indefinitely-empty canvas.
///
/// Deliberately checks local presence FIRST via a bare Drift query, and
/// only falls through to [ensureSharedWallLocalProvider] — which, the
/// moment it's watched AT ALL (even on its own fast no-op path), eagerly
/// constructs the Supabase-wired `sharedWallHydratorProvider` ->
/// `sharedWallRemoteProvider` -> `supabaseClientProvider` chain, since that
/// chain is built from plain (non-async) `Provider`s evaluated at first
/// read — when the wall is genuinely absent locally. This keeps the common
/// case (a signed-in owner viewing their own already-local wall, or a
/// visitor re-opening an already-hydrated one) from ever touching
/// `supabaseClientProvider`, matching every existing (signed-in,
/// no-Supabase-override) test in this suite, and avoids a redundant
/// network round trip on every rebuild (the hydrator's own fast-path
/// already short-circuits per-call, but this skips even the ATTEMPT).
final wallReadyForDetailProvider =
    FutureProvider.autoDispose.family<bool, String>((ref, wallId) async {
      final db = ref.watch(appDatabaseProvider);
      Future<bool> existsLocally() async {
        final row = await (db.select(db.walls)
              ..where((t) => t.id.equals(wallId) & t.deletedAt.isNull())
              ..limit(1))
            .getSingleOrNull();
        return row != null;
      }

      if (await existsLocally()) return true;
      await ref.watch(ensureSharedWallLocalProvider(wallId).future);
      return existsLocally();
    });
