import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../../app/theme.dart';
import '../../topo/presentation/photo_source_sheet.dart' show showCameraOption;

/// How long a capture may run.
///
/// 45 seconds is a compromise between two hard limits pulling opposite ways.
/// Reconstruction wants a slow, complete pass across the face, which takes
/// time; the upload wants the file small, and a phone shooting 1080p30 writes
/// roughly 60-90 MB per minute. Past about a minute the video stops being
/// something a climber will wait to upload on a crag connection — and a video
/// that never uploads reconstructs exactly as well as one never taken.
const Duration kScanMaxDuration = Duration(seconds: 45);

/// Picks a scan video. The one seam tests inject over, mirroring
/// `pickPhotoFrom` — callers never touch `image_picker` directly.
///
/// `maxDuration` is a request, not a guarantee: on iOS it configures the
/// camera UI, and a video chosen from the library is whatever length it is.
/// Nothing downstream may assume the result is under [kScanMaxDuration].
Future<XFile?> pickScanVideoFrom(ImageSource source) =>
    ImagePicker().pickVideo(source: source, maxDuration: kScanMaxDuration);

/// Shows what a usable capture looks like, then asks where the video comes
/// from. Returns `null` if the climber backs out.
///
/// The guidance is not decoration. Every failure mode of the reconstruction
/// that a person can actually control is on this sheet, in the order they
/// will hit them — and phrased as what to DO, because "insufficient parallax"
/// is not an instruction. The alternative is a worker that fails a scan
/// twenty minutes later for a reason the climber has already walked away
/// from.
Future<ImageSource?> showScanCaptureSheet(BuildContext context) {
  return showModalBottomSheet<ImageSource>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (sheetContext) => const _ScanCaptureSheet(),
  );
}

class _ScanCaptureSheet extends ConsumerWidget {
  const _ScanCaptureSheet();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = MasiColors.of(context);
    final media = MediaQuery.of(context);

    return Container(
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(MasiSpacing.lg),
        ),
      ),
      padding: EdgeInsets.fromLTRB(
        MasiSpacing.xl,
        MasiSpacing.lg,
        MasiSpacing.xl,
        // Same floor as every other sheet here: an installed iOS PWA reports
        // zero bottom padding, so trusting MediaQuery alone puts the last
        // button under the home indicator.
        MasiSpacing.xl + (media.padding.bottom > 0 ? media.padding.bottom : 12),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: colors.separator,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: MasiSpacing.lg),
          Text(
            'Capture this wall in 3D',
            style: TextStyle(
              color: colors.ink,
              fontSize: 20,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: MasiSpacing.xs),
          Text(
            'Record one slow pass across the rock. We build a 3D model from '
            'it — your topo and route lines are untouched either way.',
            style: TextStyle(color: colors.ink2, fontSize: 14, height: 1.4),
          ),
          const SizedBox(height: MasiSpacing.lg),
          ..._tips.map((tip) => _TipRow(tip: tip, colors: colors)),
          const SizedBox(height: MasiSpacing.lg),
          if (showCameraOption())
            _SheetButton(
              key: const Key('scan-source-camera'),
              label: 'Record a pass',
              filled: true,
              colors: colors,
              onPressed: () =>
                  Navigator.pop(context, ImageSource.camera),
            ),
          if (showCameraOption()) const SizedBox(height: MasiSpacing.sm),
          _SheetButton(
            key: const Key('scan-source-gallery'),
            label: 'Choose a video',
            filled: false,
            colors: colors,
            onPressed: () => Navigator.pop(context, ImageSource.gallery),
          ),
        ],
      ),
    );
  }

  static const List<String> _tips = [
    'Walk slowly from one end of the face to the other.',
    'Keep the whole face in frame, and keep moving — standing still and '
        'turning gives us nothing to work with.',
    'About 30–45 seconds. Longer is not better.',
    'Even light helps. Hard shade and blown-out sun both hide the rock.',
  ];
}

class _TipRow extends StatelessWidget {
  const _TipRow({required this.tip, required this.colors});

  final String tip;
  final MasiColors colors;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: MasiSpacing.sm),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          margin: const EdgeInsets.only(top: 7, right: MasiSpacing.md),
          width: 5,
          height: 5,
          decoration: BoxDecoration(
            color: colors.accent,
            shape: BoxShape.circle,
          ),
        ),
        Expanded(
          child: Text(
            tip,
            style: TextStyle(color: colors.ink2, fontSize: 14, height: 1.35),
          ),
        ),
      ],
    ),
  );
}

class _SheetButton extends StatelessWidget {
  const _SheetButton({
    required this.label,
    required this.filled,
    required this.colors,
    required this.onPressed,
    super.key,
  });

  final String label;
  final bool filled;
  final MasiColors colors;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: double.infinity,
    height: 48,
    child: Material(
      color: filled ? colors.accent : colors.surface2,
      borderRadius: BorderRadius.circular(MasiSpacing.md),
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(MasiSpacing.md),
        child: Center(
          child: Text(
            label,
            style: TextStyle(
              color: filled ? colors.onAccent : colors.ink,
              fontSize: 16,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
    ),
  );
}
