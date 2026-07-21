import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/db/database_provider.dart';
import '../../account/application/auth_providers.dart';
import '../data/ascents_repository.dart';

/// The [AscentsRepository] wired to the shared [appDatabaseProvider] /
/// [nowMsProvider] / [currentUidProvider], matching the pattern used by
/// `libraryCrudRepositoryProvider` in `library_providers.dart`.
final ascentsRepositoryProvider = Provider<AscentsRepository>(
  (ref) => AscentsRepository(
    ref.watch(appDatabaseProvider),
    nowMs: ref.watch(nowMsProvider),
    currentUid: ref.watch(currentUidProvider),
  ),
);

/// Reactive, cross-owner feed of every opt-in-`shared` ascent (Feature #12,
/// public opt-in ascent logs) — backs a public "ascent feed" (any signed-in
/// user's shared climbs, not scoped to the current user). See
/// [AscentsRepository.watchSharedAscents] for the exact query semantics.
final sharedAscentsProvider = StreamProvider<List<SharedAscentEntry>>(
  (ref) => ref.watch(ascentsRepositoryProvider).watchSharedAscents(),
);
