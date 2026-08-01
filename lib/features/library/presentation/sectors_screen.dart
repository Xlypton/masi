import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../account/application/auth_providers.dart';
import '../application/library_providers.dart';
import '../data/library_crud_repository.dart';
import 'crud_list_scaffold.dart';
import 'move_target_picker.dart';

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
      onMove: (context, sector) => _handleMove(context, ref, sector),
    );
  }

  /// "Move" flow for a sector row (see `CrudListScaffold`'s `onMove` doc):
  /// resolves the destination-Area candidates (this device's own areas,
  /// minus the sector's current area — see [LibraryCrudRepository.
  /// listOwnAreas]'s doc for why FOREIGN areas are never offered), shows
  /// [showMoveTargetPicker], and on a selection calls [LibraryCrudRepository
  /// .moveSector] followed by a confirmation [SnackBar]. A no-op if the
  /// sheet is dismissed without a selection.
  Future<void> _handleMove(
    BuildContext context,
    WidgetRef ref,
    SectorRef sector,
  ) async {
    final repo = ref.read(libraryCrudRepositoryProvider);
    // §1c: the single local-data uid door — never `authStateProvider.asData`,
    // which reads null on AsyncError too.
    final myUid = ref.read(effectiveUidProvider);
    final ownAreas = await repo.listOwnAreas(myUid);
    final candidates = ownAreas
        .where((area) => area.id != sector.areaId)
        .toList();
    if (!context.mounted) return;

    final targetAreaId = await showMoveTargetPicker(
      context,
      title: 'Move "${sector.name}" to…',
      keyPrefix: 'move-target-area',
      emptyMessage: 'No other areas available',
      options: [
        for (final area in candidates)
          MoveTargetOption(id: area.id, label: area.name),
      ],
    );
    if (targetAreaId == null) return;

    try {
      await repo.moveSector(sector.id, targetAreaId);
    } catch (e, st) {
      debugPrint('Failed to move sector: $e\n$st');
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Couldn't move — please try again")),
      );
      return;
    }
    if (!context.mounted) return;

    final targetArea = candidates.firstWhere((a) => a.id == targetAreaId);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Moved to ${targetArea.name}')),
    );
  }
}
