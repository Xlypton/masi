import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/db/storage_durability_provider.dart';
import '../features/account/application/pwa_install_providers.dart';
import '../features/topo/presentation/canvas_chrome.dart';
import '../shared/presentation/masi_icon.dart';
import 'install_banner.dart';
import 'storage_retry_banner.dart';
import 'theme.dart';

/// The app's persistent bottom-navigation shell, wrapping the three primary
/// destinations — Topos (home), Map, Feed — each an
/// [StatefulShellBranch]/`IndexedStack` branch of `router.dart`'s
/// `StatefulShellRoute.indexedStack`. Switching tabs via [navigationShell]'s
/// `goBranch` preserves each branch's own navigator/scroll state (unlike a
/// plain `context.go`, which would rebuild the destination from scratch).
///
/// Every OTHER route (`/walls/:wallId`, `/community/topo/:wallId`, `/areas`,
/// `/account`, `/logbook`, ...) is a top-level [GoRoute] declared as a
/// SIBLING of the shell route in `router.dart` — those build on the root
/// navigator and appear full-screen, above this bar, per DESIGN.md's "Chrome
/// floats, content is king." (a topo canvas or a topo's read-only community
/// detail is a focused, full-screen task, not one of the three persistent
/// tabs).
///
/// ALL THREE branches are full-bleed (#48, generalized by #51): [build] sets
/// `Scaffold.extendBody: true` unconditionally, so every branch's content
/// draws edge-to-edge behind the translucent [GlassChrome] bar rather than
/// being inset above it — the bar floats over Topos/Map/Feed alike, matching
/// DESIGN.md's "Chrome floats, content is king." Each branch's own scrolling
/// content adds bottom clearance for itself (rather than the Scaffold
/// insetting the whole body) by reading `MediaQuery.of(context)
/// .padding.bottom` and folding it into its scroll view's bottom padding:
/// `community_screen.dart`'s `_MapView` for its bottom-anchored overlay
/// controls (find-me, legend, attribution), `_FeedView`'s list, and
/// `topos_screen.dart`'s `_ToposList` + compact add button. Under
/// `extendBody`, Flutter's own `Scaffold` computes that value as the REAL
/// measured `bottomNavigationBar` height (maxed with the device safe-area
/// inset, see `_BodyBuilder`/`bottomWidgetsHeight` in `scaffold.dart`), so
/// this stays correct across text-scale/device changes without a
/// hand-maintained height constant. Each screen's own top-level `SafeArea`
/// uses `bottom: false` so that measured value reaches its scroll view
/// unconsumed, exactly like `CommunityMapScreen` already did for the Map
/// branch pre-#51.
class NavShell extends ConsumerWidget {
  const NavShell({super.key, required this.navigationShell});

  /// Drives which branch's content is shown (`navigationShell.currentIndex`)
  /// and switches branches (`navigationShell.goBranch`) — supplied by
  /// `router.dart`'s `StatefulShellRoute.indexedStack` builder.
  final StatefulNavigationShell navigationShell;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Installed-standalone-PWA-only (#58 cluster): iOS reports
    // safe-area-inset-bottom = 0 in that mode (apple-mobile-web-app-status-bar-style
    // is 'default'), so the bottom bar's SafeArea below adds nothing and the
    // pill sits over the home indicator. Everywhere else (in-browser Safari,
    // native iOS/Android, tests) this stays false and behavior is unchanged.
    final isStandalone = ref.watch(pwaInstallStatusProvider).isStandalone;
    return Scaffold(
      // At most ONE shell notice sits ABOVE the branch content, never covering
      // the floating bottom bar — see [ShellNotices]. On the overwhelmingly
      // common path it collapses to zero height and this is just
      // `navigationShell` in an `Expanded`, exactly as before.
      body: Column(
        children: [
          const ShellNotices(),
          Expanded(child: navigationShell),
        ],
      ),
      // Every branch extends under the floating bar now (#51) — see this
      // class's doc.
      extendBody: true,
      bottomNavigationBar: SafeArea(
        // Standalone-PWA-only floor: `minimum` takes max(deviceInset, this)
        // per edge, so a real (non-zero) device inset still wins and nothing
        // double-counts — this only fills the gap when iOS reports zero.
        minimum: EdgeInsets.only(bottom: isStandalone ? MasiSpacing.xxl : 0),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            MasiSpacing.lg,
            0,
            MasiSpacing.lg,
            MasiSpacing.sm,
          ),
          // A floating GlassChrome pill (reused from the topo canvas's
          // chrome — see that class's doc), NOT a Material
          // `BottomNavigationBar`/opaque `BottomAppBar`: the bar is meant to
          // read as the SAME translucent-glass chrome material used
          // throughout the rest of the app, never a flat opaque strip.
          child: GlassChrome(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
            child: Row(
              children: [
                Expanded(
                  child: _NavTab(
                    tabKey: const Key('nav-tab-topos'),
                    iconName: 'route',
                    label: 'Topos',
                    selected: navigationShell.currentIndex == 0,
                    onTap: () => navigationShell.goBranch(0),
                  ),
                ),
                Expanded(
                  child: _NavTab(
                    tabKey: const Key('nav-tab-map'),
                    iconName: 'topo_map',
                    label: 'Map',
                    selected: navigationShell.currentIndex == 1,
                    onTap: () => navigationShell.goBranch(1),
                  ),
                ),
                Expanded(
                  child: _NavTab(
                    tabKey: const Key('nav-tab-feed'),
                    iconName: 'comment',
                    label: 'Feed',
                    selected: navigationShell.currentIndex == 2,
                    onTap: () => navigationShell.goBranch(2),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A single bottom-nav destination: a [MasiIcon] glyph over a short label,
/// tinted [MasiColors.accent] when [selected] (else [MasiColors.ink3]).
class _NavTab extends StatelessWidget {
  const _NavTab({
    required this.tabKey,
    required this.iconName,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final Key tabKey;
  final String iconName;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = MasiColors.of(context);
    final color = selected ? colors.accent : colors.ink3;
    return Material(
      key: tabKey,
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(MasiRadii.control),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              MasiIcon(iconName, size: 22, color: color),
              const SizedBox(height: 2),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: color,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The shell's notice slot: at most ONE banner above the branch content.
///
/// Why a single slot rather than a stack of banners. Each notice owns clearing
/// the status-bar/notch inset itself (there is no AppBar), which it does with
/// its own `SafeArea(top: true)`. Two SIBLING `SafeArea`s each add the full
/// inset — `MediaQuery.removePadding` only affects a widget's own subtree — so
/// stacking two notices would open a status-bar-height gap between them. And
/// when a notice has nothing to say it must collapse to TRULY zero height, so
/// wrapping the pair in one shared `SafeArea` is not an option either: it would
/// leave a stray gap above the content on the normal path.
///
/// The priority is not arbitrary. [StorageRetryBanner] wins because storage
/// being unopenable is the only condition here that can lose the user's work,
/// and because "add this app to your home screen" is absurd advice while the
/// app cannot open its own storage — suppressing the install prompt on that
/// path is the right call regardless of the layout constraint above.
class ShellNotices extends ConsumerWidget {
  const ShellNotices({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Deliberately keyed off `storageRetryNotice` rather than
    // `StorageDurability.isEphemeral`: a merely-slow open (`isProbing`) and the
    // two failures no re-open can fix (an L7 schema downgrade, a blocked
    // in-memory browser backend) all return null, so this never turns a slow
    // boot into an alarm and never offers a button that cannot work. See that
    // function's doc.
    final notice = storageRetryNotice(ref.watch(storageDurabilityProvider));
    if (notice != null) return StorageRetryBanner(notice: notice);
    return const InstallBanner();
  }
}
