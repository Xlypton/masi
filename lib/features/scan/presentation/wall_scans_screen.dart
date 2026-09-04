import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';

import '../../../app/theme.dart';
import '../../../core/db/app_database.dart' as db;
import '../../library/application/library_providers.dart';
import '../application/rock_scan_providers.dart';
import '../domain/rock_scan_manifest.dart';
import '../domain/rock_scan_status.dart';
import 'scan_capture_sheet.dart';

/// Every 3D capture of one wall, and the way to make another.
///
/// A separate screen from the topo, not a panel inside it, for the same
/// reason the plan view is: a scan is a property of the ROCK, and the canvas
/// is about what is drawn on a photo of it. Keeping them apart is also what
/// lets the topo carry on working when there is no scan, when one is still
/// processing, and when one has failed — which are the three states it will
/// spend most of its life in.
class WallScansScreen extends ConsumerWidget {
  const WallScansScreen({
    required this.wallId,
    this.pickVideo = pickScanVideoFrom,
    super.key,
  });

  final String wallId;

  /// Video-picker seam. Defaults to the real picker; a test injects its own,
  /// because the OS picker is a native dialog outside Flutter that no widget
  /// test or `integration_test` can drive.
  final Future<XFile?> Function(ImageSource source) pickVideo;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = MasiColors.of(context);
    final scans = ref.watch(wallScansProvider(wallId)).value;
    final wallName = ref.watch(wallNameProvider(wallId)).value;
    final capture = ref.watch(rockScanCaptureProvider);

    return Scaffold(
      backgroundColor: colors.ground,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _Header(wallName: wallName, colors: colors),
            if (capture is RockScanCaptureFailed)
              _ErrorBanner(
                message: capture.message,
                colors: colors,
                onDismiss: () =>
                    ref.read(rockScanCaptureProvider.notifier).dismissError(),
              ),
            Expanded(
              child: switch (scans) {
                null => const Center(child: CircularProgressIndicator()),
                [] => _EmptyState(colors: colors),
                final rows => ListView.separated(
                  padding: const EdgeInsets.all(MasiSpacing.lg),
                  itemCount: rows.length,
                  separatorBuilder: (_, _) =>
                      const SizedBox(height: MasiSpacing.sm),
                  itemBuilder: (context, index) => _ScanTile(
                    key: Key('scan-tile-${rows[index].id}'),
                    scan: rows[index],
                    colors: colors,
                    onOpen: () => context.push(
                      '/walls/$wallId/scans/${rows[index].id}',
                    ),
                    onDelete: () => ref
                        .read(rockScanRepositoryProvider)
                        .deleteScan(rows[index].id),
                  ),
                ),
              },
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                MasiSpacing.lg,
                0,
                MasiSpacing.lg,
                MasiSpacing.lg,
              ),
              child: _CaptureButton(
                busy: capture is RockScanCaptureUploading,
                colors: colors,
                onPressed: () => _startCapture(context, ref),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _startCapture(BuildContext context, WidgetRef ref) async {
    final source = await showScanCaptureSheet(context);
    if (source == null) return;

    final picked = await pickVideo(source);
    if (picked == null) return;

    // Read the bytes here rather than inside the controller: `XFile` is the
    // picker's type, and keeping it out of the application layer is what lets
    // that layer be tested with a plain `Uint8List` and no plugin at all.
    final bytes = await picked.readAsBytes();

    await ref
        .read(rockScanCaptureProvider.notifier)
        .capture(wallId: wallId, bytes: bytes);
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.wallName, required this.colors});

  final String? wallName;
  final MasiColors colors;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(
      MasiSpacing.sm,
      MasiSpacing.sm,
      MasiSpacing.lg,
      MasiSpacing.sm,
    ),
    child: Row(
      children: [
        IconButton(
          key: const Key('scans-back'),
          icon: Icon(Icons.arrow_back_ios_new, color: colors.ink, size: 20),
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '3D scans',
                style: TextStyle(
                  color: colors.ink,
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                ),
              ),
              if (wallName != null)
                Text(
                  wallName!,
                  style: TextStyle(color: colors.ink3, fontSize: 13),
                  overflow: TextOverflow.ellipsis,
                ),
            ],
          ),
        ),
      ],
    ),
  );
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.colors});

  final MasiColors colors;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: MasiSpacing.xxl),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.view_in_ar_outlined, size: 44, color: colors.ink3),
          const SizedBox(height: MasiSpacing.md),
          Text(
            'No scans yet',
            style: TextStyle(
              color: colors.ink,
              fontSize: 17,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: MasiSpacing.xs),
          Text(
            'Record a slow pass across the rock and we will build a 3D model '
            'of it. Your topo works exactly the same either way.',
            textAlign: TextAlign.center,
            style: TextStyle(color: colors.ink2, fontSize: 14, height: 1.4),
          ),
        ],
      ),
    ),
  );
}

class _ScanTile extends StatelessWidget {
  const _ScanTile({
    required this.scan,
    required this.colors,
    required this.onOpen,
    required this.onDelete,
    super.key,
  });

  final db.RockScanRow scan;
  final MasiColors colors;
  final VoidCallback onOpen;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final phase = rockScanPhase(
      upload: RockScanUpload.fromWire(scan.uploadState),
      status: RockScanStatus.fromWire(scan.status),
    );
    final manifest = RockScanManifest.tryParse(scan.manifestJson);

    return Material(
      color: colors.surface,
      borderRadius: BorderRadius.circular(MasiSpacing.md),
      child: InkWell(
        // Only a finished scan opens. Tapping a processing one and landing on
        // an empty viewer teaches the user the viewer is broken.
        onTap: phase == RockScanPhase.ready ? onOpen : null,
        borderRadius: BorderRadius.circular(MasiSpacing.md),
        child: Padding(
          padding: const EdgeInsets.all(MasiSpacing.md),
          child: Row(
            children: [
              _PhaseDot(phase: phase, colors: colors),
              const SizedBox(width: MasiSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _phaseLabel(phase),
                      style: TextStyle(
                        color: colors.ink,
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _detail(phase, scan, manifest),
                      style: TextStyle(color: colors.ink3, fontSize: 13),
                    ),
                  ],
                ),
              ),
              if (phase == RockScanPhase.ready)
                Icon(Icons.chevron_right, color: colors.ink3, size: 20),
              IconButton(
                key: Key('scan-delete-${scan.id}'),
                icon: Icon(Icons.delete_outline, color: colors.ink3, size: 20),
                onPressed: onDelete,
              ),
            ],
          ),
        ),
      ),
    );
  }

  static String _phaseLabel(RockScanPhase phase) => switch (phase) {
    RockScanPhase.onDevice => 'On this device',
    RockScanPhase.uploading => 'Uploading',
    RockScanPhase.uploadFailed => 'Upload failed',
    RockScanPhase.reconstructing => 'Building the 3D model',
    RockScanPhase.ready => '3D model ready',
    RockScanPhase.reconstructionFailed => 'Could not build a model',
  };

  /// The second line. Says something true and specific in every phase —
  /// notably it NEVER invents a percentage or an ETA, because nothing here
  /// knows either and a wrong ETA is worse than none.
  static String _detail(
    RockScanPhase phase,
    db.RockScanRow scan,
    RockScanManifest? manifest,
  ) {
    switch (phase) {
      case RockScanPhase.onDevice:
        return 'Not uploaded yet';
      case RockScanPhase.uploading:
        return _sizeLabel(scan.sizeBytes);
      case RockScanPhase.uploadFailed:
        return 'Tap Capture to record another pass';
      case RockScanPhase.reconstructing:
        return 'This can take a while — you can leave this screen';
      case RockScanPhase.reconstructionFailed:
        // The worker writes this in sentences meant for a climber. If it is
        // missing, say nothing rather than surfacing an engine error.
        return scan.failureReason ?? 'No details';
      case RockScanPhase.ready:
        final points = manifest?.pointCount;
        if (points == null) return 'Tap to open';
        return '${_thousands(points)} points';
    }
  }

  static String _sizeLabel(int? bytes) {
    if (bytes == null) return 'Sending the video';
    final mb = bytes / (1024 * 1024);
    return '${mb.toStringAsFixed(mb >= 10 ? 0 : 1)} MB';
  }

  static String _thousands(int value) {
    final digits = value.toString();
    final buffer = StringBuffer();
    for (var i = 0; i < digits.length; i++) {
      if (i > 0 && (digits.length - i) % 3 == 0) buffer.write(' ');
      buffer.write(digits[i]);
    }
    return buffer.toString();
  }
}

class _PhaseDot extends StatelessWidget {
  const _PhaseDot({required this.phase, required this.colors});

  final RockScanPhase phase;
  final MasiColors colors;

  @override
  Widget build(BuildContext context) {
    if (phase == RockScanPhase.uploading ||
        phase == RockScanPhase.reconstructing) {
      return SizedBox(
        width: 18,
        height: 18,
        child: CircularProgressIndicator(
          strokeWidth: 2,
          valueColor: AlwaysStoppedAnimation(colors.accent),
        ),
      );
    }
    return Icon(
      switch (phase) {
        RockScanPhase.ready => Icons.view_in_ar,
        RockScanPhase.uploadFailed ||
        RockScanPhase.reconstructionFailed => Icons.error_outline,
        _ => Icons.videocam_outlined,
      },
      size: 18,
      color: phase.needsUser && phase != RockScanPhase.onDevice
          ? colors.gradeHard
          : colors.accent,
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({
    required this.message,
    required this.colors,
    required this.onDismiss,
  });

  final String message;
  final MasiColors colors;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.symmetric(horizontal: MasiSpacing.lg),
    padding: const EdgeInsets.all(MasiSpacing.md),
    decoration: BoxDecoration(
      color: colors.surface2,
      borderRadius: BorderRadius.circular(MasiSpacing.sm),
    ),
    child: Row(
      children: [
        Icon(Icons.error_outline, size: 18, color: colors.gradeHard),
        const SizedBox(width: MasiSpacing.sm),
        Expanded(
          child: Text(
            message,
            style: TextStyle(color: colors.ink, fontSize: 13),
          ),
        ),
        IconButton(
          key: const Key('scan-error-dismiss'),
          icon: Icon(Icons.close, size: 18, color: colors.ink3),
          onPressed: onDismiss,
        ),
      ],
    ),
  );
}

class _CaptureButton extends StatelessWidget {
  const _CaptureButton({
    required this.busy,
    required this.colors,
    required this.onPressed,
  });

  final bool busy;
  final MasiColors colors;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 50,
    child: Material(
      color: busy ? colors.surface2 : colors.accent,
      borderRadius: BorderRadius.circular(MasiSpacing.md),
      child: InkWell(
        key: const Key('scan-capture-button'),
        // Disabled while an upload is in flight: one at a time, because two
        // 50 MB uploads from a phone are slower than two in sequence and
        // there is nowhere honest to show a second progress indicator.
        onTap: busy ? null : onPressed,
        borderRadius: BorderRadius.circular(MasiSpacing.md),
        child: Center(
          child: Text(
            busy ? 'Uploading…' : 'Capture in 3D',
            style: TextStyle(
              color: busy ? colors.ink3 : colors.onAccent,
              fontSize: 16,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
    ),
  );
}
