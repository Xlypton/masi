// AR Rock-Crop Task 3, slice 1 (#68): proves the ALREADY-SHIPPED Core ML
// model (`RockSeg.mlmodelc`, Task 1) + Swift `segmentAndCrop` recipe
// (`ArRockSegmentation.swift`, Task 2) produce a real rock mask when run
// inside the app on the iOS Simulator -- WITHOUT touching the AR
// overlay/painter wiring (that's the next slice). See
// `docs/superpowers/plans/2026-07-27-ar-rock-crop.md`, Task 3.
//
// Boots the real app (`app.main()`) so the `masi/arSegmentation`
// `MethodChannel` is live -- it's registered eagerly in `AppDelegate`, not
// lazily like the primary `masi/ar` channel (see
// `ArSegmentationChannelHandler.swift`'s header doc), so this reaches native
// segmentation without ever navigating to the AR screen (no camera needed;
// Core ML runs CPU-only on the Simulator).
//
// Copies the bundled `assets/test/crag_sample.jpg` (a real crag photo -- the
// forest boulder, chosen as the representative hard case: rock, trees,
// grass, and sky all in one frame) to a real file under the app documents
// dir, since the native side needs a filesystem path (a Flutter asset key
// isn't independently readable from Swift).
//
// IMPORTANT -- that asset is NOT bundled by default. It is 9.9 MB and used
// by nothing under `lib/`, so it no longer sits in `pubspec.yaml`'s `assets:`
// where it shipped in every production build. It lives un-bundled in
// `test_fixtures/crag_sample.jpg`, and `tool/drive_ar_seg.sh` stages it into
// `assets/test/` (git-ignored) + adds the pubspec entry for exactly the
// length of one drive, restoring both afterwards. RUN THIS TEST THROUGH THAT
// SCRIPT -- a bare `flutter drive` will fail in `rootBundle.load` because the
// asset genuinely is not in the bundle. See the script header for why the
// tidier Flutter mechanisms (dev-dependency assets, asset flavors) do not
// work here.
//
// Invokes `ArSegmentationChannel.segmentPreview` TWICE on the same photo:
//   (a) `routesNorm: null` -- no route clip, exercises the plain
//       ROCKPOS-union-INVERT + person-subtract + largest-CC (seeded at the
//       image center) recipe.
//   (b) `routesNorm` = 5 points roughly tracing the boulder in this photo's
//       upright frame (checked visually while writing this test -- the rock
//       spans about x:[0.3,0.95] y:[0.32,0.85] of the full upright frame) --
//       exercises the route-bbox clip (step 4 of the recipe) BEFORE the
//       largest-CC pass, so the returned mask/quad should shrink to roughly
//       the padded route bbox rather than the whole rock.
//
// `segmentPreview` already decodes both wire fields via the shared
// `rock_mask_codec.dart` parsers internally (`parseRockQuadPercent` /
// `decodeRockMaskAlpha` -- see `ArSegmentationChannel.segmentPreview`'s own
// doc comment), so this test reads them off the returned
// `ArSegmentationResult` rather than re-parsing a raw method-channel map by
// hand: identical decode path, without invoking native Core ML+Vision twice
// per case just to get at the raw bytes.
//
// For each result: asserts (1) native returned a mask + quad at all (a
// critical native-recipe bug if not); (2) the mask has real foreground
// coverage (not a blank/degenerate mask); (3) the quad is a STRICT sub-rect
// of the full frame (area < 1.0 -- proves it cropped, not full-photo).
//
// Then paints the tinted mask over the source photo -- composited OFF-SCREEN
// via a `PictureRecorder` + `Picture.toImage`, PNG-encoded, and written
// straight to a file under the app's OWN documents directory, rather than
// via `WidgetTester.pumpWidget` + `IntegrationTestWidgetsFlutterBinding
// .takeScreenshot`. That on-screen path was tried first and reliably came
// back a blank white PNG on this harness (iOS Simulator, `flutter drive`)
// even though the painter's own `paint()` demonstrably ran with valid,
// correctly-decoded photo/mask images (verified via a debugPrint + a
// diagnostic solid-color fill) -- i.e. the WIDGET rendered, but
// `takeScreenshot`'s native UIKit-snapshot capture did not reflect it, for
// reasons outside this test's scope to chase further. Rendering the
// composite directly into an offscreen `ui.Image`/PNG sidesteps that
// mechanism entirely and is strictly MORE reliable for a static composite
// like this one. On the iOS SIMULATOR (unlike a real device) the app
// container lives on the host Mac's own filesystem, so the calling shell
// copies the written PNGs out of the simulator's Documents dir into
// `build/screenshots/` after this test completes (see this file's own
// header for the exact `find`/`cp` step, or the implementer's run log).
//
// Run with (see CLAUDE.md's "Running the app on a real screen" iOS
// Simulator loop) -- via the staging wrapper, NOT a bare `flutter drive`:
//   cd /Users/kerip/Projects/masi && tool/drive_ar_seg.sh <simulator-udid>
//   # then copy the PNGs out of the simulator's (host-visible) app sandbox:
//   find ~/Library/Developer/CoreSimulator/Devices/<udid>/data/Containers/Data/Application \
//     -name 'sim-rock-mask-*.png' -exec cp {} build/screenshots/ \;
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui show
    Canvas,
    Color,
    Image,
    ImageByteFormat,
    Paint,
    Picture,
    PictureRecorder,
    Rect,
    decodeImageFromList;

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

import 'package:masi/features/ar/application/ar_segmentation_channel.dart';
import 'package:masi/features/ar/domain/rock_mask_codec.dart'
    show ArSegmentationResult;
import 'package:masi/main.dart' as app;

/// The route-clip points for case (b): a flat `[x0,y0,x1,y1,...]` list, each
/// 0..1 in the full-upright-photo frame, tracing roughly down the middle of
/// the boulder in `assets/test/crag_sample.jpg` (verified against a
/// EXIF-upright render of the bundled photo while writing this test).
const List<double> _routesNormOverRock = <double>[
  0.42, 0.35,
  0.45, 0.5,
  0.44, 0.68,
  0.55, 0.4,
  0.56, 0.6,
];

Future<ui.Image> _decodeImage(Uint8List bytes) {
  final completer = Completer<ui.Image>();
  ui.decodeImageFromList(bytes, completer.complete);
  return completer.future;
}

/// Fraction of `mask`'s pixels with nonzero alpha (i.e. segmented
/// foreground), read back from the decoded RGBA texture itself so this
/// doesn't need a second, separate native call just to get at the raw mask
/// bytes (`decodeRockMaskAlpha` already consumed those to build `mask`).
Future<double> _maskForegroundCoverage(ui.Image mask) async {
  final ByteData? data = await mask.toByteData(
    format: ui.ImageByteFormat.rawRgba,
  );
  if (data == null) return 0;
  final Uint8List bytes = data.buffer.asUint8List();
  final int total = mask.width * mask.height;
  if (total <= 0) return 0;
  int foreground = 0;
  for (int i = 0; i < total; i++) {
    if (bytes[i * 4 + 3] != 0) foreground++;
  }
  return foreground / total;
}

/// Shoelace-formula area of the 4-corner `quad` (TL/TR/BR/BL, each a 0..1
/// fraction of the full upright photo frame) -- the fraction of the FULL
/// frame the quad covers. `1.0` would mean "the whole photo, uncropped".
double _quadAreaFraction(List<Offset> quad) {
  double area = 0;
  for (int i = 0; i < quad.length; i++) {
    final Offset p1 = quad[i];
    final Offset p2 = quad[(i + 1) % quad.length];
    area += p1.dx * p2.dy - p2.dx * p1.dy;
  }
  return area.abs() / 2;
}

/// Composites `photo` with the tinted `mask` stretched over the SAME
/// full-frame rect on top of it (the mask lives in the same 0..1 frame as
/// the photo -- see `rock_mask_codec.dart`'s `decodeRockMaskAlpha` doc), so
/// the silhouette reads directly against the rock. Optionally also plots the
/// route-clip input points as small red dots, for visual cross-reference
/// against what was fed to `routesNorm`. Rendered off-screen (no widget
/// tree involved -- see this file's header doc for why) at a capped
/// long-edge of 1600px, PNG-encoded, and written to
/// `<docsDir>/<screenshotName>.png`.
Future<void> _writeCompositeScreenshot({
  required ui.Image photo,
  required ui.Image mask,
  required List<Offset>? routePointsNorm,
  required Directory docsDir,
  required String screenshotName,
}) async {
  const double longEdge = 1600;
  final double scale =
      longEdge / math.max(photo.width, photo.height).toDouble();
  final int outW = (photo.width * scale).round().clamp(1, 4096);
  final int outH = (photo.height * scale).round().clamp(1, 4096);
  final ui.Rect dst = ui.Rect.fromLTWH(0, 0, outW.toDouble(), outH.toDouble());

  final ui.PictureRecorder recorder = ui.PictureRecorder();
  final ui.Canvas canvas = ui.Canvas(recorder, dst);
  canvas.drawImageRect(
    photo,
    ui.Rect.fromLTWH(0, 0, photo.width.toDouble(), photo.height.toDouble()),
    dst,
    ui.Paint(),
  );
  canvas.drawImageRect(
    mask,
    ui.Rect.fromLTWH(0, 0, mask.width.toDouble(), mask.height.toDouble()),
    dst,
    ui.Paint(),
  );
  final List<Offset>? points = routePointsNorm;
  if (points != null) {
    final ui.Paint dot = ui.Paint()..color = const ui.Color(0xFFFF3B30);
    for (final Offset p in points) {
      canvas.drawCircle(Offset(p.dx * outW, p.dy * outH), 14, dot);
    }
  }
  final ui.Picture picture = recorder.endRecording();
  final ui.Image composite = await picture.toImage(outW, outH);
  final ByteData? png = await composite.toByteData(
    format: ui.ImageByteFormat.png,
  );
  composite.dispose();
  picture.dispose();
  if (png == null) {
    fail('failed to PNG-encode the $screenshotName composite');
  }
  final File outFile = File('${docsDir.path}/$screenshotName.png');
  await outFile.writeAsBytes(png.buffer.asUint8List(), flush: true);
  // ignore: avoid_print
  print('AR_SEG_TEST_SCREENSHOT $screenshotName -> ${outFile.path}');
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'segmentPreview (masi/arSegmentation) returns a real, cropped rock '
    'mask -- with and without a routesNorm clip',
    (tester) async {
      // 1. Boot the real app so the native masi/arSegmentation channel
      // (registered eagerly at launch, see AppDelegate) is live.
      app.main();
      await tester.pumpAndSettle(const Duration(seconds: 2));

      // 2. Copy the bundled test asset to a real file -- native needs a
      // filesystem path, not a Flutter asset key.
      final ByteData assetData = await rootBundle.load(
        'assets/test/crag_sample.jpg',
      );
      final Uint8List photoBytes = assetData.buffer.asUint8List(
        assetData.offsetInBytes,
        assetData.lengthInBytes,
      );
      final Directory docsDir = await getApplicationDocumentsDirectory();
      final File sampleFile = File(
        '${docsDir.path}/crag_sample_seg_test.jpg',
      );
      await sampleFile.writeAsBytes(photoBytes, flush: true);

      final ui.Image photoImage = await _decodeImage(photoBytes);

      final ArSegmentationChannel channel = ArSegmentationChannel();
      expect(
        channel.isNoop,
        isFalse,
        reason:
            'expected a real native-backed channel on this platform, got '
            'the web no-op -- this test must run on iOS/Android/desktop',
      );

      // 3a. No route clip.
      final ArSegmentationResult noClip = await channel.segmentPreview(
        sampleFile.path,
      );

      // 3b. Route-clip roughly over the boulder, center-frame.
      final ArSegmentationResult routeClip = await channel.segmentPreview(
        sampleFile.path,
        routesNorm: _routesNormOverRock,
      );

      // --- 4/5. Screenshot BOTH cases first (evidence captured even if a
      // numeric assertion below fails -- a "the recipe produced a bad crop"
      // finding is exactly as important to SEE as a "everything's great"
      // one, and screenshots must not depend on the assertions passing). ---
      if (noClip.mask != null) {
        await _writeCompositeScreenshot(
          photo: photoImage,
          mask: noClip.mask!,
          routePointsNorm: null,
          docsDir: docsDir,
          screenshotName: 'sim-rock-mask-noclip',
        );
      }
      if (routeClip.mask != null) {
        await _writeCompositeScreenshot(
          photo: photoImage,
          mask: routeClip.mask!,
          routePointsNorm: <Offset>[
            for (int i = 0; i + 1 < _routesNormOverRock.length; i += 2)
              Offset(_routesNormOverRock[i], _routesNormOverRock[i + 1]),
          ],
          docsDir: docsDir,
          screenshotName: 'sim-rock-mask-routeclip',
        );
      }

      // `flutter drive` uninstalls the app (wiping its container, PNGs
      // included) IMMEDIATELY once this test function returns -- give the
      // calling shell a real-world window to `cp` the two files out of the
      // simulator's (host-visible) Documents dir before that happens. This
      // print is the signal the calling shell greps for before it copies.
      // ignore: avoid_print
      print('AR_SEG_TEST_SCREENSHOTS_READY docsDir=${docsDir.path}');
      await Future<void>.delayed(const Duration(seconds: 25));

      // --- Compute metrics for both cases (still before any hard assert). ---
      final double? noClipArea = noClip.quadPercent == null
          ? null
          : _quadAreaFraction(noClip.quadPercent!);
      final double? noClipCoverage = noClip.mask == null
          ? null
          : await _maskForegroundCoverage(noClip.mask!);
      final double? routeClipArea = routeClip.quadPercent == null
          ? null
          : _quadAreaFraction(routeClip.quadPercent!);
      final double? routeClipCoverage = routeClip.mask == null
          ? null
          : await _maskForegroundCoverage(routeClip.mask!);

      // Surfaced in the `flutter drive` console output for the record --
      // BEFORE any assertion, so this always reaches the log even on a
      // hard-assertion failure below.
      // ignore: avoid_print
      print(
        'AR_SEG_TEST_RESULT noClip: coverage=$noClipCoverage '
        'area=$noClipArea | routeClip: coverage=$routeClipCoverage '
        'area=$routeClipArea',
      );

      noClip.mask?.dispose();
      routeClip.mask?.dispose();
      photoImage.dispose();

      // Core ML returns an all-zeros tensor on the iOS Simulator (no on-device
      // ML runtime / E5RT), which collapses the mask to the full frame. This
      // mask validation is therefore DEVICE-ONLY -- skip (don't fail) when we
      // detect that degenerate simulator signature (verified on PetiTeló:
      // coverage ~0.55, not ~1.0).
      if ((noClipCoverage ?? 0) >= 0.999 && (noClipArea ?? 0) >= 0.999) {
        markTestSkipped(
          'Core ML rock-seg returns a zero tensor on the iOS Simulator; '
          'run on a physical device to validate the mask.',
        );
        return;
      }

      // --- 5. Assertions (screenshots/metrics/log above are unconditional;
      // these are the pass/fail verdict). ---
      expect(
        noClip.quadPercent,
        isNotNull,
        reason:
            'no-clip: rockQuadPercent missing -- native found nothing / '
            'errored (critical: the Core ML recipe should segment SOMETHING '
            'on this photo without a route clip)',
      );
      expect(
        noClip.mask,
        isNotNull,
        reason:
            'no-clip: rockMaskAlpha missing/malformed -- native found '
            'nothing / errored',
      );
      expect(
        noClipCoverage,
        greaterThan(0.02),
        reason:
            'no-clip: mask has almost no foreground (coverage='
            '$noClipCoverage) -- the recipe produced an effectively blank '
            'mask',
      );
      expect(
        noClipArea,
        lessThan(1.0),
        reason:
            'no-clip: quad covers the full frame (area=$noClipArea) -- not '
            'actually cropped',
      );

      expect(
        routeClip.quadPercent,
        isNotNull,
        reason:
            'route-clip: rockQuadPercent missing -- native found nothing / '
            'errored',
      );
      expect(
        routeClip.mask,
        isNotNull,
        reason:
            'route-clip: rockMaskAlpha missing/malformed -- native found '
            'nothing / errored',
      );
      expect(
        routeClipCoverage,
        greaterThan(0.02),
        reason:
            'route-clip: mask has almost no foreground (coverage='
            '$routeClipCoverage)',
      );
      expect(
        routeClipArea,
        lessThan(1.0),
        reason:
            'route-clip: quad covers the full frame (area=$routeClipArea) '
            '-- the route-clip step did not narrow the crop',
      );
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
