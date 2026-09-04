import 'package:flutter_test/flutter_test.dart';
import 'package:masi/features/scan/domain/rock_scan_status.dart';

void main() {
  group('RockScanUpload.fromWire', () {
    test('parses every declared name', () {
      for (final value in RockScanUpload.values) {
        expect(RockScanUpload.fromWire(value.name), value);
      }
    });

    test('falls back to pending for unknown, null and non-string input', () {
      // The fallback is forward compatibility, not laziness: this value comes
      // out of a database row a NEWER build may have written, and an old
      // client meeting a state it has never heard of must offer to upload
      // again rather than crash the library screen.
      expect(RockScanUpload.fromWire('transcoding'), RockScanUpload.pending);
      expect(RockScanUpload.fromWire(null), RockScanUpload.pending);
      expect(RockScanUpload.fromWire(42), RockScanUpload.pending);
    });
  });

  group('RockScanStatus.fromWire', () {
    test('parses every declared name', () {
      for (final value in RockScanStatus.values) {
        expect(RockScanStatus.fromWire(value.name), value);
      }
    });

    test('falls back to pending for unknown input', () {
      expect(RockScanStatus.fromWire('meshing'), RockScanStatus.pending);
      expect(RockScanStatus.fromWire(null), RockScanStatus.pending);
    });
  });

  group('rockScanPhase', () {
    test('a finished reconstruction outranks whatever the upload says', () {
      // The row that syncs down to a SECOND device is exactly this case: that
      // device never uploaded anything, so `uploadState` is whatever the
      // capturing phone last pushed — but the map demonstrably exists.
      for (final upload in RockScanUpload.values) {
        expect(
          rockScanPhase(upload: upload, status: RockScanStatus.ready),
          RockScanPhase.ready,
          reason: 'ready must win over uploadState ${upload.name}',
        );
      }
    });

    test('a failed reconstruction outranks the upload column too', () {
      for (final upload in RockScanUpload.values) {
        expect(
          rockScanPhase(upload: upload, status: RockScanStatus.failed),
          RockScanPhase.reconstructionFailed,
        );
      }
    });

    test('processing outranks the upload column', () {
      expect(
        rockScanPhase(
          upload: RockScanUpload.pending,
          status: RockScanStatus.processing,
        ),
        RockScanPhase.reconstructing,
      );
    });

    test('uploaded but not yet claimed reads as reconstructing', () {
      // Sitting in the queue is not a state a climber can act on, so it is
      // shown as the same "we are working on it" as active processing.
      expect(
        rockScanPhase(
          upload: RockScanUpload.uploaded,
          status: RockScanStatus.pending,
        ),
        RockScanPhase.reconstructing,
      );
    });

    test('a failed upload is surfaced, not hidden behind a pending job', () {
      // The whole point of the ordering: this is the one state the user can
      // fix, so it must not be reported as "reconstructing".
      final phase = rockScanPhase(
        upload: RockScanUpload.failed,
        status: RockScanStatus.pending,
      );
      expect(phase, RockScanPhase.uploadFailed);
      expect(phase.needsUser, isTrue);
    });

    test('freshly recorded, nothing sent', () {
      final phase = rockScanPhase(
        upload: RockScanUpload.pending,
        status: RockScanStatus.pending,
      );
      expect(phase, RockScanPhase.onDevice);
      expect(phase.needsUser, isTrue);
    });

    test('in-flight upload needs nothing from the user', () {
      final phase = rockScanPhase(
        upload: RockScanUpload.uploading,
        status: RockScanStatus.pending,
      );
      expect(phase, RockScanPhase.uploading);
      expect(phase.needsUser, isFalse);
    });

    test('needsUser marks exactly the actionable phases', () {
      expect(
        {for (final p in RockScanPhase.values) if (p.needsUser) p},
        {
          RockScanPhase.onDevice,
          RockScanPhase.uploadFailed,
          RockScanPhase.reconstructionFailed,
        },
      );
    });

    test('every upload/status combination resolves to some phase', () {
      // Guards the switch in `rockScanPhase` against a future enum value
      // being added without a branch.
      for (final upload in RockScanUpload.values) {
        for (final status in RockScanStatus.values) {
          expect(
            () => rockScanPhase(upload: upload, status: status),
            returnsNormally,
          );
        }
      }
    });
  });
}
