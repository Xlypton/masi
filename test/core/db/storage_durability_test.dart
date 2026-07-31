import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:masi/core/db/connection/storage_durability.dart';

/// Captures every [debugPrint] emitted while [body] runs, restoring the real
/// implementation afterwards. `debugPrint` is a plain mutable top-level
/// function pointer, which is exactly why the release-visible logging in
/// [logStorageDurability] is assertable without inventing a log-sink seam.
List<String> _captureDebugPrint(void Function() body) {
  final captured = <String>[];
  final original = debugPrint;
  debugPrint = (String? message, {int? wrapWidth}) {
    if (message != null) captured.add(message);
  };
  addTearDown(() => debugPrint = original);
  body();
  debugPrint = original;
  return captured;
}

void main() {
  group('StorageBackend.isDurable', () {
    test('only inMemory is non-durable', () {
      expect(StorageBackend.inMemory.isDurable, isFalse);
      for (final backend in StorageBackend.values) {
        if (backend == StorageBackend.inMemory) continue;
        expect(
          backend.isDurable,
          isTrue,
          reason: '$backend must count as durable — unsafeIndexedDb is '
              'race-prone across tabs (L8) but it DOES persist',
        );
      }
    });
  });

  group('StorageDurability', () {
    test('probing is neither durable nor ephemeral', () {
      const probing = StorageDurability.probing();
      expect(probing.isProbing, isTrue);
      expect(probing.isDurable, isFalse);
      expect(probing.isEphemeral, isFalse);
      expect(probing.backend, isNull);
      expect(probing.missingFeatures, isEmpty);
    });

    test('an inMemory verdict is ephemeral, not durable', () {
      const verdict = StorageDurability(
        backend: StorageBackend.inMemory,
        missingFeatures: {
          StorageMissingFeature.indexedDb,
          StorageMissingFeature.dedicatedWorkers,
        },
      );
      expect(verdict.isProbing, isFalse);
      expect(verdict.isEphemeral, isTrue);
      expect(verdict.isDurable, isFalse);
    });

    test('native/OPFS/IndexedDB verdicts are durable, not ephemeral', () {
      for (final backend in const [
        StorageBackend.nativeFile,
        StorageBackend.opfsShared,
        StorageBackend.opfsLocks,
        StorageBackend.sharedIndexedDb,
        StorageBackend.unsafeIndexedDb,
      ]) {
        final verdict = StorageDurability(backend: backend);
        expect(verdict.isDurable, isTrue, reason: '$backend');
        expect(verdict.isEphemeral, isFalse, reason: '$backend');
      }
    });

    test('equality covers the missing-feature set, not just the backend', () {
      const a = StorageDurability(
        backend: StorageBackend.inMemory,
        missingFeatures: {StorageMissingFeature.indexedDb},
      );
      const b = StorageDurability(
        backend: StorageBackend.inMemory,
        missingFeatures: {StorageMissingFeature.indexedDb},
      );
      const c = StorageDurability(
        backend: StorageBackend.inMemory,
        missingFeatures: {StorageMissingFeature.sharedWorkers},
      );
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(c));
    });
  });

  group('logStorageDurability', () {
    test('logs the chosen backend + missing features via debugPrint', () {
      final lines = _captureDebugPrint(() {
        logStorageDurability(
          const StorageDurability(
            backend: StorageBackend.inMemory,
            missingFeatures: {StorageMissingFeature.sharedArrayBuffers},
          ),
        );
      });

      expect(lines, hasLength(1));
      expect(lines.single, contains('masi/storage:'));
      expect(lines.single, contains('backend=inMemory'));
      expect(lines.single, contains('durable=false'));
      expect(lines.single, contains('sharedArrayBuffers'));
    });

    test('logs a durable backend too — it is the "my data vanished" answer',
        () {
      final lines = _captureDebugPrint(() {
        logStorageDurability(
          const StorageDurability(backend: StorageBackend.opfsLocks),
        );
      });
      expect(lines.single, contains('backend=opfsLocks'));
      expect(lines.single, contains('durable=true'));
    });
  });
}
