import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../application/library_providers.dart';
import '../data/library_crud_repository.dart';
import 'crud_list_scaffold.dart';

/// Root screen of the library hierarchy: lists all non-deleted [AreaRef]s
/// and lets the user create/rename/delete areas and drill into a sector
/// list.
class AreasScreen extends ConsumerWidget {
  const AreasScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final asyncAreas = ref.watch(areasProvider);
    final repo = ref.read(libraryCrudRepositoryProvider);

    return CrudListScaffold<AreaRef>(
      title: 'Areas',
      entityKey: 'area',
      asyncItems: asyncAreas,
      idOf: (area) => area.id,
      nameOf: (area) => area.name,
      subtitleOf: (area) => area.description,
      emptyMessage: 'No areas yet — tap + to add one',
      addDialogTitle: 'New area',
      renameDialogTitle: 'Rename area',
      onRetry: () => ref.invalidate(areasProvider),
      onTap: (area) =>
          context.push('/areas/${area.id}/sectors', extra: area.name),
      onCreate: (name) async {
        await repo.createArea(name);
      },
      onRename: (area, name) async {
        await repo.renameArea(area.id, name);
      },
      onDelete: (area) async {
        await repo.softDeleteArea(area.id);
      },
    );
  }
}
