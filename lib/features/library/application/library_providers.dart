import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/db/database_provider.dart';
import '../data/library_crud_repository.dart';

/// The [LibraryCrudRepository] wired to the shared [appDatabaseProvider] /
/// [nowMsProvider], matching the pattern used by the other repository
/// providers in `database_provider.dart`.
final libraryCrudRepositoryProvider = Provider<LibraryCrudRepository>(
  (ref) => LibraryCrudRepository(
    ref.watch(appDatabaseProvider),
    nowMs: ref.watch(nowMsProvider),
  ),
);

/// Live list of non-deleted areas, ordered by name then creation time.
final areasProvider = StreamProvider<List<AreaRef>>(
  (ref) => ref.watch(libraryCrudRepositoryProvider).watchAreas(),
);

/// Live list of non-deleted sectors scoped to a single area, ordered by
/// sortOrder then creation time.
final sectorsProvider = StreamProvider.family<List<SectorRef>, String>(
  (ref, areaId) => ref.watch(libraryCrudRepositoryProvider).watchSectors(areaId),
);

/// Live list of non-deleted walls scoped to a single sector, ordered by
/// sortOrder then creation time.
final wallsProvider = StreamProvider.family<List<WallRef>, String>(
  (ref, sectorId) => ref.watch(libraryCrudRepositoryProvider).watchWalls(sectorId),
);
