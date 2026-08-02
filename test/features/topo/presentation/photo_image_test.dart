// Widget/unit tests for `PhotoImage`/`PhotoImageProvider` (Phase 2C web
// port): the shared façade that replaced every remaining
// `Image.file(File(...))`/`FileImage(File(...))`/`File(...).existsSync()`
// display site. Running under plain `flutter test` (the Dart VM) means
// `dart.library.io` is true, so the conditional-export facade
// (`photo_image_source.dart`) always resolves to the NATIVE backend here —
// exactly like every other conditional-export facade in this codebase
// (`PhotoFiles`, `image_ops`, `ar_support`): the web backend is only ever
// selected by a real `dart2wasm`/`dart2js` web compile, not by `flutter
// test` on the VM, so it isn't (and can't be) exercised by this file.
//
// Real photo bytes + `tester.runAsync` mirror `topos_screen_test.dart`'s
// established pattern for driving an actual `Image.file`/`FileImage` decode
// under a widget test's fake-async clock (see that file's `_drain` doc):
// dart:io file reads and `ui.instantiateImageCodec` are real async platform
// work that only progresses under the REAL event loop, not fake-time
// `pump()`s alone.
import 'dart:convert';
import 'dart:io';

import 'package:masi/features/topo/data/photo_files.dart';
import 'package:masi/features/topo/presentation/photo_image.dart';
import 'package:masi/features/topo/presentation/photo_image_self_heal_guard.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import '../../../support/async_drain.dart';

/// A minimal-but-real 1x1 transparent PNG, so `Image.file`/`FileImage` have
/// genuine bytes to decode rather than a mocked-out step — same fixture
/// `topos_screen_test.dart` uses for the same reason.
final _tinyPngBytes = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY'
  '42YAAAAASUVORK5CYII=',
);

/// Mirrors `topos_screen_test.dart`'s `_drain`: advances the REAL event loop
/// (in small increments) so genuinely-async dart:io/decode work started by
/// the widget under test actually gets a chance to complete, then pumps to
/// flush the resulting rebuild.
///
/// Every assertion in this file that depends on a real `dart:io` read +
/// `ui.instantiateImageCodec` decode having FINISHED pairs this with an
/// explicit [pumpUntilFound]/[pumpUntilGone] on the very widget it is about —
/// a drain alone is a wall-clock bet, and this file's decodes are the slowest
/// real work in the suite. The one thing deliberately NOT waited on is the
/// "still loading right after a single `pump()`" half of the #56 tests: that
/// asserts the decode has NOT finished, which is guaranteed by construction
/// (without a `tester.runAsync` the real event loop never turns at all, so a
/// real file read cannot possibly have completed) and, unlike everything
/// else here, becomes MORE true under load rather than less.
Future<void> _drain(WidgetTester tester) async {
  await drainAsync(tester, rounds: 6, settle: false);
}

/// Real-time deadline for the two `PhotoImageProvider` probe tests below,
/// which drive an `ImageStream` directly (no widget tree, so no pump). A
/// safety valve, not a timing assumption: both loops exit the instant the
/// stream reports, and both leave their assertions untouched.
const _probeTimeout = Duration(seconds: 20);

Widget _wrap(Widget child) =>
    ProviderScope(child: MaterialApp(home: Scaffold(body: child)));

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('photo_image_test_');
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  group('PhotoImage (native backend)', () {
    testWidgets(
      'renders the real decoded photo at an existing absolute path, with no '
      'exception',
      (tester) async {
        final file = File(p.join(tempDir.path, 'real.png'))
          ..writeAsBytesSync(_tinyPngBytes);

        await tester.pumpWidget(
          _wrap(PhotoImage(file.path, width: 40, height: 40)),
        );
        await _drain(tester);

        expect(find.byType(Image), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'fit/width/height pass straight through to the underlying Image, '
      'exactly like the old direct Image.file call sites',
      (tester) async {
        final file = File(p.join(tempDir.path, 'sized.png'))
          ..writeAsBytesSync(_tinyPngBytes);

        await tester.pumpWidget(
          _wrap(
            PhotoImage(file.path, fit: BoxFit.contain, width: 77, height: 88),
          ),
        );
        await tester.pump();

        final image = tester.widget<Image>(find.byType(Image));
        expect(image.fit, BoxFit.contain);
        expect(image.width, 77);
        expect(image.height, 88);
      },
    );

    testWidgets(
      'a missing/undecodable photo shows the given placeholder instead of a '
      'broken-image icon (replaces the old File(...).existsSync() gate)',
      (tester) async {
        final missingPath = p.join(tempDir.path, 'missing.png');

        await tester.pumpWidget(
          _wrap(
            PhotoImage(
              missingPath,
              placeholder: () =>
                  const Icon(Icons.image_not_supported, key: Key('ph')),
            ),
          ),
        );
        await _drain(tester);
        await pumpUntilFound(tester, find.byKey(const Key('ph')));

        expect(find.byKey(const Key('ph')), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'with no placeholder given, a missing photo degrades to an empty box '
      '(the default every migrated call site without its own fallback used)',
      (tester) async {
        final missingPath = p.join(tempDir.path, 'missing-no-placeholder.png');

        await tester.pumpWidget(_wrap(PhotoImage(missingPath)));
        await _drain(tester);

        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      '#56: cacheWidth/cacheHeight pass straight through to the underlying '
      'Image.file\'s own decode-size hints',
      (tester) async {
        final file = File(p.join(tempDir.path, 'cache-size.png'))
          ..writeAsBytesSync(_tinyPngBytes);

        await tester.pumpWidget(
          _wrap(
            PhotoImage(
              file.path,
              width: 40,
              height: 40,
              cacheWidth: 80,
              cacheHeight: 90,
            ),
          ),
        );
        await tester.pump();

        final image = tester.widget<Image>(find.byType(Image));
        // `Image.file(..., cacheWidth:, cacheHeight:)` has no `cacheWidth`/
        // `cacheHeight` getters of its own -- the constructor folds them
        // into `image = ResizeImage.resizeIfNeeded(cacheWidth, cacheHeight,
        // <provider>)` (see `Image.file`'s source). So the only observable
        // proof the params were threaded through is the resulting `image`
        // provider: it must be a `ResizeImage` wrapping the underlying
        // `FileImage`, carrying `width`/`height` exactly equal to what was
        // passed in (neither `Image.file` nor `PhotoImage`/
        // `PlatformPhotoImage` do any devicePixelRatio math of their own --
        // that scaling, when wanted, is the CALLER's job, e.g.
        // `topos_row.dart`'s `_Thumbnail` computing `52 * devicePixelRatio`
        // before it ever reaches here -- this test passes already-physical
        // 80/90 literals straight through, so the expected `ResizeImage`
        // values are those same literals, unscaled).
        expect(image.image, isA<ResizeImage>());
        final resizeImage = image.image as ResizeImage;
        expect(resizeImage.width, 80);
        expect(resizeImage.height, 90);
      },
    );

    testWidgets(
      '#56: loadingPlaceholder shows while the real decode is still '
      'pending -- DISTINCT from placeholder -- then disappears once the '
      'photo actually loads, with no exception',
      (tester) async {
        final file = File(p.join(tempDir.path, 'loading-then-found.png'))
          ..writeAsBytesSync(_tinyPngBytes);

        await tester.pumpWidget(
          _wrap(
            PhotoImage(
              file.path,
              loadingPlaceholder: () =>
                  const SizedBox(key: Key('loading'), width: 1, height: 1),
              placeholder: () =>
                  const SizedBox(key: Key('missing'), width: 1, height: 1),
            ),
          ),
        );
        // A single pump, no drain: the real file read/decode hasn't had a
        // chance to complete yet, so this must still be the LOADING state.
        await tester.pump();

        expect(
          find.byKey(const Key('loading')),
          findsOneWidget,
          reason: 'still loading -- must show loadingPlaceholder',
        );
        expect(
          find.byKey(const Key('missing')),
          findsNothing,
          reason: 'a photo that decodes fine must never show placeholder',
        );

        await _drain(tester);
        await pumpUntilGone(tester, find.byKey(const Key('loading')));

        expect(tester.takeException(), isNull);
        expect(
          find.byKey(const Key('loading')),
          findsNothing,
          reason:
              'once the frame has arrived, loadingPlaceholder must be gone',
        );
        expect(find.byKey(const Key('missing')), findsNothing);
      },
    );

    testWidgets(
      '#56: a MISSING photo eventually shows the static placeholder, NEVER '
      'the loadingPlaceholder, once resolution completes -- proving a '
      'missing photo does not shimmer forever',
      (tester) async {
        final missingPath = p.join(tempDir.path, 'loading-then-missing.png');

        await tester.pumpWidget(
          _wrap(
            PhotoImage(
              missingPath,
              loadingPlaceholder: () =>
                  const SizedBox(key: Key('loading'), width: 1, height: 1),
              placeholder: () =>
                  const SizedBox(key: Key('missing'), width: 1, height: 1),
            ),
          ),
        );
        // A single pump, no drain: the async open-and-fail hasn't resolved
        // yet, so this must still read as LOADING, not missing.
        await tester.pump();

        expect(
          find.byKey(const Key('loading')),
          findsOneWidget,
          reason: 'not yet resolved -- must show loadingPlaceholder, not '
              'jump straight to the missing-photo placeholder',
        );
        expect(find.byKey(const Key('missing')), findsNothing);

        await _drain(tester);
        await pumpUntilFound(tester, find.byKey(const Key('missing')));

        expect(tester.takeException(), isNull);
        expect(
          find.byKey(const Key('missing')),
          findsOneWidget,
          reason: 'resolved-missing must show the static placeholder',
        );
        expect(
          find.byKey(const Key('loading')),
          findsNothing,
          reason:
              'a confirmed-missing photo must never keep showing '
              'loadingPlaceholder -- that would shimmer forever',
        );
      },
    );
  });

  group('PhotoImageProvider (native dimension probe)', () {
    testWidgets(
      'resolves to the real decoded image size for an existing file — the '
      'same contract FileImage(File(path)).resolve(...) had',
      (tester) async {
        final file = File(p.join(tempDir.path, 'probe.png'))
          ..writeAsBytesSync(_tinyPngBytes);

        ImageInfo? result;
        Object? error;
        final provider = PhotoImageProvider(
          file.path,
          photoFiles: PhotoFiles(),
        );

        await tester.runAsync(() async {
          final stream = provider.resolve(const ImageConfiguration());
          late ImageStreamListener listener;
          listener = ImageStreamListener(
            (info, synchronousCall) {
              result = info;
              stream.removeListener(listener);
            },
            onError: (exception, stackTrace) {
              error = exception;
              stream.removeListener(listener);
            },
          );
          stream.addListener(listener);
          // Wait for the real decode under the real event loop (mirrors
          // `_drain`'s reasoning, just without a widget pump to flush — this
          // test has no widget tree). Bounded by a DEADLINE rather than a
          // fixed iteration count: the old `i < 20` capped the decode at
          // 200 ms of wall clock, which is plenty on an idle machine and not
          // remotely enough on a loaded one — the loop would give up and
          // `expect(result, isNotNull)` would fail for scheduling reasons
          // alone. It still exits the instant the stream reports.
          final deadline = DateTime.now().add(_probeTimeout);
          while (result == null &&
              error == null &&
              DateTime.now().isBefore(deadline)) {
            await Future<void>.delayed(const Duration(milliseconds: 5));
          }
        });

        expect(error, isNull);
        expect(result, isNotNull);
        expect(result!.image.width, 1);
        expect(result!.image.height, 1);
      },
    );

    testWidgets(
      'reports a stream error for a missing file, mirroring FileImage\'s own '
      'decode-failure contract rather than hanging forever',
      (tester) async {
        final missingPath = p.join(tempDir.path, 'probe-missing.png');
        Object? error;
        final provider = PhotoImageProvider(
          missingPath,
          photoFiles: PhotoFiles(),
        );

        await tester.runAsync(() async {
          final stream = provider.resolve(const ImageConfiguration());
          late ImageStreamListener listener;
          listener = ImageStreamListener(
            (info, synchronousCall) {
              stream.removeListener(listener);
            },
            onError: (exception, stackTrace) {
              error = exception;
              stream.removeListener(listener);
            },
          );
          stream.addListener(listener);
          // Deadline-bounded for the same reason as the sibling probe test
          // above: the old fixed 20x10 ms cap was a wall-clock bet.
          final deadline = DateTime.now().add(_probeTimeout);
          while (error == null && DateTime.now().isBefore(deadline)) {
            await Future<void>.delayed(const Duration(milliseconds: 5));
          }
        });

        expect(error, isNotNull);
      },
    );
  });

  group('photo self-heal guard (web backend, pure logic)', () {
    // `photo_image_source_web.dart`'s `_PlatformPhotoImageState` self-heals
    // when `PhotoImageCache` revokes an object URL out from under a
    // still-mounted widget (e.g. an inactive IndexedStack tab), by
    // re-resolving through the cache once per key. That whole file
    // transitively imports `package:web`, which does not compile under
    // plain `flutter test` (VM) — see this file's header doc — so the
    // decision logic was factored out into `photo_image_self_heal_guard.dart`
    // (zero web/js_interop dependencies) specifically so it's unit-testable
    // here. These tests exercise that guard directly.

    test(
      'attempts a heal when the failed URL matches what is on screen and no '
      'attempt has been made yet for this key',
      () {
        expect(
          shouldAttemptPhotoSelfHeal(
            failedUrl: 'blob:a',
            currentUrl: 'blob:a',
            alreadyAttemptedUrl: null,
          ),
          isTrue,
        );
      },
    );

    test(
      'does NOT attempt a heal for a stale error (failed URL no longer '
      'matches what is currently displayed)',
      () {
        expect(
          shouldAttemptPhotoSelfHeal(
            failedUrl: 'blob:old',
            currentUrl: 'blob:new',
            alreadyAttemptedUrl: null,
          ),
          isFalse,
        );
      },
    );

    test(
      'does NOT attempt a second heal for the same key — the infinite-loop '
      'guard: once an attempt has been recorded, further failures degrade '
      'straight to the placeholder',
      () {
        expect(
          shouldAttemptPhotoSelfHeal(
            failedUrl: 'blob:b',
            currentUrl: 'blob:b',
            alreadyAttemptedUrl: 'blob:a', // an earlier attempt already ran.
          ),
          isFalse,
        );
      },
    );

    test(
      'a re-resolve that returns a fresh, different URL counts as a '
      'successful heal',
      () {
        expect(
          isSuccessfulPhotoSelfHeal(
            resolvedUrl: 'blob:fresh',
            failedUrl: 'blob:stale',
          ),
          isTrue,
        );
      },
    );

    test(
      'a re-resolve that returns null (bytes genuinely gone) is NOT a '
      'successful heal — falls through to the placeholder instead of '
      'spinning',
      () {
        expect(
          isSuccessfulPhotoSelfHeal(resolvedUrl: null, failedUrl: 'blob:x'),
          isFalse,
        );
      },
    );

    test(
      'a re-resolve that defensively echoes back the exact URL that just '
      'failed is NOT a successful heal',
      () {
        expect(
          isSuccessfulPhotoSelfHeal(
            resolvedUrl: 'blob:x',
            failedUrl: 'blob:x',
          ),
          isFalse,
        );
      },
    );
  });
}
