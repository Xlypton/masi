import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/db/database_provider.dart';
import '../../account/application/auth_providers.dart';
import '../data/comments_repository.dart';

/// The [CommentsRepository] wired to the shared [appDatabaseProvider] /
/// [nowMsProvider], matching the pattern used by
/// `library_providers.dart`'s `libraryCrudRepositoryProvider`. `currentUid`
/// comes from the shared [currentUidProvider] seam, which reads the
/// signed-in uid lazily (per INSERT) and degrades to signed-out (`null`) if
/// auth is unavailable — see its doc for the local-first rationale.
final commentsRepositoryProvider = Provider<CommentsRepository>(
  (ref) => CommentsRepository(
    ref.watch(appDatabaseProvider),
    nowMs: ref.watch(nowMsProvider),
    currentUid: ref.watch(currentUidProvider),
  ),
);
