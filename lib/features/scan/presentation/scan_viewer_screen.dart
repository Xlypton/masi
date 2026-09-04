import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme.dart';
import '../../../core/db/app_database.dart' as db;
import '../application/rock_scan_providers.dart';
import '../domain/rock_scan_manifest.dart';
import '../domain/rock_scan_status.dart';
import 'point_cloud_view.dart';

/// One scan's 3D model, and what to say when there isn't one yet.
///
/// The states carry as much of this screen as the model does. A scan reaches
/// here from a list where it looked ready, then spends real time being none of
/// those things: queued behind another job, mid-reconstruction, failed for a
/// reason worth reading, or ready with its bytes still downloading. Each gets
/// its own answer, because "empty grey screen" is the same picture for all of
/// them and it reads as a broken app.
class ScanViewerScreen extends ConsumerWidget {
  const ScanViewerScreen({required this.scanId, super.key});

  final String scanId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = MasiColors.of(context);
    final scan = ref.watch(rockScanProvider(scanId)).value;

    return Scaffold(
      backgroundColor: colors.ground,
      body: SafeArea(
        child: Column(
          children: [
            _header(context, colors, scan),
            Expanded(child: _body(context, ref, colors, scan)),
          ],
        ),
      ),
    );
  }

  Widget _header(
    BuildContext context,
    MasiColors colors,
    db.RockScanRow? scan,
  ) {
    final manifest = RockScanManifest.tryParse(scan?.manifestJson);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        MasiSpacing.sm,
        MasiSpacing.sm,
        MasiSpacing.lg,
        MasiSpacing.sm,
      ),
      child: Row(
        children: [
          IconButton(
            key: const Key('scan-viewer-back'),
            icon: Icon(Icons.arrow_back_ios_new, color: colors.ink, size: 20),
            onPressed: () => Navigator.of(context).maybePop(),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '3D model',
                  style: TextStyle(
                    color: colors.ink,
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (_subtitle(manifest) case final line?)
                  Text(
                    line,
                    style: TextStyle(color: colors.ink3, fontSize: 13),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// What the reconstruction is worth, in one line.
  ///
  /// Never a size in metres unless the manifest actually carries a scale.
  /// Structure-from-motion recovers geometry only up to a similarity
  /// transform, so an arbitrary-scale cloud has no idea how big the rock is,
  /// and printing a number anyway would be inventing one.
  static String? _subtitle(RockScanManifest? manifest) {
    if (manifest == null) return null;
    final parts = <String>[];
    if (manifest.pointCount case final count?) parts.add('$count points');
    if (manifest.registeredRatio case final ratio?) {
      parts.add('${(ratio * 100).round()}% of frames placed');
    }
    return parts.isEmpty ? null : parts.join(' · ');
  }

  Widget _body(
    BuildContext context,
    WidgetRef ref,
    MasiColors colors,
    db.RockScanRow? scan,
  ) {
    if (scan == null) {
      return _Message(
        icon: Icons.help_outline,
        title: 'Scan not found',
        detail: 'It may have been deleted on another device.',
        colors: colors,
      );
    }

    final phase = rockScanPhase(
      upload: RockScanUpload.fromWire(scan.uploadState),
      status: RockScanStatus.fromWire(scan.status),
    );

    switch (phase) {
      case RockScanPhase.onDevice:
        return _Message(
          icon: Icons.cloud_upload_outlined,
          title: 'Not uploaded yet',
          detail: 'The video is still on this device.',
          colors: colors,
        );
      case RockScanPhase.uploading:
        return _Message(
          icon: Icons.cloud_upload_outlined,
          title: 'Uploading',
          detail: 'Reconstruction starts once the video is up.',
          colors: colors,
          busy: true,
        );
      case RockScanPhase.uploadFailed:
        return _Message(
          icon: Icons.error_outline,
          title: 'Upload failed',
          detail: 'Record another pass from the scans list.',
          colors: colors,
        );
      case RockScanPhase.reconstructing:
        return _Message(
          icon: Icons.hourglass_empty,
          title: 'Building the 3D model',
          // No ETA. Nothing on this device knows one — it depends on a
          // worker's queue — and a wrong estimate is worse than none.
          detail: 'You can leave this screen; it will be here when it is done.',
          colors: colors,
          busy: true,
        );
      case RockScanPhase.reconstructionFailed:
        return _Message(
          icon: Icons.error_outline,
          title: 'Could not build a model',
          detail:
              scan.failureReason ??
              'The video did not give us enough to work with.',
          colors: colors,
        );
      case RockScanPhase.ready:
        return _ready(ref, colors, scan);
    }
  }

  Widget _ready(WidgetRef ref, MasiColors colors, db.RockScanRow scan) {
    final manifest = RockScanManifest.tryParse(scan.manifestJson);
    final cloud = ref.watch(rockScanPointCloudProvider(scan.id));
    return cloud.when(
      loading: () => _Message(
        icon: Icons.view_in_ar_outlined,
        title: 'Loading the model',
        detail: null,
        colors: colors,
        busy: true,
      ),
      // A transport failure, as distinct from "not there" — the provider
      // returns null for the latter, so reaching here means something
      // genuinely broke and saying "still working" would be a lie.
      error: (_, _) => _Message(
        icon: Icons.error_outline,
        title: 'Could not load the model',
        detail: 'Check your connection and try again.',
        colors: colors,
      ),
      data: (data) {
        if (data == null) {
          // Covers both "the object is not there" and "the bytes are not a
          // cloud we can read" — from the climber's side those are the same
          // situation, and neither is worth a different instruction.
          return _Message(
            icon: Icons.cloud_off_outlined,
            title: 'The model could not be opened',
            detail:
                'The scan is marked ready, but its file is missing or '
                'unreadable. Capture the wall again to rebuild it.',
            colors: colors,
          );
        }
        return PointCloudView(
          key: const Key('scan-point-cloud'),
          cloud: data,
          // Null unless the reconstruction genuinely recovered scale, in
          // which case the view shows a measurement and otherwise shows none.
          metresPerUnit: manifest?.metresPerUnit,
        );
      },
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({
    required this.icon,
    required this.title,
    required this.detail,
    required this.colors,
    this.busy = false,
  });

  final IconData icon;
  final String title;
  final String? detail;
  final MasiColors colors;
  final bool busy;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: MasiSpacing.xxl),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (busy)
            SizedBox(
              width: 28,
              height: 28,
              child: CircularProgressIndicator(
                strokeWidth: 2.5,
                valueColor: AlwaysStoppedAnimation(colors.accent),
              ),
            )
          else
            Icon(icon, size: 44, color: colors.ink3),
          const SizedBox(height: MasiSpacing.md),
          Text(
            title,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: colors.ink,
              fontSize: 17,
              fontWeight: FontWeight.w600,
            ),
          ),
          if (detail case final text?) ...[
            const SizedBox(height: MasiSpacing.xs),
            Text(
              text,
              textAlign: TextAlign.center,
              style: TextStyle(color: colors.ink2, fontSize: 14, height: 1.4),
            ),
          ],
        ],
      ),
    ),
  );
}
