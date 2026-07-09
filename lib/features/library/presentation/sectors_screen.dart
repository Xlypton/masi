import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../application/library_providers.dart';
import '../data/library_crud_repository.dart';
import 'crud_list_scaffold.dart';

/// Lists the non-deleted [SectorRef]s scoped to a single area, and lets the
/// user create/rename/delete sectors and drill into a wall list.
class SectorsScreen extends ConsumerWidget {
  const SectorsScreen({super.key, required this.areaId, this.areaName});

  /// The parent area's id — every sector shown/created here is scoped to it.
  final String areaId;

  /// Optional display name for the app bar title (threaded via
  /// `GoRouterState.extra` from [AreasScreen]); falls back to a generic
  /// title if navigated to directly (e.g. deep link, or in a test).
  final String? areaName;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final asyncSectors = ref.watch(sectorsProvider(areaId));
    final repo = ref.read(libraryCrudRepositoryProvider);

    return CrudListScaffold<SectorRef>(
      title: areaName ?? 'Sectors',
      entityKey: 'sector',
      asyncItems: asyncSectors,
      idOf: (sector) => sector.id,
      nameOf: (sector) => sector.name,
      emptyMessage: 'No sectors yet — tap + to add one',
      addDialogTitle: 'New sector',
      renameDialogTitle: 'Rename sector',
      onRetry: () => ref.invalidate(sectorsProvider(areaId)),
      onTap: (sector) =>
          context.push('/sectors/${sector.id}/walls', extra: sector.name),
      onCreate: (name) async {
        await repo.createSector(areaId, name);
      },
      onRename: (sector, name) async {
        await repo.renameSector(sector.id, name);
      },
      onDelete: (sector) async {
        await repo.softDeleteSector(sector.id);
      },
    );
  }
}
