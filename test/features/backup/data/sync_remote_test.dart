import 'package:masi/features/backup/data/sync_remote.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('partitionSyncRows', () {
    test(
      'splits rows into valid + invalid by required-field presence, keeping '
      'every valid row and reporting every dropped one (L5: the push side '
      'needs to KNOW what it excluded, not just log it)',
      () {
        final rows = <Map<String, dynamic>>[
          {'id': 'a1', 'createdAt': 1, 'updatedAt': 2, 'name': 'Good'},
          {'id': 'a2', 'createdAt': 1, 'updatedAt': 2, 'name': null},
          {'id': null, 'createdAt': 1, 'updatedAt': 2, 'name': 'No id'},
          {'createdAt': 1, 'updatedAt': 2, 'name': 'Missing the id key'},
        ];

        final split = partitionSyncRows(
          rows,
          const ['id', 'createdAt', 'updatedAt', 'name'],
          debugLabel: 'local areas (push)',
        );

        expect(split.valid.map((r) => r['id']), ['a1']);
        expect(split.invalid, hasLength(3));
        expect(split.invalid.map((r) => r['id']), ['a2', null, null]);
      },
    );

    test('every row valid -> invalid is empty', () {
      final split = partitionSyncRows(
        <Map<String, dynamic>>[
          {'id': 'a1', 'createdAt': 1, 'updatedAt': 2},
          {'id': 'a2', 'createdAt': 1, 'updatedAt': 2},
        ],
        const ['id', 'createdAt', 'updatedAt'],
        debugLabel: 'local areas (push)',
      );

      expect(split.valid, hasLength(2));
      expect(split.invalid, isEmpty);
    });

    test(
      'filterValidSyncRows returns exactly partitionSyncRows(...).valid — the '
      'existing fetch-side callers must be behaviourally untouched',
      () {
        final rows = <Map<String, dynamic>>[
          {'id': 'ok', 'createdAt': 1, 'updatedAt': 1},
          {'id': null, 'createdAt': 1, 'updatedAt': 1},
        ];
        const required = ['id', 'createdAt', 'updatedAt'];

        expect(
          filterValidSyncRows(
            rows,
            required,
            debugLabel: 'own areas',
          ).map((r) => r['id']),
          partitionSyncRows(
            rows,
            required,
            debugLabel: 'own areas',
          ).valid.map((r) => r['id']),
        );
      },
    );
  });

  group('TablePushOutcome', () {
    test('ok carries the upserted/skipped counts and reports no error', () {
      const outcome = TablePushOutcome.ok(
        table: 'areas',
        rowsUpserted: 3,
        rowsSkippedNewerRemote: 1,
      );

      expect(outcome.ok, isTrue);
      expect(outcome.error, isNull);
      expect(outcome.table, 'areas');
      expect(outcome.rowsUpserted, 3);
      expect(outcome.rowsSkippedNewerRemote, 1);
      expect(outcome.rowsFailed, 0);
    });

    test('failed carries the unsynced row count and a stringified error', () {
      final outcome = TablePushOutcome.failed(
        table: 'photos',
        rowsFailed: 4,
        error: Exception('network down'),
      );

      expect(outcome.ok, isFalse);
      expect(outcome.error, contains('network down'));
      expect(outcome.table, 'photos');
      expect(outcome.rowsUpserted, 0);
      expect(outcome.rowsSkippedNewerRemote, 0);
      expect(outcome.rowsFailed, 4);
    });
  });
}
