import 'package:masi/app/theme.dart';
import 'package:masi/features/topo/presentation/photo_source_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';

/// Harness: a single button whose `onPressed` calls [showPhotoSourceSheet]
/// and stashes the returned future so the test can await its resolution
/// after driving the sheet's actions.
///
/// `ProviderScope`-wrapped: the sheet reads `pwaInstallStatusProvider` (the
/// standalone-PWA bottom-inset floor) — unoverridden here, which resolves
/// to `isStandalone: false` on the native/test backend, i.e. no behavior
/// change for this suite.
class _Harness extends StatefulWidget {
  const _Harness({required this.onFuture});

  final void Function(Future<ImageSource?> future) onFuture;

  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> {
  @override
  Widget build(BuildContext context) {
    return ProviderScope(
      child: MaterialApp(
        theme: MasiTheme.light,
        home: Scaffold(
          body: Center(
            child: Builder(
              builder: (buttonContext) => ElevatedButton(
                key: const Key('open-photo-source-sheet'),
                onPressed: () {
                  widget.onFuture(showPhotoSourceSheet(buttonContext));
                },
                child: const Text('Add a photo'),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

void main() {
  testWidgets(
    'A1: tapping photo-source-camera resolves to ImageSource.camera',
    (tester) async {
      Future<ImageSource?>? result;
      await tester.pumpWidget(_Harness(onFuture: (future) => result = future));

      await tester.tap(find.byKey(const Key('open-photo-source-sheet')));
      await tester.pumpAndSettle();

      expect(find.text('Add a photo'), findsWidgets);

      await tester.tap(find.byKey(const Key('photo-source-camera')));
      await tester.pumpAndSettle();

      expect(result, isNotNull);
      expect(await result, ImageSource.camera);
    },
  );

  testWidgets(
    'A2: tapping photo-source-library resolves to ImageSource.gallery',
    (tester) async {
      Future<ImageSource?>? result;
      await tester.pumpWidget(_Harness(onFuture: (future) => result = future));

      await tester.tap(find.byKey(const Key('open-photo-source-sheet')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('photo-source-library')));
      await tester.pumpAndSettle();

      expect(result, isNotNull);
      expect(await result, ImageSource.gallery);
    },
  );

  testWidgets(
    'A3: tapping photo-source-cancel resolves to null',
    (tester) async {
      Future<ImageSource?>? result;
      await tester.pumpWidget(_Harness(onFuture: (future) => result = future));

      await tester.tap(find.byKey(const Key('open-photo-source-sheet')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('photo-source-cancel')));
      await tester.pumpAndSettle();

      expect(result, isNotNull);
      expect(await result, isNull);
    },
  );

  test(
    'A4: pickPhotoFrom has signature Future<XFile?> Function(ImageSource)',
    () {
      expect(pickPhotoFrom, isA<Future<XFile?> Function(ImageSource)>());
    },
  );

  group('A5: showCameraOption gates Camera on mobile-web vs. desktop-web', () {
    test('native (isWeb=false) always shows Camera, regardless of platform', () {
      expect(showCameraOption(isWeb: false, platform: TargetPlatform.iOS), isTrue);
      expect(showCameraOption(isWeb: false, platform: TargetPlatform.android), isTrue);
      expect(showCameraOption(isWeb: false, platform: TargetPlatform.macOS), isTrue);
      expect(showCameraOption(isWeb: false, platform: TargetPlatform.windows), isTrue);
    });

    test('mobile web (iOS/Android) shows Camera', () {
      expect(showCameraOption(isWeb: true, platform: TargetPlatform.iOS), isTrue);
      expect(showCameraOption(isWeb: true, platform: TargetPlatform.android), isTrue);
    });

    test('desktop web (macOS/Windows/Linux/Fuchsia) hides Camera', () {
      expect(showCameraOption(isWeb: true, platform: TargetPlatform.macOS), isFalse);
      expect(showCameraOption(isWeb: true, platform: TargetPlatform.windows), isFalse);
      expect(showCameraOption(isWeb: true, platform: TargetPlatform.linux), isFalse);
      expect(showCameraOption(isWeb: true, platform: TargetPlatform.fuchsia), isFalse);
    });

    test('defaults (no overrides) resolve from the real kIsWeb/defaultTargetPlatform '
        'and, on this native VM test runner, always show Camera', () {
      expect(showCameraOption(), isTrue);
    });
  });
}
