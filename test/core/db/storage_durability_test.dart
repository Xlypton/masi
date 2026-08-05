import 'dart:async';

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

    test('an unavailable verdict IS a verdict — ephemeral, never probing', () {
      const verdict = StorageDurability.unavailable('WasmDatabase.open blew up');
      // The whole point: `probing` reads as "not yet known to be bad", which
      // the create-topo interlock treats as "allow creation". A failed open
      // must NOT land there, or the interlock silently stays open.
      expect(verdict.isProbing, isFalse);
      expect(verdict.isEphemeral, isTrue);
      expect(verdict.isDurable, isFalse);
      expect(verdict.unavailable, isTrue);
      expect(verdict.unavailableReason, 'WasmDatabase.open blew up');
      expect(verdict.backend, isNull);
    });

    test('unavailable and probing are NOT equal despite both having a null '
        'backend', () {
      const unavailable = StorageDurability.unavailable('boom');
      const probing = StorageDurability.probing();
      // Equality keyed on `backend` alone would conflate these two, which are
      // opposites for the interlock (ephemeral vs allow-creation).
      expect(unavailable, isNot(probing));
      expect(unavailable.hashCode, isNot(probing.hashCode));
      expect(unavailable, const StorageDurability.unavailable('boom'));
      expect(unavailable, isNot(const StorageDurability.unavailable('other')));
    });

    group('unavailableOver preserves the connection layer\'s measurements', () {
      // B2. `StorageDurability.unavailable` hard-zeroes `measuredBackend` and
      // `missingFeatures`, and boot's stall verdict OVERWRITES the connection
      // layer's real report with it. Production measures
      // `opfsLocks / {dedicatedWorkersInSharedWorkers}` seconds earlier, so a
      // stall destroyed the only field-diagnosable facts the app ever learns —
      // which is why a real field report's banner had no `· missing: …`
      // segment.
      const measured = StorageDurability(
        backend: StorageBackend.opfsLocks,
        missingFeatures: {
          StorageMissingFeature.dedicatedWorkersInSharedWorkers,
        },
      );

      test('carries the measured backend and missing features forward', () {
        final stalled = StorageDurability.unavailableOver(measured, 'stalled');

        expect(stalled.measuredBackend, StorageBackend.opfsLocks);
        expect(
          stalled.missingFeatures,
          {StorageMissingFeature.dedicatedWorkersInSharedWorkers},
          reason: 'this set IS the `· missing: …` segment both storage banners '
              'render; zeroing it is what made the field report unanswerable',
        );
        expect(stalled.unavailableReason, 'stalled');
      });

      test('is still a full unavailable verdict — the interlock must not '
          'soften just because a backend is remembered', () {
        final stalled = StorageDurability.unavailableOver(measured, 'stalled');

        expect(stalled.unavailable, isTrue);
        expect(stalled.isEphemeral, isTrue);
        expect(stalled.isDurable, isFalse);
        expect(stalled.isProbing, isFalse);
        expect(stalled.unavailableCause, StorageUnavailableCause.failed);
        expect(
          stalled.backend,
          isNull,
          reason: 'no backend is IN EFFECT for an unreachable database — three '
              'render sites read `backend?.name ?? "unavailable"` and must '
              'keep saying "unavailable"',
        );
      });

      test('invents nothing when nothing was measured yet', () {
        final stalled = StorageDurability.unavailableOver(
          const StorageDurability.probing(),
          'stalled while still probing',
        );

        expect(stalled.measuredBackend, isNull);
        expect(stalled.missingFeatures, isEmpty);
        expect(stalled.unavailable, isTrue);
      });

      test('an overlay on an earlier failure keeps that failure\'s '
          'measurements, so a retry cannot erase them', () {
        final first = StorageDurability.unavailableOver(measured, 'first');
        final second = StorageDurability.unavailableOver(first, 'second');

        expect(second.measuredBackend, StorageBackend.opfsLocks);
        expect(second.missingFeatures, isNotEmpty);
        expect(second.unavailableReason, 'second');
      });

      test('cause is carried, so an L7 downgrade overlay is still an L7 '
          'downgrade', () {
        final stalled = StorageDurability.unavailableOver(
          measured,
          'db is newer',
          cause: StorageUnavailableCause.schemaDowngrade,
        );

        expect(stalled.unavailableCause, StorageUnavailableCause.schemaDowngrade);
        expect(storageRetryNotice(stalled), isNull);
      });

      test('equality distinguishes two overlays that measured different '
          'backends', () {
        expect(
          StorageDurability.unavailableOver(measured, 'x'),
          StorageDurability.unavailableOver(measured, 'x'),
        );
        expect(
          StorageDurability.unavailableOver(measured, 'x').hashCode,
          StorageDurability.unavailableOver(measured, 'x').hashCode,
        );
        expect(
          StorageDurability.unavailableOver(measured, 'x'),
          isNot(const StorageDurability.unavailable('x')),
          reason: 'a verdict that remembers opfsLocks is NOT the same value as '
              'one that remembers nothing — main.dart reverts on exactly this '
              'equality',
        );
      });

      test('the preserved measurement reaches the release log line', () {
        final lines = _captureDebugPrint(() {
          logStorageDurability(
            StorageDurability.unavailableOver(measured, 'did not answer'),
          );
        });

        expect(lines.single, contains('backend=unavailable'));
        expect(
          lines.single,
          contains('measured=opfsLocks'),
          reason: 'the console line is the only artifact a web field report '
              'can ever carry',
        );
        expect(
          lines.single,
          contains('dedicatedWorkersInSharedWorkers'),
        );
      });

      test('a plain verdict does not repeat itself in the log', () {
        final lines = _captureDebugPrint(() {
          logStorageDurability(
            const StorageDurability(backend: StorageBackend.opfsLocks),
          );
        });

        expect(lines.single, isNot(contains('measured=')));
      });
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

  group('boundStorageOpen', () {
    // B4. `WasmDatabase.open` has no timeout, and neither does anything drift
    // calls underneath it. A wedged worker left the open future pending for the
    // lifetime of the page: no verdict, no error, and `storageDurabilityProvider`
    // stuck at `probing`, which the create-topo interlock reads as "allow
    // creation" — writes accepted into a database nobody can reach.
    //
    // The bound lives here rather than in `connection_web.dart` because that
    // file imports `package:drift/wasm.dart` (and so `dart:js_interop`) and
    // cannot be loaded by the Dart VM at all. This drives the SAME function
    // production calls; `connection_seam_source_test.dart` pins that
    // `connection_web.dart` really routes its open through it.
    const tiny = Duration(milliseconds: 10);

    test('an open that never completes surfaces as a failure, with an honest '
        'reason naming the subsystem and the bound', () async {
      final wedged = Completer<void>();
      addTearDown(() => wedged.complete());

      await expectLater(
        boundStorageOpen(wedged.future, timeout: tiny),
        throwsA(
          isA<TimeoutException>()
              .having(
                (e) => e.message,
                'message',
                contains('did not finish opening the local database'),
              )
              .having((e) => e.duration, 'duration', tiny),
        ),
      );
    });

    test('routed through the connection layer\'s report shape it becomes an '
        'unavailable verdict the retry banner can act on', () async {
      // Exactly `openConnection`'s `catch`: report, then rethrow.
      final wedged = Completer<void>();
      addTearDown(() => wedged.complete());
      StorageDurability? reported;

      await expectLater(() async {
        try {
          await boundStorageOpen(wedged.future, timeout: tiny);
        } catch (error) {
          reported = StorageDurability.unavailable('$error');
          rethrow;
        }
      }(), throwsA(isA<TimeoutException>()));

      expect(reported, isNotNull);
      expect(reported!.unavailable, isTrue);
      expect(
        reported!.isEphemeral,
        isTrue,
        reason: 'a database that never opened must not be trusted with writes',
      );
      expect(
        reported!.isProbing,
        isFalse,
        reason: 'THE fix: without a bound this stayed `probing` forever, and '
            'the create-topo interlock reads `probing` as allow-creation',
      );
      expect(
        reported!.unavailableReason,
        contains('did not finish opening the local database'),
        reason: 'the release masi/storage: line has to say what wedged',
      );
      expect(
        storageRetryNotice(reported!),
        isNotNull,
        reason: 'classified as `failed`, so the in-app retry is offered rather '
            'than the user being left with no way back',
      );
    });

    test('a slow-but-successful open is passed straight through — a timeout '
        'must not turn slow into broken', () async {
      final open = Future<String>.delayed(
        const Duration(milliseconds: 5),
        () => 'executor',
      );

      expect(await boundStorageOpen(open, timeout: const Duration(seconds: 5)),
          'executor');
    });

    test('a real open error is passed through unchanged, not relabelled as a '
        'timeout', () async {
      await expectLater(
        boundStorageOpen(
          Future<void>.error(StateError('worker blew up')),
          timeout: tiny,
        ),
        throwsA(isA<StateError>()),
      );
    });

    test('the default bound is generous enough for a cold open yet tighter '
        'than boot\'s generic fallback', () {
      expect(
        kStorageOpenTimeout >= const Duration(seconds: 10),
        isTrue,
        reason: 'a cold low-end Android fetching drift_worker.js over slow '
            'mobile data must not be called broken',
      );
      expect(
        kStorageOpenTimeout < const Duration(seconds: 30),
        isTrue,
        reason: "must fire before main.dart's kBootStorageDeadline, so the "
            'specific reason beats the generic one',
      );
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

    test('logs a failed open with its reason — without this, a throwing '
        'WasmDatabase.open leaves no production signal at all', () {
      final lines = _captureDebugPrint(() {
        logStorageDurability(
          const StorageDurability.unavailable('MissingBrowserFeature.workerError'),
        );
      });
      expect(lines, hasLength(1));
      expect(lines.single, contains('masi/storage:'));
      expect(lines.single, contains('backend=unavailable'));
      expect(lines.single, contains('durable=false'));
      expect(lines.single, contains('reason=MissingBrowserFeature.workerError'));
    });
  });
}
