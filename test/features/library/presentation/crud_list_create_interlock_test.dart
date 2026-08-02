import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:masi/app/theme.dart';
import 'package:masi/core/db/storage_durability_provider.dart';
import 'package:masi/features/library/presentation/crud_list_scaffold.dart';

/// The create interlock on the area/sector/wall lists.
///
/// Before this, `<entity>-add-fab` sat OUTSIDE `asyncItems.when` with an
/// unconditional `onPressed`, so a list that failed to load rendered
/// "Something went wrong" beside a fully live "New area" button — one that
/// opens a name dialog and writes into the very database that had just
/// refused to be read. It also had no way to know about
/// `storageDurabilityProvider`, so the §1a interlock that has guarded the
/// topos home since the start simply did not exist on these three screens.
///
/// [CrudListScaffold] is deliberately not a `ConsumerWidget` (see its class
/// doc), so the storage reason arrives as a parameter and these tests drive it
/// directly. The three real screens pass
/// `storageBlockedNotice(ref.watch(storageDurabilityProvider))`; the wiring
/// half is covered by `crud_screens_storage_wiring_test.dart`.
Widget _wrap({
  required AsyncValue<List<String>> items,
  String? createBlockedReason,
}) {
  return ProviderScope(
    child: MaterialApp(
      theme: MasiTheme.light,
      home: CrudListScaffold<String>(
        title: 'Areas',
        entityKey: 'area',
        asyncItems: items,
        idOf: (s) => s,
        nameOf: (s) => s,
        emptyMessage: 'No areas yet',
        addDialogTitle: 'New area',
        renameDialogTitle: 'Rename area',
        createBlockedReason: createBlockedReason,
        onRetry: () {},
        onTap: (_) {},
        onCreate: (_) async {},
        onRename: (_, _) async {},
        onDelete: (_) async {},
      ),
    ),
  );
}

ElevatedButton _addButton(WidgetTester tester) =>
    tester.widget<ElevatedButton>(find.byKey(const Key('area-add-fab')));

void main() {
  testWidgets('a loaded list leaves creation enabled and shows no reason', (
    tester,
  ) async {
    await tester.pumpWidget(_wrap(items: const AsyncData(['Peak'])));
    await tester.pump();

    expect(_addButton(tester).onPressed, isNotNull);
    expect(find.byKey(const Key('area-add-blocked-reason')), findsNothing);
  });

  testWidgets('a list that failed to load disables creation and says why', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(items: AsyncError(Exception('boom'), StackTrace.empty)),
    );
    await tester.pump();

    expect(
      _addButton(tester).onPressed,
      isNull,
      reason: 'the button used to stay live beside "Something went wrong" and '
          'write into the database that had just refused to be read',
    );
    expect(find.byKey(const Key('area-add-blocked-reason')), findsOneWidget);
  });

  testWidgets('a loading list still allows creation — block only on a KNOWN '
      'bad state', (tester) async {
    await tester.pumpWidget(_wrap(items: const AsyncLoading()));
    await tester.pump();

    expect(_addButton(tester).onPressed, isNotNull);
  });

  testWidgets('a storage verdict disables creation even when the list loaded '
      'perfectly well', (tester) async {
    // The in-memory case: every read succeeds, so nothing about the list looks
    // wrong — and every write would vanish on reload. This is the case the
    // error-state gate alone cannot see.
    await tester.pumpWidget(
      _wrap(
        items: const AsyncData(['Peak']),
        createBlockedReason: storageBlockedNotice(
          const StorageDurability(backend: StorageBackend.inMemory),
        ),
      ),
    );
    await tester.pump();

    expect(_addButton(tester).onPressed, isNull);
    final reason = tester.widget<Text>(
      find.byKey(const Key('area-add-blocked-reason')),
    );
    expect(reason.data, contains('blocked in this browser'));
  });

  testWidgets('the storage reason wins over the load-error reason, because it '
      'explains it', (tester) async {
    await tester.pumpWidget(
      _wrap(
        items: AsyncError(Exception('boom'), StackTrace.empty),
        createBlockedReason: storageBlockedNotice(
          const StorageDurability.unavailable(
            'SchemaDowngradeException: ...',
            cause: StorageUnavailableCause.schemaDowngrade,
          ),
        ),
      ),
    );
    await tester.pump();

    final reason = tester.widget<Text>(
      find.byKey(const Key('area-add-blocked-reason')),
    );
    // An unopenable database is WHY the list failed; saying "this list
    // couldn't be loaded" there would describe the symptom and hide the cause.
    expect(reason.data, contains('Nothing has been lost'));
    expect(reason.data, isNot(contains("This list couldn't be loaded")));
  });
}
