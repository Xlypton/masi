import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:masi/app/theme.dart';
import 'package:masi/core/db/app_database.dart';
import 'package:masi/core/db/database_provider.dart';
import 'package:masi/core/db/storage_durability_provider.dart';
import 'package:masi/features/library/application/library_providers.dart';
import 'package:masi/features/library/data/library_crud_repository.dart';
import 'package:masi/features/library/presentation/areas_screen.dart';
import 'package:masi/features/library/presentation/crud_list_scaffold.dart';

/// `crud_list_create_interlock_test.dart` proves [CrudListScaffold] honours a
/// `createBlockedReason`. This file proves a real screen actually SUPPLIES one
/// from `storageDurabilityProvider` — the half that decides whether any of it
/// reaches production. Without it the parameter could sit unused and every
/// test in that file would still pass, which is exactly the "gate that
/// silently does nothing" shape this work exists to avoid.
///
/// [AreasScreen] only. `SectorsScreen`/`WallsScreen` carry the identical
/// one-line wiring; mounting either in a bare harness hangs past a
/// `--timeout 45s` per-test bound (i.e. outside the clock the test timeout
/// governs), which is a pre-existing property of those screens' provider
/// graph rather than anything this change introduced.
///
/// [areasProvider] is overridden with a plain stream rather than left on the
/// real drift query. Not a shortcut — a necessity: disposing a live drift
/// `QueryStream` makes `StreamQueryStore.markAsClosed` schedule a
/// zero-duration cleanup timer
/// (`drift-2.34.2/lib/src/runtime/executor/stream_queries.dart:156`), which
/// trips flutter_test's `!timersPending` invariant at teardown ("A Timer is
/// still pending even after the widget tree was disposed"). Unmounting the
/// tree inside the test body to flush it instead deadlocks. The list contents
/// are irrelevant here anyway: the button under test is rendered outside the
/// async switch.
class _FakeStorageDurability extends StorageDurabilityNotifier {
  _FakeStorageDurability(this._verdict);

  final StorageDurability _verdict;

  @override
  StorageDurability build() => _verdict;
}

Widget _wrap(StorageDurability verdict) {
  // Still needed: `AreasScreen.build` reads `libraryCrudRepositoryProvider`,
  // which constructs against the database even though nothing queries it here.
  final db = AppDatabase(NativeDatabase.memory());
  addTearDown(db.close);
  return ProviderScope(
    overrides: [
      appDatabaseProvider.overrideWithValue(db),
      nowMsProvider.overrideWithValue(() => 1000),
      areasProvider.overrideWith((ref) => Stream.value(const <AreaRef>[])),
      storageDurabilityProvider.overrideWith(
        () => _FakeStorageDurability(verdict),
      ),
    ],
    // `MasiTheme.light` is not optional: `MasiColors.of(context)` null-asserts
    // the masi theme extension, so a bare MaterialApp crashes every screen in
    // this app on its first build.
    child: MaterialApp(theme: MasiTheme.light, home: const AreasScreen()),
  );
}

ElevatedButton _addButton(WidgetTester tester) =>
    tester.widget<ElevatedButton>(find.byKey(const Key('area-add-fab')));

void main() {
  testWidgets('a non-durable backend disables the area create button and '
      'says why', (tester) async {
    await tester.pumpWidget(
      _wrap(const StorageDurability(backend: StorageBackend.inMemory)),
    );
    await tester.pump();

    expect(_addButton(tester).onPressed, isNull);
    expect(
      find.byKey(const Key('area-add-blocked-reason')),
      findsOneWidget,
      reason: 'disabled without a reason is the dead-tap failure in a quieter '
          'costume',
    );
  });

  testWidgets('a durable backend leaves it enabled with no notice', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(const StorageDurability(backend: StorageBackend.nativeFile)),
    );
    await tester.pump();

    expect(_addButton(tester).onPressed, isNotNull);
    expect(find.byKey(const Key('area-add-blocked-reason')), findsNothing);
  });
}
