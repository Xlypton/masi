// Pure, dependency-free classification + user-message contract for the L3
// fix. Runs on the plain Dart VM: classifyPhotoWriteFailure is deliberately
// string-based (see its doc) precisely so the BROWSER quota shape is testable
// without a browser test runner.
import 'package:flutter_test/flutter_test.dart';
import 'package:idb_shim/idb.dart' show DatabaseError;
import 'package:masi/features/topo/data/photo_write_exception.dart';

void main() {
  group('classifyPhotoWriteFailure', () {
    test('a Blink/WebKit DOMException name is quotaExceeded', () {
      // The exact shape idb_shim's DatabaseErrorNative.toString() produces:
      // '<DOMException.name>: <DOMException.message>'.
      expect(
        classifyPhotoWriteFailure(
          DatabaseError('QuotaExceededError: The quota has been exceeded.'),
        ),
        PhotoWriteFailure.quotaExceeded,
      );
    });

    test('legacy Gecko NS_ERROR_DOM_QUOTA_REACHED is quotaExceeded', () {
      expect(
        classifyPhotoWriteFailure(
          DatabaseError('NS_ERROR_DOM_QUOTA_REACHED: persistent storage full'),
        ),
        PhotoWriteFailure.quotaExceeded,
      );
    });

    test('matching is case-insensitive', () {
      expect(
        classifyPhotoWriteFailure(Exception('quotaexceedederror')),
        PhotoWriteFailure.quotaExceeded,
      );
    });

    test('any other store error is unknown', () {
      expect(
        classifyPhotoWriteFailure(
          DatabaseError('InvalidStateError: database is closed'),
        ),
        PhotoWriteFailure.unknown,
      );
    });
  });

  group('PhotoWriteException', () {
    test('quotaExceeded userMessage names running out of space, in plain '
        'words, without leaking the raw exception name', () {
      const e = PhotoWriteException(
        failure: PhotoWriteFailure.quotaExceeded,
        key: 'photos/abc.jpg',
      );
      expect(e.userMessage, contains('Out of storage space'));
      expect(e.userMessage, isNot(contains('QuotaExceededError')));
    });

    test('unknown userMessage is a plain retry prompt', () {
      const e = PhotoWriteException(
        failure: PhotoWriteFailure.unknown,
        key: 'photos/abc.jpg',
      );
      expect(e.userMessage, contains('could not be saved'));
    });

    test('the two userMessages are distinguishable from each other', () {
      const quota = PhotoWriteException(
        failure: PhotoWriteFailure.quotaExceeded,
        key: 'photos/abc.jpg',
      );
      const unknown = PhotoWriteException(
        failure: PhotoWriteFailure.unknown,
        key: 'photos/abc.jpg',
      );
      expect(quota.userMessage, isNot(unknown.userMessage));
    });

    test('toString carries the failure kind, the key and the cause', () {
      final e = PhotoWriteException(
        failure: PhotoWriteFailure.quotaExceeded,
        key: 'photos/abc.jpg',
        cause: DatabaseError('QuotaExceededError'),
      );
      expect(e.toString(), contains('quotaExceeded'));
      expect(e.toString(), contains('photos/abc.jpg'));
      expect(e.toString(), contains('QuotaExceededError'));
    });
  });
}
