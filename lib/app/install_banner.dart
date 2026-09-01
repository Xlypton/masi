import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/account/application/pwa_install.dart';
import '../features/account/presentation/add_to_home_screen_alert.dart';
import '../features/account/application/pwa_install_providers.dart';
import '../features/account/application/pwa_install_types.dart';
import '../features/topo/presentation/canvas_chrome.dart' show kMasiAmbientShadow;
import '../shared/presentation/masi_icon.dart';
import '../shared/presentation/masi_toast.dart';
import 'theme.dart';

/// A compact, dismissible "Add to Home Screen" banner mounted at the top of
/// the post-login [NavShell] body (#59) — a more discoverable home for the
/// PWA-install affordance than tucking it away at the bottom of the Account
/// screen (`account_screen.dart`'s `_InstallSection`, whose gating + iOS
/// dialog this reuses verbatim).
///
/// A mobile-web-only concern: native/desktop/test builds get the inert stub
/// [PwaInstallStatus] (`pwa_install_providers.dart`), so this renders nothing
/// there — matching the "no visual change on iOS/Android app" requirement.
/// It also renders nothing once the app is already installed
/// ([PwaInstallStatus.isStandalone]) or after the user dismisses it for the
/// session (the local [_InstallBannerState._dismissed] flag).
///
/// Shown when — mirroring `_InstallSection`'s exact gate —
/// `!isStandalone && (canPrompt || platform == ios)`; its single action
/// button either fires the browser's real deferred install prompt
/// ([pwaPromptInstall], Chromium/Android's `beforeinstallprompt`) or, on iOS
/// Safari (no programmatic install API), opens [showAddToHomeScreenAlert]
/// explaining the manual Share-sheet steps.
class InstallBanner extends ConsumerStatefulWidget {
  const InstallBanner({super.key});

  @override
  ConsumerState<InstallBanner> createState() => _InstallBannerState();
}

class _InstallBannerState extends ConsumerState<InstallBanner> {
  /// Whether the user tapped dismiss this session — a purely local, transient
  /// flag (not persisted): the banner should stay gone until the next launch,
  /// but there's nothing worth remembering across launches.
  bool _dismissed = false;

  @override
  Widget build(BuildContext context) {
    final status = ref.watch(pwaInstallStatusProvider);
    final show =
        !_dismissed &&
        !status.isStandalone &&
        (status.canPrompt || status.platform == PwaPlatform.ios);
    // Fully collapsed when there's nothing to offer — crucially NO wrapping
    // SafeArea/padding in this branch, so hidden means truly zero height (no
    // stray status-bar-height gap above the shell's content).
    if (!show) return const SizedBox.shrink();

    final colors = MasiColors.of(context);
    final textTheme = Theme.of(context).textTheme;

    return SafeArea(
      // This banner is the topmost widget in the shell body (there's no
      // AppBar), so it owns clearing the status-bar/notch inset itself. The
      // shell's branch content below keeps its own `top: true` SafeArea.
      top: true,
      bottom: false,
      child: Padding(
        // `lg` sides to match the screen-level notices (`SyncBanner`,
        // `_StorageWarningBanner`, `MasiAsyncView`'s stale-error bar), all of
        // which inset by `fromLTRB(lg, md, lg, 0)`. See
        // `StorageRetryBanner`'s copy of this comment — the two shell notices
        // and the screen ones can appear in one vertical stack, and the 12px
        // vs 16px mismatch read as staggered edges.
        padding: const EdgeInsets.fromLTRB(
          MasiSpacing.lg,
          MasiSpacing.md,
          MasiSpacing.lg,
          0,
        ),
        child: Container(
          key: const Key('install-banner'),
          padding: const EdgeInsets.all(MasiSpacing.md),
          decoration: BoxDecoration(
            color: colors.surface2,
            borderRadius: BorderRadius.circular(MasiRadii.card),
            boxShadow: kMasiAmbientShadow,
          ),
          child: Row(
            children: [
              MasiIcon('download', size: 20, color: colors.accent),
              const SizedBox(width: MasiSpacing.md),
              Expanded(
                child: Text(
                  'Add Masi to your home screen',
                  style: textTheme.bodyMedium?.copyWith(
                    color: colors.ink,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(width: MasiSpacing.sm),
              TextButton(
                key: const Key('install-banner-action'),
                style: TextButton.styleFrom(
                  foregroundColor: colors.accent,
                  padding: const EdgeInsets.symmetric(
                    horizontal: MasiSpacing.sm,
                  ),
                  // 44x44, not `Size.zero` — the iOS HIG minimum tap target
                  // (same recipe as `topo_canvas_screen.dart`'s
                  // `_topRowIconStyle`). The short labels this wears
                  // ("Install"/"How") made it the smallest target of the lot.
                  //
                  // MEASURED 135.7x44 under the app's own theme. `minimumSize`
                  // is the one thing here the ambient `VisualDensity` still
                  // scales, so under a desktop-density theme this same button
                  // measures 36 tall rather than 44. Accepted: the target is
                  // mobile web (iPhone Safari), whose platform density is
                  // standard — but it is why the floor is asserted by
                  // `tester.getSize` in `install_banner_test.dart` rather than
                  // trusted to be whatever this constant says.
                  minimumSize: const Size(44, 44),
                  // Kept: `shrinkWrap` keeps the footprint at exactly
                  // `minimumSize` rather than Material's padded 48x48 default.
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                onPressed: () => _handleAction(context, status),
                child: Text(status.canPrompt ? 'Install' : 'How'),
              ),
              IconButton(
                key: const Key('install-banner-dismiss'),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
                // NO `visualDensity: VisualDensity.compact` here, deliberately
                // — that is what put this control under the tap-target floor
                // the rest of this banner was raised to.
                //
                // `IconButton`'s footprint is its TAP TARGET, not its icon:
                // with the default `MaterialTapTargetSize.padded` the button
                // reserves `kMinInteractiveDimension`, and a non-standard
                // `VisualDensity` shrinks that reservation rather than only
                // the visible box — so compact density silently took the
                // dismiss target below 44. Dropping it restores the Material
                // default, which is already at or above the floor.
                //
                // MEASURED, never derived: `install_banner_test.dart`'s "the
                // dismiss control clears the 44x44 tap-target floor" asserts
                // `tester.getSize` on this button, which now reports 48x48.
                // Reasoning about density arithmetic instead of measuring it
                // is exactly what produced the wrong number the first time
                // round — the claim that compact density left this at 44 was
                // off by the 4.0 interval `baseSizeAdjustment` scales by, and
                // it actually shipped at 40.
                //
                // Unlike the `minimumSize` on the action button above, this
                // 48x48 was measured to hold under the ambient theme density
                // too (standard AND compact themes both render it 48x48) —
                // only the WIDGET-level `visualDensity` this line removed ever
                // shrank it. So there is no desktop-density caveat here.
                //
                // Nothing VISIBLE changes: `padding` and `constraints` are
                // untouched, so the glyph and its ink box render as before —
                // only the invisible hit area grows.
                tooltip: 'Dismiss',
                onPressed: () => setState(() => _dismissed = true),
                icon: MasiIcon('close', size: 18, color: colors.ink3),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Routes the action button by affordance: [PwaInstallStatus.canPrompt]
  /// fires the browser's real install prompt (and confirms with a SnackBar on
  /// accept, matching `_InstallSection._handleInstallPrompt`); otherwise (iOS)
  /// opens the manual Share-sheet instructions dialog.
  void _handleAction(BuildContext context, PwaInstallStatus status) {
    if (status.canPrompt) {
      _handleInstallPrompt(context);
    } else {
      _showAddToHomeScreenDialog(context);
    }
  }

  /// Fires the browser's real (Chromium/Android) install prompt via
  /// [pwaPromptInstall] and — only on an accepted outcome — confirms with a
  /// SnackBar. A dismissed/unavailable outcome is a silent no-op: the
  /// browser's own prompt UI already gave the user a clear choice.
  Future<void> _handleInstallPrompt(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final accepted = await pwaPromptInstall();
    if (accepted) {
      messenger.showMasiToast('Installing…', kind: MasiToastKind.info);
    }
  }

  void _showAddToHomeScreenDialog(BuildContext context) {
    unawaited(showAddToHomeScreenAlert(context));
  }
}
