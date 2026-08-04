import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:masi/core/db/app_database.dart';
import 'package:masi/core/db/database_provider.dart';
import 'package:masi/core/db/storage_durability_provider.dart';
import 'package:masi/core/db/storage_retry_provider.dart';

/// UF-4 follow-up: when the local database genuinely never opens, the user was
/// left on a screen with NO way to retry — force-quit and relaunch, which on an
/// installed PWA is not an obvious move. `main.dart`'s boot deadlines already
/// guarantee the app renders; these cover the way back out.
void main() {
  group('storageRetryNotice: only offers a retry that could actually work', () {
    test(
      'a merely-SLOW open offers nothing — the boot deadlines exist so a slow '
      'open still paints, and must not become an alarm',
      () {
        expect(storageRetryNotice(const StorageDurability.probing()), isNull);
      },
    );

    test('a healthy backend offers nothing', () {
      expect(
        storageRetryNotice(
          const StorageDurability(backend: StorageBackend.nativeFile),
        ),
        isNull,
      );
      expect(
        storageRetryNotice(
          const StorageDurability(backend: StorageBackend.opfsLocks),
        ),
        isNull,
      );
    });

    test(
      'a blocked in-memory browser backend offers nothing: re-opening yields '
      'the same backend every time',
      () {
        final durability = const StorageDurability(
          backend: StorageBackend.inMemory,
        );
        expect(
          durability.isEphemeral,
          isTrue,
          reason: 'the storage WARNING still shows for this — only the RETRY '
              'button is withheld',
        );
        expect(storageRetryNotice(durability), isNull);
      },
    );

    test(
      'an L7 schema downgrade offers nothing: the refusal is deliberate and '
      'would repeat identically forever',
      () {
        expect(
          storageRetryNotice(
            const StorageDurability.unavailable(
              'db is newer',
              cause: StorageUnavailableCause.schemaDowngrade,
            ),
          ),
          isNull,
        );
      },
    );

    test(
      'an unclassified failed open DOES offer a retry, and says what is wrong '
      'rather than "Error"',
      () {
        final notice = storageRetryNotice(
          const StorageDurability.unavailable(
            'the local database did not answer its first query within 30s',
          ),
        );

        expect(notice, isNotNull);
        expect(notice, contains("storage isn't responding"));
        expect(
          notice,
          contains('Nothing has been deleted'),
          reason: 'the one thing the user actually fears, answered up front',
        );
      },
    );
  });

  group('StorageRetryController.retry', () {
    /// A container whose `appDatabaseProvider` builds a REAL (in-memory)
    /// database on every build, counting opens — `overrideWithValue` would
    /// defeat the whole test, since invalidating it would hand back the same
    /// already-failed instance the retry is supposed to replace.
    ({ProviderContainer container, int Function() opens}) makeContainer({
      Set<int> failingOpens = const {},
    }) {
      var opens = 0;
      final container = ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWith((ref) {
            opens++;
            if (failingOpens.contains(opens)) {
              // `openConnection` throwing synchronously is native's shape, and
              // the probe must catch it: hence its `openDatabase` CALLBACK
              // parameter rather than a ready-made AppDatabase.
              throw StateError('open-failed-$opens');
            }
            final db = AppDatabase(NativeDatabase.memory());
            ref.onDispose(db.close);
            return db;
          }),
        ],
      );
      addTearDown(container.dispose);
      return (container: container, opens: () => opens);
    }

    test(
      'the retry RE-OPENS the database rather than re-reading the failed one',
      () async {
        final (container: container, opens: opens) = makeContainer();
        final first = container.read(appDatabaseProvider);
        expect(opens(), 1);

        // The state boot lands in at `kBootStorageDeadline`.
        container
            .read(storageDurabilityProvider.notifier)
            .report(
              const StorageDurability.unavailable(
                'the local database did not answer its first query within 30s',
              ),
            );

        await container.read(storageRetryProvider.notifier).retry();

        expect(
          opens(),
          2,
          reason: 'a retry that only rebuilt a widget would re-read the very '
              'same wedged AppDatabase and re-derive the very same verdict — '
              'visibly doing something and changing nothing',
        );
        expect(container.read(appDatabaseProvider), isNot(same(first)));
      },
    );

    test('a retry that succeeds clears the failure verdict', () async {
      final (container: container, opens: _) = makeContainer();
      container
          .read(storageDurabilityProvider.notifier)
          .report(const StorageDurability.unavailable('dead'));
      expect(container.read(storageDurabilityProvider).unavailable, isTrue);

      await container.read(storageRetryProvider.notifier).retry();

      final durability = container.read(storageDurabilityProvider);
      expect(durability.unavailable, isFalse);
      expect(
        storageRetryNotice(durability),
        isNull,
        reason: 'the banner must stand down once the database answers',
      );
    });

    test(
      'a retry that fails again re-publishes the CURRENT failure, classified '
      'exactly as boot classifies it',
      () async {
        // Open #1 succeeds (boot), open #2 — the retry's — fails.
        final (container: container, opens: opens) = makeContainer(
          failingOpens: const {2},
        );
        container.read(appDatabaseProvider);
        container
            .read(storageDurabilityProvider.notifier)
            .report(const StorageDurability.unavailable('the original failure'));

        await container.read(storageRetryProvider.notifier).retry();

        expect(opens(), 2);
        final durability = container.read(storageDurabilityProvider);
        expect(durability.unavailable, isTrue);
        expect(durability.unavailableCause, StorageUnavailableCause.failed);
        expect(durability.unavailableReason, contains('open-failed-2'));
        expect(
          durability.unavailableReason,
          isNot(contains('the original failure')),
          reason: 'the banner must report what is wrong NOW',
        );
        expect(storageRetryNotice(durability), isNotNull);
      },
    );

    test('retry never throws, even when the re-open blows up', () async {
      final (container: container, opens: _) = makeContainer(
        failingOpens: const {1},
      );

      await expectLater(
        container.read(storageRetryProvider.notifier).retry(),
        completes,
      );
      expect(container.read(storageRetryProvider), StorageRetryStatus.idle);
    });

    test(
      'a second retry while one is in flight is a no-op, and the status is '
      'idle again afterwards',
      () async {
        final (container: container, opens: opens) = makeContainer();
        final controller = container.read(storageRetryProvider.notifier);

        final first = controller.retry();
        expect(
          container.read(storageRetryProvider),
          StorageRetryStatus.retrying,
          reason: 'the button reads this to disable itself — a second tap on a '
              'slow web re-open would otherwise look like a dead button',
        );
        await controller.retry();
        await first;

        expect(opens(), 1, reason: 'one re-open, not two');
        expect(container.read(storageRetryProvider), StorageRetryStatus.idle);
      },
    );
  });
}
