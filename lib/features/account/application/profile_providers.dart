import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/db/database_provider.dart';
import '../data/profile_repository.dart';
import 'auth_providers.dart';

/// The [ProfileRepository] wired to the shared [appDatabaseProvider] /
/// [nowMsProvider] / [currentUidProvider], matching the pattern used by
/// `ascentsRepositoryProvider` in `ascents_providers.dart`.
final profileRepositoryProvider = Provider<ProfileRepository>(
  (ref) => ProfileRepository(
    ref.watch(appDatabaseProvider),
    nowMs: ref.watch(nowMsProvider),
    currentUid: ref.watch(currentUidProvider),
  ),
);

/// Reactive display name for the profile row keyed by [uid] (ANY user, not
/// just the signed-in one) — a thin `StreamProvider.family` wrapper around
/// [ProfileRepository.watchDisplayName], mirroring `wallOriginalsProvider`'s
/// shape in `database_provider.dart`. `autoDispose` so a display name
/// resolved for a topo/comment/ascent author that's no longer on screen
/// doesn't stay subscribed app-lifetime for every uid ever seen.
final profileDisplayNameProvider =
    StreamProvider.autoDispose.family<String?, String>(
  (ref, uid) => ref.watch(profileRepositoryProvider).watchDisplayName(uid),
);

/// Reactive display name for the SIGNED-IN user specifically: resolves the
/// current uid from [authStateProvider] and watches
/// [ProfileRepository.watchDisplayName] for it directly. Emits `null`
/// (rather than erroring) while signed out — there is no uid to look up.
///
/// Reads the uid via `.asData?.value` (this codebase's established
/// AsyncValue-unwrapping convention — see e.g. `_FeedRow`/`_MapView` in
/// `community_screen.dart`) rather than a `.stream`/`.valueOrNull` modifier,
/// neither of which this project's pinned `riverpod` 3.3.2 exposes.
final myDisplayNameProvider = StreamProvider<String?>((ref) {
  // §1c: the single local-data uid door — never `authStateProvider.asData`,
  // which reads null on AsyncError too.
  final uid = ref.watch(effectiveUidProvider);
  if (uid == null) return Stream<String?>.value(null);
  return ref.watch(profileRepositoryProvider).watchDisplayName(uid);
});

/// The profile picture to draw for the SIGNED-IN user, or `null` for "draw
/// the initials chip instead".
///
/// Resolution order, and the reason for it:
///  1. [ProfileRepository.watchAvatarUrl] — a picture the user chose inside
///     this app. It wins outright: an explicit choice must not be
///     overridden by whatever their Google account happens to hold, and
///     "Remove photo" would otherwise be un-doable.
///  2. [AuthSessionState.providerAvatarUrl] — the Google avatar, read live
///     off the session (see its doc), so a brand-new sign-in shows a real
///     face with nothing to set up.
///  3. `null` — magic-link/OTP users, and anyone signed out.
///
/// A `StreamProvider` (not a plain computed value) because step 1 is a live
/// Drift watch: setting or clearing a picture must repaint every avatar in
/// the app without anything having to invalidate this by hand.
final myAvatarUrlProvider = StreamProvider<String?>((ref) {
  final providerAvatar = ref
      .watch(authStateProvider)
      .asData
      ?.value
      .providerAvatarUrl;
  // §1c: the single local-data uid door.
  final uid = ref.watch(effectiveUidProvider);
  if (uid == null) return Stream<String?>.value(null);
  return ref
      .watch(profileRepositoryProvider)
      .watchAvatarUrl(uid)
      .map((own) => own ?? providerAvatar);
});
