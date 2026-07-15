import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/db/database_provider.dart';
import '../../account/application/auth_providers.dart';
import '../../topo/domain/topo_route.dart';
import '../data/comments_repository.dart';
import 'comments_providers.dart';
import 'likes_providers.dart';

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
      final routeRepo = ref.watch(routeRepositoryProvider);
      final routes = await routeRepo.loadRoutes(wallId);
      final dbIds = await routeRepo.routeDbIdsByNumber(wallId);
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
