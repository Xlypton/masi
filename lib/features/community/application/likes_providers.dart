import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/db/database_provider.dart';
import '../../account/application/auth_providers.dart';
import '../data/likes_repository.dart';

/// The [LikesRepository] wired to the shared [appDatabaseProvider] /
/// [nowMsProvider] / [currentUidProvider] seams, matching the pattern used
/// by `libraryCrudRepositoryProvider` in `library_providers.dart`.
final likesRepositoryProvider = Provider<LikesRepository>(
  (ref) => LikesRepository(
    ref.watch(appDatabaseProvider),
    nowMs: ref.watch(nowMsProvider),
    currentUid: ref.watch(currentUidProvider),
  ),
);
