import 'package:flutter/material.dart';

import 'package:masi/app/theme.dart';
import 'package:masi/features/topo/presentation/photo_image.dart';
import 'package:masi/features/topo/presentation/photo_loading_fill.dart';

/// A quick look at one photo, big, over whatever raised it.
///
/// The plan and the editor draw a rock's faces at 64x48. That is enough to
/// say "there is a back and a left side" and nowhere near enough to answer
/// "is this the slab with the crack in it" — and the only way to check used
/// to be to leave the screen, open the face, and come back, which loses the
/// arrangement you were in the middle of reading.
///
/// So: long-press any face and it opens here. Deliberately not a route —
/// nothing is navigated, nothing is edited, and one tap anywhere puts it
/// back. It is a look, not a place.
Future<void> showPhotoPreview(
  BuildContext context, {
  required String storedPath,
  required String title,
  String? subtitle,
}) => showDialog<void>(
  context: context,
  barrierColor: const Color(0xCC000000),
  builder: (context) => _PhotoPreviewDialog(
    storedPath: storedPath,
    title: title,
    subtitle: subtitle,
  ),
);

class _PhotoPreviewDialog extends StatelessWidget {
  const _PhotoPreviewDialog({
    required this.storedPath,
    required this.title,
    this.subtitle,
  });

  final String storedPath;
  final String title;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    final colors = MasiColors.of(context);
    final media = MediaQuery.sizeOf(context);

    return GestureDetector(
      // The whole barrier closes it, not a button in a corner: the gesture
      // that opened this was a long-press on a picture, and the way back has
      // to be at least as cheap as the way in.
      key: const Key('photo-preview'),
      behavior: HitTestBehavior.opaque,
      onTap: () => Navigator.of(context).maybePop(),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: media.width - 40,
                maxHeight: media.height * 0.72,
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(MasiRadii.card),
                // The ORIGINAL, not the thumbnail. This exists to be looked
                // at closely; a 96px tile blown up to the screen answers
                // nothing. One photo at a time, raised by a deliberate
                // gesture, is the case a full-resolution decode is for.
                child: PhotoImage(
                  storedPath,
                  key: const Key('photo-preview-image'),
                  fit: BoxFit.contain,
                  loadingPlaceholder: () => const PhotoLoadingFill(
                    width: 220,
                    height: 160,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 14),
            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w600,
                // White on the scrim regardless of theme — this text rides a
                // dark barrier in both.
                color: Color(0xFFFFFFFF),
              ),
            ),
            if (subtitle case final line?) ...[
              const SizedBox(height: 3),
              Text(
                line,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 13,
                  color: const Color(0xFFFFFFFF).withValues(alpha: 0.72),
                ),
              ),
            ],
            const SizedBox(height: 10),
            Text(
              'Tap anywhere to close',
              style: TextStyle(
                fontSize: 12,
                color: colors.ink3.withValues(alpha: 0.9),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
