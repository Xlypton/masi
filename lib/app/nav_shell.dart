import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../features/topo/presentation/canvas_chrome.dart';
import '../shared/presentation/masi_icon.dart';
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
/// The Map branch (index 1, see `router.dart`) is full-bleed (#48): [build]
/// sets `Scaffold.extendBody` ONLY while that branch is active, so the
/// [FlutterMap] draws edge-to-edge behind the translucent [GlassChrome] bar
/// (matching the bar's own now-see-through look) while Topos/Feed (indices 0
/// and 2) keep the bar inset above their body exactly as before — least-risk
/// because `extendBody` toggles per-tab rather than globally, so nothing
/// about the other two branches' layout/tests changes. The Map view itself
/// (`community_screen.dart`'s `_MapView`) pads its bottom-anchored overlay
/// controls (find-me, legend, attribution) by `MediaQuery.of(context)
/// .padding.bottom` so they still float ABOVE the bar instead of being
/// obscured by it — under `extendBody`, Flutter's own `Scaffold` computes
/// that value as the REAL measured `bottomNavigationBar` height (maxed with
/// the device safe-area inset, see `_BodyBuilder`/`bottomWidgetsHeight` in
/// `scaffold.dart`), so this stays correct across text-scale/device changes
/// without a hand-maintained height constant.
class NavShell extends StatelessWidget {
  const NavShell({super.key, required this.navigationShell});

  /// Drives which branch's content is shown (`navigationShell.currentIndex`)
  /// and switches branches (`navigationShell.goBranch`) — supplied by
  /// `router.dart`'s `StatefulShellRoute.indexedStack` builder.
  final StatefulNavigationShell navigationShell;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: navigationShell,
      // Only the Map branch (index 1) extends under the bar (#48) — see
      // this class's doc. Topos/Feed keep `extendBody: false` (the Scaffold
      // default), so their body is inset above the bar exactly as before.
      extendBody: navigationShell.currentIndex == 1,
      bottomNavigationBar: SafeArea(
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
                    iconName: 'wall',
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
