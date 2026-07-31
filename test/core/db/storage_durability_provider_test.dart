import 'package:drift/drift.dart' show LazyDatabase, QueryExecutor;
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:masi/core/db/app_database.dart';
import 'package:masi/core/db/connection/connection.dart';
import 'package:masi/core/db/database_provider.dart';
import 'package:masi/core/db/storage_durability_provider.dart';

void main() {
  group('storageDurabilityProvider', () {
    test('starts out probing', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      expect(container.read(storageDurabilityProvider).isProbing, isTrue);
      expect(container.read(storageDurabilityProvider).isEphemeral, isFalse);
    });

    test('report() publishes the verdict AND logs it', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      final captured = <String>[];
      final original = debugPrint;
      debugPrint = (String? m, {int? wrapWidth}) {
        if (m != null) captured.add(m);
      };
      addTearDown(() => debugPrint = original);

      container.read(storageDurabilityProvider.notifier).report(
            const StorageDurability(
              backend: StorageBackend.inMemory,
              missingFeatures: {StorageMissingFeature.sharedArrayBuffers},
            ),
          );
      debugPrint = original;

      expect(
        container.read(storageDurabilityProvider).backend,
        StorageBackend.inMemory,
      );
      expect(container.read(storageDurabilityProvider).isEphemeral, isTrue);
      expect(captured.single, contains('backend=inMemory'));
    });

    test(
      'a verdict that lands after teardown is still logged, then dropped — '
      'never throws',
      () {
        final container = ProviderContainer();
        final notifier = container.read(storageDurabilityProvider.notifier);
        container.dispose();

        // `report()` deliberately logs BEFORE its `ref.mounted` guard, so a
        // verdict arriving during teardown or a hot restart still reaches the
        // console — which is exactly the case §1a exists to diagnose. Assert
        // the log, not just the absence of a throw: without this, swapping the
        // two lines would silently lose the only production signal, and every
        // other test here would still pass.
        final captured = <String>[];
        final original = debugPrint;
        debugPrint = (String? m, {int? wrapWidth}) {
          if (m != null) captured.add(m);
        };
        addTearDown(() => debugPrint = original);

        expect(
          () => notifier.report(
            const StorageDurability(backend: StorageBackend.nativeFile),
          ),
          returnsNormally,
        );

        debugPrint = original;
        expect(captured, hasLength(1));
        expect(captured.single, contains('masi/storage:'));
        expect(captured.single, contains('backend=nativeFile'));
      },
    );
  });

  group('openConnection (native seam)', () {
    test(
      'reports nativeFile/durable SYNCHRONOUSLY and still returns an '
      'unopened LazyDatabase — no path_provider or filesystem work here',
      () {
        final reports = <StorageDurability>[];
        final QueryExecutor executor = openConnection(
          onStorageReport: reports.add,
        );

        expect(reports, hasLength(1));
        expect(reports.single.backend, StorageBackend.nativeFile);
        expect(reports.single.isDurable, isTrue);
        expect(reports.single.missingFeatures, isEmpty);
        expect(executor, isA<LazyDatabase>());
      },
    );

    test('openConnection() with no callback still works (old call shape)', () {
      expect(openConnection(), isA<LazyDatabase>());
    });
  });

  group('appDatabaseProvider <-> storageDurabilityProvider wiring', () {
    test(
      'the native verdict lands one microtask after the first read, WITHOUT '
      "mutating a provider during appDatabaseProvider's own build",
      () async {
        final container = ProviderContainer();
        addTearDown(container.dispose);

        // Riverpod asserts "Providers are not allowed to modify other
        // providers during their initialization." (riverpod
        // src/core/element.dart). connection_native.dart calls
        // `onStorageReport` synchronously, so this read would trip that
        // assert if appDatabaseProvider did not defer the report by a
        // microtask.
        expect(container.read(appDatabaseProvider), isA<AppDatabase>());
        expect(
          container.read(storageDurabilityProvider).isProbing,
          isTrue,
          reason: 'the report must NOT have been applied synchronously',
        );

        await Future<void>.delayed(Duration.zero);

        expect(
          container.read(storageDurabilityProvider).backend,
          StorageBackend.nativeFile,
        );
        expect(container.read(storageDurabilityProvider).isDurable, isTrue);
        expect(container.read(storageDurabilityProvider).isEphemeral, isFalse);
      },
    );
  });
}
