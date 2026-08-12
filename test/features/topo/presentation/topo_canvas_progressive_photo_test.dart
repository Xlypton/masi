// The topo canvas paints the photo's 512px thumbnail underneath the
// full-resolution original, so the wall appears at once instead of after the
// original's whole download + decode (user report, 2026-08-11: "images still
// load very slowly, either display a shimmer there or make it faster").
//
// The size gap is what makes this worth doing: in the reporter's own library
// the originals run 3.4-9.3 MB while their thumbnails are 52-65 KB, and on
// web every one of those megabytes is an IndexedDB read, a blob URL and a
// full-resolution decode before a single pixel lands.
//
// Three properties, all of which a naive "just add another image" would get
// wrong:
//   * the thumbnail resolves to the SAME photo's `thumbs/<id>.jpg` key;
//   * it is UNDER the original, so the original covers it once decoded;
//   * the original's loading placeholder is transparent — a skeleton there
//     would paint straight over the thumbnail and undo the whole point —
//     while the thumbnail keeps the full-size skeleton, so a photo with no
//     thumbnail at all still shows "coming" rather than a blank canvas.

import 'package:masi/app/theme.dart';
import 'package:masi/features/topo/data/photo_path_resolution.dart';
import 'package:masi/features/topo/presentation/photo_image.dart';
import 'package:masi/features/topo/presentation/photo_loading_fill.dart';
import 'package:masi/features/topo/presentation/topo_canvas.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _wallId = 'test-wall';
const _imageSize = Size(4000, 3000);
const _imagePath = 'photos/a887846d-2fbf-4f6d-a955-fc107e0ba041.jpg';

const _originalKey = Key('topo-canvas-photo');
const _thumbKey = Key('topo-canvas-photo-thumb');

Future<void> _pumpCanvas(WidgetTester tester) async {
  final controller = TransformationController();
  addTearDown(controller.dispose);
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        theme: MasiTheme.light,
        home: Scaffold(
          body: TopoCanvas(
            wallId: _wallId,
            imagePath: _imagePath,
            imageSize: _imageSize,
            transformationController: controller,
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets(
    'the canvas renders the photo\'s own thumbnail as well as the original',
    (tester) async {
      await _pumpCanvas(tester);

      expect(find.byKey(_originalKey), findsOneWidget);
      expect(find.byKey(_thumbKey), findsOneWidget);

      expect(
        tester.widget<PhotoImage>(find.byKey(_originalKey)).storedPath,
        _imagePath,
      );
      expect(
        tester.widget<PhotoImage>(find.byKey(_thumbKey)).storedPath,
        thumbKeyFor(_imagePath),
        reason: 'the placeholder must be THIS photo\'s thumbnail — a '
            'different photo\'s would flash the wrong wall',
      );
    },
  );

  testWidgets(
    'the thumbnail is painted UNDER the original, so the original covers it '
    'the moment it has a frame rather than being hidden behind it',
    (tester) async {
      await _pumpCanvas(tester);

      final stack = tester.widget<Stack>(
        find
            .ancestor(
              of: find.byKey(_thumbKey),
              matching: find.byType(Stack),
            )
            .first,
      );
      final thumbIndex = stack.children.indexWhere((w) => w.key == _thumbKey);
      final originalIndex = stack.children.indexWhere(
        (w) => w.key == _originalKey,
      );

      expect(thumbIndex, isNonNegative);
      expect(originalIndex, isNonNegative);
      expect(
        thumbIndex,
        lessThan(originalIndex),
        reason: 'a Stack paints in order — the thumbnail must come first, or '
            'the blurry copy would sit on top of the real photo forever',
      );
    },
  );

  testWidgets(
    'both layers are laid out in the SAME box, so the swap cannot jump',
    (tester) async {
      await _pumpCanvas(tester);

      final original = tester.widget<PhotoImage>(find.byKey(_originalKey));
      final thumb = tester.widget<PhotoImage>(find.byKey(_thumbKey));

      expect(thumb.width, original.width);
      expect(thumb.height, original.height);
      expect(thumb.fit, original.fit);
    },
  );

  testWidgets(
    'the original\'s loading placeholder is TRANSPARENT — a skeleton there '
    'would paint over the thumbnail and defeat the progressive load — while '
    'the thumbnail keeps the full-size skeleton for the no-thumbnail case',
    (tester) async {
      await _pumpCanvas(tester);

      final original = tester.widget<PhotoImage>(find.byKey(_originalKey));
      final thumb = tester.widget<PhotoImage>(find.byKey(_thumbKey));

      expect(original.loadingPlaceholder, isNotNull);
      expect(
        original.loadingPlaceholder!(),
        isA<SizedBox>(),
        reason: 'anything that paints here hides the thumbnail underneath',
      );

      expect(thumb.loadingPlaceholder, isNotNull);
      final thumbPlaceholder = thumb.loadingPlaceholder!();
      expect(
        thumbPlaceholder,
        isA<PhotoLoadingFill>(),
        reason: 'a photo with no thumbnail must still say "coming" rather '
            'than leaving the canvas blank — this is where that lives now',
      );
      expect((thumbPlaceholder as PhotoLoadingFill).width, _imageSize.width);
      expect(thumbPlaceholder.height, _imageSize.height);
    },
  );

  testWidgets(
    'the full-resolution layer still passes NO cacheWidth/cacheHeight — the '
    'canvas pinch-zooms past 1:1 to place a line on a single hold, and a '
    'sized decode would show the decoder\'s blur instead',
    (tester) async {
      await _pumpCanvas(tester);

      final original = tester.widget<PhotoImage>(find.byKey(_originalKey));
      expect(original.cacheWidth, isNull);
      expect(original.cacheHeight, isNull);
    },
  );
}
