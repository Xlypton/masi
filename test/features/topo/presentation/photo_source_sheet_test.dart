import 'package:climbtopo/app/theme.dart';
import 'package:climbtopo/features/topo/presentation/photo_source_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';

/// Harness: a single button whose `onPressed` calls [showPhotoSourceSheet]
/// and stashes the returned future so the test can await its resolution
/// after driving the sheet's actions.
class _Harness extends StatefulWidget {
  const _Harness({required this.onFuture});

  final void Function(Future<ImageSource?> future) onFuture;

  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
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
}
