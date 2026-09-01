import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/db/storage_durability_provider.dart';
import '../../account/application/auth_providers.dart';
import '../application/library_providers.dart';
import '../data/library_crud_repository.dart';
import '../../../shared/presentation/masi_pending_button.dart' show MasiBusyReporter;
import 'crud_list_scaffold.dart';
import 'move_target_picker.dart';
import '../../../shared/presentation/masi_toast.dart';

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
      // See `areas_screen.dart`'s identical line.
      createBlockedReason: storageBlockedNotice(
        ref.watch(storageDurabilityProvider),
      ),
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
      onMove: (context, sector, reportBusy) =>
          _handleMove(context, ref, sector, reportBusy),
    );
  }

  /// "Move" flow for a sector row (see `CrudListScaffold`'s `onMove` doc):
  /// resolves the destination-Area candidates (this device's own areas,
  /// minus the sector's current area — see [LibraryCrudRepository.
  /// listOwnAreas]'s doc for why FOREIGN areas are never offered), shows
  /// [showMoveTargetPicker], and on a selection calls [LibraryCrudRepository
  /// .moveSector] followed by a confirmation [SnackBar]. A no-op if the
  /// sheet is dismissed without a selection.
  ///
  /// [reportBusy] is what makes the tap feel like anything at all (see
  /// [MasiBusyReporter]). The candidate list is a database read that has to
  /// finish BEFORE the sheet can be built, so until this reported it, tapping
  /// "Move" did nothing observable for however long that read took — the
  /// classic "is this button broken?" gap. It is reported twice: once around
  /// the read, and again around the write once a destination is picked. In
  /// between, while the sheet is up, the row goes deliberately quiet again:
  /// nothing is loading while the user chooses.
  Future<void> _handleMove(
    BuildContext context,
    WidgetRef ref,
    SectorRef sector,
    MasiBusyReporter reportBusy,
  ) async {
    final repo = ref.read(libraryCrudRepositoryProvider);
    // §1c: the single local-data uid door — never `authStateProvider.asData`,
    // which reads null on AsyncError too.
    final myUid = ref.read(effectiveUidProvider);
    reportBusy(true);
    final List<AreaRef> ownAreas;
    try {
      ownAreas = await repo.listOwnAreas(myUid);
    } finally {
      // Handed back to the user (or, on a throw, back to the caller's guard —
      // `CrudListScaffold` wraps this whole method in `_runGuarded`).
      reportBusy(false);
    }
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

    reportBusy(true);
    try {
      await repo.moveSector(sector.id, targetAreaId);
    } catch (e, st) {
      debugPrint('Failed to move sector: $e\n$st');
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showMasiToast(
        "Couldn't move — please try again",
        kind: MasiToastKind.error,
      );
      return;
    }
    if (!context.mounted) return;

    final targetArea = candidates.firstWhere((a) => a.id == targetAreaId);
    ScaffoldMessenger.of(context).showMasiToast(
      'Moved to ${targetArea.name}',
      kind: MasiToastKind.success,
    );
  }
}
