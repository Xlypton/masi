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
