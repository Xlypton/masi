import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../../app/theme.dart';
import '../../../shared/presentation/bottom_safe_inset.dart';

/// Whether [showPhotoSourceSheet] should offer the "Take photo" (camera)
/// option, or only "Choose from library".
///
/// Native (`!kIsWeb`): always `true` — unchanged behavior, camera always
/// shown.
///
/// Web: `image_picker`'s [ImageSource.camera] is backed by an HTML
/// `<input capture>` element. On MOBILE browsers that actually opens the
/// device camera capture UI, so it's kept there. On DESKTOP browsers
/// `capture` is ignored and it silently degrades to the exact same
/// file-open dialog [ImageSource.gallery] already offers — a dead,
/// confusing duplicate option — so it's hidden there.
///
/// Gated on [defaultTargetPlatform] rather than a screen-size/breakpoint
/// check: Flutter web still sniffs the user agent to populate
/// [defaultTargetPlatform] with the underlying OS (iOS/Android vs.
/// macOS/Windows/Linux/Fuchsia), which tracks actual device form factor —
/// unlike viewport width, which a resizable desktop browser window can put
/// into "mobile" range without there being a camera to capture from.
///
/// [isWeb]/[platform] default to the real [kIsWeb]/[defaultTargetPlatform]
/// and only exist so a unit test can exercise the web branches (mobile web
/// vs. desktop web) without a real browser test runner, where the compile-
/// time [kIsWeb] can't otherwise be flipped.
bool showCameraOption({bool? isWeb, TargetPlatform? platform}) {
  if (!(isWeb ?? kIsWeb)) return true;
  final targetPlatform = platform ?? defaultTargetPlatform;
  return targetPlatform == TargetPlatform.iOS ||
      targetPlatform == TargetPlatform.android;
}

/// Presents a Cupertino action sheet letting the user choose where a new
/// wall photo comes from: the camera, the photo library, or cancel.
///
/// Returns [ImageSource.camera] / [ImageSource.gallery] when the user picks
/// one, or `null` if they cancel (either via the cancel button or by
/// dismissing the sheet, e.g. tapping outside it).
///
/// The camera option is hidden on desktop web — see [showCameraOption].
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
    // Same fix and the same reasoning as `showMasiActionSheet` (used by
    // every other action sheet in the app): `CupertinoActionSheet`'s own
    // `SafeArea(minimum: bottom 8)` reads the ambient `MediaQuery.padding`,
    // which is zero in an installed iOS PWA, so this sheet lands only 8px
    // above the home indicator. Override the ambient bottom padding to our
    // floor so that built-in `SafeArea` maxes against it instead.
    // `showCupertinoModalPopup` uses `useRootNavigator: true`, so this route
    // is always outside `NavShell` — the floor applies uniformly.
    builder: (sheetContext) => Consumer(
      builder: (consumerContext, ref, _) {
        final media = MediaQuery.of(consumerContext);
        return MediaQuery(
          data: media.copyWith(
            padding: media.padding.copyWith(
              bottom: masiBottomInset(consumerContext, ref),
            ),
          ),
          child: CupertinoActionSheet(
            title: const Text('Add a photo'),
            actions: [
              if (showCameraOption())
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
      },
    ),
  );
}

/// Thin wrapper around [ImagePicker.pickImage] so callers (and tests) have
/// a single seam to inject/mock, without depending on `image_picker`
/// directly.
///
/// `requestFullMetadata: true` is passed explicitly (it already defaults to
/// `true` in `image_picker` ^1.2.2, so this is a no-op today, but pins the
/// behavior against a future default change) — on iOS, WITHOUT it the
/// plugin strips the picked file's EXIF metadata, including the GPS tags
/// `core/location/photo_gps.dart`'s `extractGpsFromImageBytes` reads to
/// auto-populate a wall's coordinates.
Future<XFile?> pickPhotoFrom(ImageSource source) =>
    ImagePicker().pickImage(source: source, requestFullMetadata: true);
