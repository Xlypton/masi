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
