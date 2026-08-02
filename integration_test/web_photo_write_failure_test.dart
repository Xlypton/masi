// Claim 3 of the photo-durability work: when browser storage genuinely
// cannot hold a photo, the user is TOLD — the failure does not vanish into a
// debugPrint and the app does not keep a topo whose document is missing.
//
// Run it:
//   tool/drive_web.sh integration_test/web_photo_write_failure_test.dart
//
// -----------------------------------------------------------------------
// WHY THIS EXISTS WHEN A WIDGET TEST ALREADY COVERS IT
// -----------------------------------------------------------------------
// `test/features/library/presentation/topos_screen_test.dart` has an L3 case,
// but it runs on the Dart VM and its `_QuotaFailingPhotoFiles` throws a
// hand-written `PhotoWriteException(failure: quotaExceeded, ...)`. That
// asserts the UI reacts to an exception someone constructed; it cannot
// assert that a real browser failure BECOMES that exception. Three links in
// the chain are unreachable from the VM:
//
//   * `photo_files_web.dart` — the only implementation that throws
//     `PhotoWriteException` at all (the native one never does);
//   * `IdbPhotoByteStore` against real IndexedDB; and
//   * `classifyPhotoWriteFailure`, which is a STRING MATCH against
//     `_quotaMarkers`. Whether a real Chrome quota rejection stringifies to
//     something containing "quotaexceedederror" is precisely the kind of
//     thing a fabricated `Exception('QuotaExceededError: ...')` assumes
//     rather than tests.
//
// So this file runs the real web stack in real Chrome, and — the part that
// matters — does not invent the error. It provokes Chrome's OWN quota
// machinery by overflowing `localStorage`, captures the `QuotaExceededError`
// object Chrome throws, and feeds THAT to the photo byte store. The
// classifier then has to cope with a genuine browser error object.
//
// -----------------------------------------------------------------------
// WHAT IS STILL SYNTHETIC, STATED PLAINLY
// -----------------------------------------------------------------------
// The error object is real; the moment it is raised is not. Exhausting the
// IndexedDB quota for real would mean writing tens of gigabytes (Chrome
// grants an origin ~60% of total disk), which is not something this suite
// can do on a machine already at 99% full. What that would take, if the
// stronger form is ever wanted: put `--user-data-dir` on a small mounted
// disk image so Chrome computes a small quota, or drive
// `Storage.overrideQuota` over CDP — chromedriver exposes
// `/session/{id}/goog/cdp/execute`, but `flutter drive` does not hand the
// test its WebDriver session, so that needs the raw-WebDriver harness shape
// of `tool/verify_offline_shell.py` rather than `integration_test`.
//
// The screen is also pumped directly rather than reached through the router,
// because `router.dart:328` builds `TopoCanvasScreen`/`ToposScreen` without
// forwarding their `photoSourcePicker`/`photoPicker` params and
// `image_picker` opens an OS dialog no test can tap. Everything below the
// picker is production code.
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:integration_test/integration_test.dart';
import 'package:masi/app/theme.dart';
import 'package:masi/core/db/database_provider.dart';
import 'package:masi/features/library/application/library_providers.dart';
import 'package:masi/features/library/presentation/topos_screen.dart';
import 'package:masi/features/topo/data/photo_byte_store.dart';
import 'package:masi/features/topo/data/photo_files.dart';
import 'package:web/web.dart' as web;

import 'web_photo_offline_fixture.dart';

/// A [PhotoByteStore] that fails every write with [error].
///
/// [error] is not constructed here — it is an object Chrome threw, handed in
/// by [captureRealQuotaExceededError]. Reads/deletes are answered rather than
/// thrown so that only the WRITE path is under test.
class _FailingWriteStore implements PhotoByteStore {
  _FailingWriteStore(this.error);

  final Object error;
  int writeAttempts = 0;

  @override
  Future<void> writeBytes(String key, Uint8List bytes) async {
    writeAttempts++;
    throw error;
  }

  @override
  Future<Uint8List?> readBytes(String key) async => null;

  @override
  Future<void> delete(String key) async {}

  @override
  Future<bool> exists(String key) async => false;
}

/// Makes Chrome raise a real `QuotaExceededError` and returns it.
///
/// `localStorage` is capped at roughly 5 MB per origin and is enforced by the
/// same quota machinery that rejects an oversized IndexedDB write, so the
/// DOMException it throws is the genuine article — not a `DOMException(...)`
/// this test built to look like one. Returns null if the browser somehow
/// accepted 50 MB, which the caller treats as a failed precondition rather
/// than quietly carrying on.
Object? captureRealQuotaExceededError() {
  final storage = web.window.localStorage;
  // 256K UTF-16 chars = 512 KB per key; 100 keys = ~50 MB, ~10x the cap.
  final chunk = 'x' * (256 * 1024);
  Object? captured;
  try {
    for (var i = 0; i < 100; i++) {
      storage.setItem('masi-quota-probe-$i', chunk);
    }
  } catch (error) {
    captured = error;
  } finally {
    for (var i = 0; i < 100; i++) {
      storage.removeItem('masi-quota-probe-$i');
    }
  }
  return captured;
}

/// Wraps [screen] in a real GoRouter + the real theme, mirroring
/// `topos_screen_test.dart`'s `_wrap`. `/walls/:wallId` must exist because a
/// SUCCESSFUL create pushes it — its absence in the tree afterwards is how a
/// test tells success from failure.
Widget _wrap(Widget screen) {
  final router = GoRouter(
    initialLocation: '/',
    routes: [
      GoRoute(path: '/', builder: (context, state) => screen),
      GoRoute(
        path: '/walls/:wallId',
        builder: (context, state) =>
            const SizedBox(key: Key('fake-canvas-route')),
      ),
      GoRoute(path: '/areas', builder: (context, state) => const SizedBox()),
      GoRoute(
        path: '/community',
        builder: (context, state) => const SizedBox(),
      ),
    ],
  );
  return MaterialApp.router(theme: MasiTheme.light, routerConfig: router);
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final observed = <String, Object?>{};
  void record(Map<String, Object?> entries) {
    observed.addAll(entries);
    binding.reportData = Map<String, Object?>.from(observed);
  }

  testWidgets(
    'a real Chrome QuotaExceededError, carried through the real web '
    'PhotoFiles, reaches the user as the out-of-storage SnackBar and leaves '
    'no photo-less topo behind',
    (tester) async {
      // -------------------------------------------------------------
      // 1. Get a genuine quota error out of Chrome.
      // -------------------------------------------------------------
      final captured = captureRealQuotaExceededError();
      record({'captured_error': captured?.toString()});
      expect(
        captured,
        isNotNull,
        reason: 'the browser accepted ~50 MB of localStorage without '
            'complaining, so no real quota error could be captured and this '
            'test has nothing genuine to assert with',
      );

      // The load-bearing link the VM test cannot reach: a real browser error
      // object has to be RECOGNISED as a quota failure by a classifier that
      // works on `error.toString()`. If Chrome or dart2js ever changes how
      // this stringifies, the user silently starts getting the generic
      // message instead of "free up space" — so assert it here, with the
      // actual string in the failure output.
      final classified = classifyPhotoWriteFailure(captured!);
      record({'classified_as': classified.name});
      expect(
        classified,
        PhotoWriteFailure.quotaExceeded,
        reason: 'classifyPhotoWriteFailure did not recognise a REAL Chrome '
            'quota rejection. It matches `_quotaMarkers` against '
            'error.toString(), which here was: "$captured". Users hitting a '
            'full device would get the generic "could not be saved" message '
            'instead of being told to free up space.',
      );

      // -------------------------------------------------------------
      // 2. The real production flow, with the real web PhotoFiles wrapped
      //    around a store that raises that error.
      // -------------------------------------------------------------
      final store = _FailingWriteStore(captured);
      final container = ProviderContainer(
        overrides: [
          photoFilesProvider.overrideWithValue(PhotoFiles(byteStore: store)),
        ],
      );
      addTearDown(container.dispose);

      final bytes = buildPhotoBytes();
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: _wrap(
            ToposScreen(
              photoSourcePicker: (context) async => ImageSource.gallery,
              photoPicker: (source) async =>
                  XFile.fromData(bytes, name: photoFileName, mimeType: 'image/jpeg'),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle(const Duration(seconds: 2));

      final ready = await pumpUntil(
        tester,
        () => tester.any(find.byKey(const Key('topos-new-topo'))),
        timeout: const Duration(seconds: 60),
      );
      expect(
        ready,
        isTrue,
        reason: 'the New topo button never appeared — if '
            'topos-storage-warning is up, this browser reported ephemeral '
            'storage and creation is disabled for a different reason',
      );
      await binding.takeScreenshot('photo-06-writefail-home');

      await tester.tap(find.byKey(const Key('topos-new-topo')));
      await tester.pumpAndSettle(const Duration(seconds: 1));

      // The name dialog comes BEFORE the write (topos_screen.dart:537), so
      // the flow has to be carried through it to reach the failure.
      final dialogUp = await pumpUntil(
        tester,
        () => tester.any(find.byKey(const Key('topo-name-field'))),
        timeout: const Duration(seconds: 30),
      );
      expect(
        dialogUp,
        isTrue,
        reason: 'the name dialog never opened, so the picked photo never '
            'even reached the decode step',
      );
      await tester.tap(find.byKey(const Key('topo-name-submit')));

      // -------------------------------------------------------------
      // 3. THE ASSERTION: the user is told.
      //
      //    No trailing pumpAndSettle — a SnackBar animates out, and settling
      //    would wait for it to leave.
      // -------------------------------------------------------------
      final told = await pumpUntil(
        tester,
        () => tester.any(find.textContaining('Out of storage space')),
        timeout: const Duration(seconds: 60),
      );
      record({'write_attempts': store.writeAttempts});
      expect(
        told,
        isTrue,
        reason: 'THE FAILURE THIS TEST EXISTS FOR: the photo could not be '
            'written and the user was never told. The bytes vanished into a '
            'debugPrint.',
      );
      expect(find.byType(SnackBar), findsOneWidget);
      await binding.takeScreenshot('photo-07-writefail-snackbar');

      expect(
        store.writeAttempts,
        greaterThan(0),
        reason: 'the store was never asked to write, so the SnackBar above '
            'came from something other than the byte-write path',
      );

      // -------------------------------------------------------------
      // 4. And nothing broken is left behind. `createTopo` commits a wall
      //    BEFORE `attachPhotoToWall` runs, so a missed cleanup leaves a
      //    permanently photo-less topo on the home screen.
      // -------------------------------------------------------------
      final topos = await container
          .read(libraryCrudRepositoryProvider)
          .watchTopos()
          .first;
      record({'topos_after_failure': topos.length});
      expect(
        topos,
        isEmpty,
        reason: 'a topo survived a failed photo write — it would render as a '
            'blank canvas forever',
      );
      expect(
        find.byKey(const Key('fake-canvas-route')),
        findsNothing,
        reason: 'the app navigated into a canvas that has no photo to show',
      );

      record({'write_failure_proven': true});
    },
  );
}
