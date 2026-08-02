import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/db/storage_durability_provider.dart';
import '../application/library_providers.dart';
import '../data/library_crud_repository.dart';
import 'crud_list_scaffold.dart';

/// Lists the non-deleted [WallRef]s scoped to a single sector, and lets the
/// user create/rename/delete walls and drill into a wall's detail (the topo
/// canvas, bound to the tapped wall — see `TopoCanvasScreen` and
/// `lib/app/router.dart`'s `/walls/:wallId` route).
class WallsScreen extends ConsumerWidget {
  const WallsScreen({super.key, required this.sectorId, this.sectorName});

  /// The parent sector's id — every wall shown/created here is scoped to it.
  final String sectorId;

  /// Optional display name for the app bar title (threaded via
  /// `GoRouterState.extra` from [SectorsScreen]); falls back to a generic
  /// title if navigated to directly (e.g. deep link, or in a test).
  final String? sectorName;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final asyncWalls = ref.watch(wallsProvider(sectorId));
    final repo = ref.read(libraryCrudRepositoryProvider);

    return CrudListScaffold<WallRef>(
      title: sectorName ?? 'Walls',
      entityKey: 'wall',
      // See `areas_screen.dart`'s identical line.
      createBlockedReason: storageBlockedNotice(
        ref.watch(storageDurabilityProvider),
      ),
      asyncItems: asyncWalls,
      idOf: (wall) => wall.id,
      nameOf: (wall) => wall.name,
      emptyMessage: 'No walls yet — tap + to add one',
      addDialogTitle: 'New wall',
      renameDialogTitle: 'Rename wall',
      onRetry: () => ref.invalidate(wallsProvider(sectorId)),
      onTap: (wall) => context.push('/walls/${wall.id}'),
      onCreate: (name) async {
        await repo.createWall(sectorId, name);
      },
      onRename: (wall, name) async {
        await repo.renameWall(wall.id, name);
      },
      onDelete: (wall) async {
        await repo.softDeleteWall(wall.id);
      },
    );
  }
}

/// Former placeholder for `/walls/:wallId`, superseded by `TopoCanvasScreen`
/// (see `lib/app/router.dart`). No longer wired into the router; kept around
/// harmlessly in case a lightweight stand-in is useful again later.
class WallDetailPlaceholder extends StatelessWidget {
  const WallDetailPlaceholder({super.key, required this.wallId});

  final String wallId;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Wall')),
      body: Center(
        child: Text(
          'Wall $wallId\n\ncanvas coming in subtask 4',
          key: const Key('wall-detail-placeholder-text'),
          textAlign: TextAlign.center,
        ),
      ),
    );
  }
}
