import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/db/storage_durability_provider.dart';
import '../features/account/application/pwa_install_providers.dart';
import '../features/backup/application/sync_orchestrator.dart';
import '../features/community/application/feed_freshness_providers.dart';
import '../features/topo/presentation/canvas_chrome.dart';
import '../shared/presentation/masi_icon.dart';
import 'install_banner.dart';
import 'storage_pressure_banner.dart';
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
class NavShell extends ConsumerStatefulWidget {
  const NavShell({super.key, required this.navigationShell});

  /// Drives which branch's content is shown (`navigationShell.currentIndex`)
  /// and switches branches (`navigationShell.goBranch`) — supplied by
  /// `router.dart`'s `StatefulShellRoute.indexedStack` builder.
  final StatefulNavigationShell navigationShell;

  /// The Feed branch's index, named because three separate places below
  /// compare against it and an off-by-one would silently mis-target the dot.
  static const int feedBranchIndex = 2;

  @override
  ConsumerState<NavShell> createState() => _NavShellState();
}

class _NavShellState extends ConsumerState<NavShell> {
  @override
  void initState() {
    super.initState();
    // Covers a cold start that lands ON the Feed — a PWA reload of `/feed`,
    // or a restored route. Without this the baseline would never be stamped
    // for a user who mostly arrives that way, and the dot could never appear
    // for them at all.
    if (widget.navigationShell.currentIndex == NavShell.feedBranchIndex) {
      _markFeedSeen();
    }
  }

  @override
  void didUpdateWidget(NavShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    final was = oldWidget.navigationShell.currentIndex;
    final now = widget.navigationShell.currentIndex;
    if (was == now) return;
    // Stamped on ENTERING and on LEAVING, which is not belt-and-braces.
    //
    // Entering alone is not enough: the list updates live, so somebody sitting
    // on the Feed for ten minutes genuinely sees everything that lands during
    // it, and stamping only at entry would dot the tab the moment they walked
    // away for things they had already read.
    //
    // Leaving alone is not enough either, because of the cold-start case in
    // `initState`.
    if (was == NavShell.feedBranchIndex || now == NavShell.feedBranchIndex) {
      _markFeedSeen();
    }
  }

  /// Fire-and-forget: nothing renders off the result, and a nav transition
  /// must never wait on a settings write.
  void _markFeedSeen() {
    // Post-frame — `initState`/`didUpdateWidget` run mid-build, and this
    // mutates a provider the same tree is reading.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(feedLastSeenProvider.notifier).markSeen();
    });
  }

  @override
  Widget build(BuildContext context) {
    final navigationShell = widget.navigationShell;
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
                    selected:
                        navigationShell.currentIndex ==
                        NavShell.feedBranchIndex,
                    // Never dotted while you are standing on it — the tab is
                    // showing you the very thing the dot would point at.
                    showDot:
                        navigationShell.currentIndex !=
                            NavShell.feedBranchIndex &&
                        ref.watch(feedHasUnseenProvider),
                    onTap: () =>
                        navigationShell.goBranch(NavShell.feedBranchIndex),
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
    this.showDot = false,
  });

  final Key tabKey;
  final String iconName;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  /// Draws the unseen dot over the glyph's top-right corner.
  ///
  /// A dot, not a count. A number would have to be honest about WHAT it was
  /// counting, and the feed's unit is not a countable thing the way an inbox's
  /// is — a duplicate group is one row made of several topos, and a rank
  /// change can move an old topo to the top. "There is something you have not
  /// seen" is the claim this can actually support.
  final bool showDot;

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
              // `clipBehavior: none` — the dot deliberately overhangs the
              // glyph's box, and the default `hardEdge` would shave it.
              Stack(
                clipBehavior: Clip.none,
                children: [
                  MasiIcon(iconName, size: 22, color: color),
                  if (showDot)
                    Positioned(
                      top: -1,
                      right: -2,
                      child: _UnseenDot(colors: colors),
                    ),
                ],
              ),
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
/// [StoragePressureBanner] (task #51) ranks next, above the install prompt,
/// for the same "suppressing the install prompt is still correct" reasoning
/// one step down in severity: storage being NEARLY full is a real,
/// near-term risk to the user's own unsaved work (the very next own-photo
/// import can throw on quota), just not the immediate one an unopenable
/// database already is.
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

    // #51: the proactive "storage is nearly full" warning. Reuses #49 P1's
    // existing signal (`SyncOrchestratorState.lastPublicPhotoPruneOutcome`,
    // already refreshed on every successful pull) rather than inventing a
    // second one — see `PublicPhotoPruneOutcome.automaticReliefExhausted`'s
    // doc for exactly which two prune reasons mean "nothing further this app
    // can do on its own."
    final pruneOutcome = ref.watch(syncOrchestratorProvider).lastPublicPhotoPruneOutcome;
    if (pruneOutcome != null && pruneOutcome.automaticReliefExhausted) {
      return const StoragePressureBanner();
    }

    return const InstallBanner();
  }
}

/// The Feed tab's "there is something you have not seen" mark.
///
/// A ring in the bar's own surface colour sits under the accent dot so it
/// stays legible against the glyph it overlaps. Without it, a dot landing on a
/// dark icon stroke reads as part of the icon rather than as a badge — and the
/// bar is translucent glass, so there is no fixed background colour to rely on.
class _UnseenDot extends StatelessWidget {
  const _UnseenDot({required this.colors});

  final MasiColors colors;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('nav-tab-feed-dot'),
      width: 9,
      height: 9,
      decoration: BoxDecoration(
        color: colors.accent,
        shape: BoxShape.circle,
        border: Border.all(color: colors.surface, width: 1.5),
      ),
    );
  }
}
