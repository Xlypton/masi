import 'package:flutter/cupertino.dart';
import 'package:image_picker/image_picker.dart';

import '../../../app/theme.dart';

/// Presents a Cupertino action sheet letting the user choose where a new
/// wall photo comes from: the camera, the photo library, or cancel.
///
/// Returns [ImageSource.camera] / [ImageSource.gallery] when the user picks
/// one, or `null` if they cancel (either via the cancel button or by
/// dismissing the sheet, e.g. tapping outside it).
///
/// Standalone and reusable: this widget is not wired into any screen by
/// itself — callers own the resulting [ImageSource] and what to do with it
/// (typically passing it straight into [pickPhotoFrom]).
Future<ImageSource?> showPhotoSourceSheet(BuildContext context) {
  final colors = MasiColors.of(context);
  final actionTextStyle = TextStyle(color: colors.accent);
  final cancelTextStyle = TextStyle(color: colors.ink2);

  return showCupertinoModalPopup<ImageSource>(
    context: context,
    builder: (sheetContext) => CupertinoActionSheet(
      title: const Text('Add a photo'),
      actions: [
        CupertinoActionSheetAction(
          key: const Key('photo-source-camera'),
          onPressed: () =>
              Navigator.pop(sheetContext, ImageSource.camera),
          child: Text('Take photo', style: actionTextStyle),
        ),
        CupertinoActionSheetAction(
          key: const Key('photo-source-library'),
          onPressed: () =>
              Navigator.pop(sheetContext, ImageSource.gallery),
          child: Text('Choose from library', style: actionTextStyle),
        ),
      ],
      cancelButton: CupertinoActionSheetAction(
        key: const Key('photo-source-cancel'),
        onPressed: () => Navigator.pop(sheetContext, null),
        child: Text('Cancel', style: cancelTextStyle),
      ),
    ),
  );
}

/// Thin wrapper around [ImagePicker.pickImage] so callers (and tests) have
/// a single seam to inject/mock, without depending on `image_picker`
/// directly.
Future<XFile?> pickPhotoFrom(ImageSource source) =>
    ImagePicker().pickImage(source: source);
