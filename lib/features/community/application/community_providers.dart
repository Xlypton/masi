import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/db/database_provider.dart';
import '../data/community_repository.dart';

/// The [CommunityRepository] wired to the shared [appDatabaseProvider] /
/// [photoFilesProvider], matching the pattern used by
/// `library_providers.dart`'s `libraryCrudRepositoryProvider`. Read-only (no
/// `nowMs`/`currentUid` seam — this repo never writes a row).
final communityRepositoryProvider = Provider<CommunityRepository>(
  (ref) => CommunityRepository(
    ref.watch(appDatabaseProvider),
    photoFiles: ref.watch(photoFilesProvider),
  ),
);

/// Live list of every shared topo (a non-deleted Wall with
/// `visibility == 'shared'`), newest-first. Backs the Community feed + map.
final sharedToposProvider = StreamProvider<List<SharedTopo>>(
  (ref) => ref.watch(communityRepositoryProvider).watchSharedTopos(),
);
