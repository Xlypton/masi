import 'package:flutter_test/flutter_test.dart';
import 'package:masi/core/storage/storage_persistence_types.dart';

void main() {
  group('StorageEstimateSnapshot', () {
    test('usedFraction is usage/quota', () {
      const snapshot = StorageEstimateSnapshot(
        usageBytes: 512,
        quotaBytes: 2048,
      );

      expect(snapshot.usedFraction, 0.25);
    });

    test('usedFraction is null when either number is missing', () {
      expect(
        const StorageEstimateSnapshot(quotaBytes: 2048).usedFraction,
        isNull,
      );
      expect(
        const StorageEstimateSnapshot(usageBytes: 512).usedFraction,
        isNull,
      );
      expect(const StorageEstimateSnapshot().usedFraction, isNull);
    });

    test('usedFraction is null for a zero quota (never divides by zero)', () {
      expect(
        const StorageEstimateSnapshot(usageBytes: 512, quotaBytes: 0)
            .usedFraction,
        isNull,
      );
    });

    test('is value-equal on both numbers', () {
      // Deliberately NON-const so the two instances are genuinely distinct
      // objects: two identical `const` literals are canonicalised to the
      // same instance and would pass even without an `operator ==`.
      final a = StorageEstimateSnapshot(usageBytes: 1, quotaBytes: 2);
      final b = StorageEstimateSnapshot(usageBytes: 1, quotaBytes: 2);
      final c = StorageEstimateSnapshot(usageBytes: 1, quotaBytes: 3);

      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(c));
    });
  });

  group('StoragePersistenceStatus', () {
    test('defaults to notRequested / not persisted / unknown estimate', () {
      const status = StoragePersistenceStatus();

      expect(status.outcome, StoragePersistOutcome.notRequested);
      expect(status.persisted, isFalse);
      expect(status.estimate, isNull);
    });

    test('is value-equal on all three fields', () {
      final a = StoragePersistenceStatus(
        outcome: StoragePersistOutcome.granted,
        persisted: true,
        estimate: StorageEstimateSnapshot(usageBytes: 1, quotaBytes: 2),
      );
      final b = StoragePersistenceStatus(
        outcome: StoragePersistOutcome.granted,
        persisted: true,
        estimate: StorageEstimateSnapshot(usageBytes: 1, quotaBytes: 2),
      );
      final differentOutcome = StoragePersistenceStatus(
        outcome: StoragePersistOutcome.denied,
        persisted: true,
        estimate: StorageEstimateSnapshot(usageBytes: 1, quotaBytes: 2),
      );
      final differentEstimate = StoragePersistenceStatus(
        outcome: StoragePersistOutcome.granted,
        persisted: true,
        estimate: StorageEstimateSnapshot(usageBytes: 9, quotaBytes: 2),
      );

      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(differentOutcome));
      expect(a, isNot(differentEstimate));
    });
  });
}
