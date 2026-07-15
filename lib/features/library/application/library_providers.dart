import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/db/database_provider.dart';
import '../../account/application/auth_providers.dart';
import '../data/library_crud_repository.dart';

/// The [LibraryCrudRepository] wired to the shared [appDatabaseProvider] /
/// [nowMsProvider], matching the pattern used by the other repository
/// providers in `database_provider.dart`. `currentUid` comes from the
/// shared [currentUidProvider] seam, which reads the signed-in uid lazily
/// (per INSERT) and degrades to signed-out (`null`) if auth is unavailable
/// — see its doc for the local-first rationale. `photoFiles` comes from the
/// shared [photoFilesProvider] so this repo's photo-path resolution shares
/// its memoized docs-path cache with [photoRepositoryProvider] (and with
/// whatever pre-warmed it at startup — see `main.dart`) instead of each
/// repo carrying its own cold, unshared `PhotoFiles()`.
final libraryCrudRepositoryProvider = Provider<LibraryCrudRepository>(
  (ref) => LibraryCrudRepository(
    ref.watch(appDatabaseProvider),
    nowMs: ref.watch(nowMsProvider),
    currentUid: ref.watch(currentUidProvider),
    photoFiles: ref.watch(photoFilesProvider),
  ),
);

/// Live list of non-deleted areas, ordered by name then creation time.
final areasProvider = StreamProvider<List<AreaRef>>(
  (ref) => ref.watch(libraryCrudRepositoryProvider).watchAreas(),
);

/// Live list of non-deleted sectors scoped to a single area, ordered by
/// sortOrder then creation time.
final sectorsProvider = StreamProvider.family<List<SectorRef>, String>(
  (ref, areaId) =>
      ref.watch(libraryCrudRepositoryProvider).watchSectors(areaId),
);

/// Live list of non-deleted walls scoped to a single sector, ordered by
/// sortOrder then creation time.
final wallsProvider = StreamProvider.family<List<WallRef>, String>(
  (ref, sectorId) =>
      ref.watch(libraryCrudRepositoryProvider).watchWalls(sectorId),
);

/// Live flat list of every non-deleted wall (a "topo"), each paired with its
/// thumbnail path and route count, ordered newest-first. Backs the flat
/// Topos-home list.
final toposProvider = StreamProvider<List<TopoRef>>(
  (ref) => ref.watch(libraryCrudRepositoryProvider).watchTopos(),
);

/// The display name of a single wall (a "topo"), or `null` if it has none /
/// doesn't exist. Backs the topo canvas screen's title chrome — see
/// `TopoCanvasScreen` in `topo_canvas_screen.dart`, which falls back to a
/// generic "Topo" label while this is loading or resolves to null.
final wallNameProvider = FutureProvider.family<String?, String>(
  (ref, wallId) => ref.watch(libraryCrudRepositoryProvider).wallName(wallId),
);
