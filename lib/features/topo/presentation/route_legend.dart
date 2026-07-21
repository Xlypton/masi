import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:climbtopo/app/theme.dart';
import 'package:climbtopo/core/routes/route_styles.dart';
import 'package:climbtopo/features/topo/application/draw_controller.dart';
import 'package:climbtopo/features/topo/domain/topo_route.dart';
import 'package:climbtopo/features/topo/presentation/grade_colors.dart';
import 'package:climbtopo/features/topo/presentation/route_palette.dart';
import 'package:climbtopo/shared/presentation/masi_icon.dart';

/// Best-effort external launch of a route's beta-video URL. Never throws:
/// an unparseable/invalid [url] or a platform launch failure is swallowed
/// (there's no useful recovery for a legend row's tap beyond not crashing
/// the canvas), mirroring this codebase's other fire-and-forget UI
/// side-effect calls.
Future<void> launchBetaVideo(String url) async {
  final uri = Uri.tryParse(url);
  if (uri == null) return;
  try {
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  } catch (_) {
    // No in-app surface to report this to from here; swallow.
  }
}

/// #26: display label for [route] — `'<number>. <name>'` when
/// [TopoRoute.name] is non-empty (after trimming), else the generic
/// `'Route <number>'` fallback. Appends ` • <grade>` when
/// [TopoRoute.gradeRaw] is set, regardless of which branch above fired.
///
/// Mirrors `LocatedRouteRef.title`'s identical name-vs-number fallback
/// (`library_crud_repository.dart`) so a route's display name reads
/// identically everywhere it's shown. Public (rather than a private
/// function local to [RouteLegend]) so `CommunityTopoDetailScreen`'s own
/// Routes list can share this exact same label/fallback logic instead of
/// duplicating it.
String routeDisplayLabel(TopoRoute route) {
  final trimmedName = route.name?.trim();
  final base = (trimmedName != null && trimmedName.isNotEmpty)
      ? '${route.number}. $trimmedName'
      : 'Route ${route.number}';
  final grade = route.gradeRaw;
  return grade != null ? '$base • $grade' : base;
}

/// Whether the [RouteLegend] panel is expanded (showing its route rows) or
/// collapsed (hidden/minimized) — defaults to expanded in view mode. See
/// [LegendExpandedController.setForMode] for the mode-aware reset used when
/// switching between view and draw modes.
class LegendExpandedController extends Notifier<bool> {
  /// FIX #6 (HIGH, CONFIRMED — multi-instance state bleed): [wallId] is the
  /// family key [legendExpandedProvider] was looked up with — required by
  /// [NotifierProvider.family]'s factory signature, so every wall gets its
  /// own expanded/collapsed flag instead of one shared app-lifetime global.
  /// Not read by any method below; kept for instance identity/debugging
  /// parity with [DrawController.wallId].
  LegendExpandedController(this.wallId);

  final String wallId;

  @override
  bool build() => true; // view-mode default = expanded

  void toggle() => state = !state;

  /// Reset to the mode-appropriate default: expanded in view, collapsed in draw.
  void setForMode(DrawMode mode) => state = mode == DrawMode.view;
}

/// FIX #6: keyed by wallId, `autoDispose`, mirroring [drawControllerProvider]
/// — see that provider's doc for why (two simultaneously-mounted canvases
/// must not share one collapsed/expanded flag; a fresh mount of the same
/// wall should reset to the mode-appropriate default rather than keep
/// whatever a long-gone previous mount left behind).
final legendExpandedProvider =
    NotifierProvider.autoDispose.family<LegendExpandedController, bool, String>(
  LegendExpandedController.new,
);

/// Fraction of the screen height the [RouteLegend] panel is capped at once
/// it has enough routes to need it. Below this cap the panel just shrink-
/// wraps to its own content (see [RouteLegend.build]) — a single route
/// gets ~one row of height, not a tall mostly-empty box; once the route
/// list is tall enough to exceed this fraction of the screen, it caps here
/// and scrolls internally instead of pushing the canvas above it off
/// screen or clipping the last rows.
///
/// Bug fix: this used to be a hard-coded 140px [SizedBox] regardless of
/// route count, which clipped every route past the first ~2 (140px is
/// barely two `ListTile`s) — scrolling worked, but most of the legend was
/// invisible until the user discovered they could drag it.
///
/// Public (rather than private) so [TopoCanvasBody] can reuse the exact same
/// fraction when it computes an explicit [RouteLegend.maxHeight] against the
/// height actually available below it, rather than the full screen — see
/// that widget's doc for the short-viewport overflow bug this fixes.
const double kLegendMaxHeightFraction = 0.4;

/// Lists every route in [DrawState.routes]: a color swatch (see
/// [colorForRoute] — [kRoutePalette] for an ungraded route, its grade
/// band's color once graded) plus its number and grade (if set), a
/// visibility toggle ([DrawController.toggleRouteVisibility]), a delete
/// control ([DrawController.removeRoute]), and select-on-tap
/// ([DrawController.selectRoute]). Renders nothing if there are no routes
/// yet.
class RouteLegend extends ConsumerWidget {
  const RouteLegend({
    super.key,
    required this.wallId,
    this.maxHeight,
    this.readOnly = false,
    this.onLogAscent,
  });

  /// FIX #6: family key for [drawControllerProvider] — see that provider's
  /// doc. Always the same wallId as the owning [TopoCanvasScreen].
  final String wallId;

  /// Explicit height cap, overriding the default `kLegendMaxHeightFraction *
  /// MediaQuery.sizeOf(context).height` fallback below.
  ///
  /// [TopoCanvasBody] passes this — computed against the height actually
  /// available to it (not the full screen) — so the legend's ~40% cap is a
  /// fraction of AVAILABLE height, not screen height (see that widget's doc
  /// for the short-viewport overflow bug this fixes). Null (the default)
  /// preserves this widget's original screen-relative behavior for any other
  /// caller/test that doesn't need the distinction.
  final double? maxHeight;

  /// Mirrors `TopoCanvasScreen.readOnly` (see that class's doc). When
  /// `true`, hides each row's visibility-toggle and delete [IconButton]s —
  /// the legend's own two editing affordances — leaving the swatch/label
  /// and tap-to-select (a non-mutating view interaction) untouched.
  /// Defaults to `false`, preserving every existing call site's behavior
  /// exactly.
  final bool readOnly;

  /// Invoked with a route's [TopoRoute.id] (the same locally-reassigned int
  /// every other row control here keys on — see [TopoRoute.id]'s doc) when
  /// its per-route "log ascent" [IconButton] is tapped. The caller (e.g.
  /// [TopoCanvasScreen]) is responsible for resolving this int to the
  /// route's real, persisted DB id (via
  /// `RouteRepository.routeDbIdsByNumber`) before opening `LogAscentSheet` —
  /// this widget has no repository access of its own and never needs to
  /// know that id.
  ///
  /// The button only renders when this is non-null AND [readOnly] is
  /// `false` — a read-only viewer of someone else's shared topo already has
  /// its own separate "log ascent" affordance (the community detail
  /// screen's per-route button), so this widget's own copy stays hidden
  /// there. Null (the default) preserves every existing call site's
  /// behavior exactly (no button renders at all).
  final void Function(int routeId)? onLogAscent;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final drawState = ref.watch(drawControllerProvider(wallId));
    final notifier = ref.read(drawControllerProvider(wallId).notifier);

    if (drawState.routes.isEmpty) {
      return const SizedBox.shrink();
    }

    final accent = MasiColors.of(context).accent;

    final effectiveMaxHeight =
        maxHeight ??
        MediaQuery.sizeOf(context).height * kLegendMaxHeightFraction;

    return ConstrainedBox(
      key: const Key('topo-route-legend'),
      constraints: BoxConstraints(maxHeight: effectiveMaxHeight),
      // `shrinkWrap: true` sizes the ListView to its own content (up to
      // the `maxHeight` cap above) instead of always claiming the full
      // cross-axis extent it's offered — this is what lets a single route
      // render as ~one row instead of a tall, mostly-empty box. Once
      // content height exceeds `maxHeight`, the surrounding
      // [ConstrainedBox] clamps it there and the ListView scrolls
      // internally (its default behavior once it's taller than its own
      // bounds) — every row stays reachable, none are ever clipped.
      child: ListView.builder(
        shrinkWrap: true,
        // Without an explicit `padding:`, BoxScrollView auto-applies the
        // ambient device safe-area `MediaQuery.padding` (the top notch
        // inset, ~44-47px) as leading scroll padding — producing a
        // conspicuous empty gap above the first route row. This card
        // already sits inside its own positioned container with its own
        // margins, so the outer safe-area inset must not leak in here.
        padding: EdgeInsets.zero,
        itemCount: drawState.routes.length,
        itemBuilder: (context, index) {
          final route = drawState.routes[index];
          final isSelected = route.id == drawState.selectedRouteId;
          final color = colorForRoute(route, kRoutePalette);

          // Compact rows (refined alongside #15's floating-overlay legend):
          // `dense` + `VisualDensity.compact` shrink the ListTile's own
          // vertical rhythm, a smaller CircleAvatar swatch, and both
          // trailing IconButtons dropped to a small icon size with their
          // default `kMinInteractiveDimension` (48px) tap-target constraint
          // removed (`constraints: BoxConstraints()`) plus tight padding —
          // together this fits noticeably more than ~2 rows in the legend's
          // capped height instead of the previous default-ListTile spacing
          // reading as squished-yet-oversized.
          return ListTile(
            key: Key('topo-route-legend-item-${route.id}'),
            dense: true,
            visualDensity: VisualDensity.compact,
            tileColor: Colors.transparent,
            selectedTileColor: accent.withValues(alpha: 0.12),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: MasiSpacing.sm,
            ),
            selected: isSelected,
            onTap: () => notifier.selectRoute(route.id),
            leading: CircleAvatar(backgroundColor: color, radius: 8),
            title: Text(
              routeDisplayLabel(route),
              style: Theme.of(context).textTheme.bodyMedium,
              // Ellipsize rather than wrap: with up to three trailing
              // IconButtons now possible (log-ascent + visibility + delete),
              // the title's available width can shrink enough that an
              // un-truncated label would wrap to a second line and overflow
              // this dense/compact ListTile's fixed row height (BUG-2a-style
              // RenderFlex overflow) instead of just eliding gracefully.
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            // #41/#42/#44: style-tag chips + star rating render as a
            // second line whenever either is present, in BOTH read-only
            // and edit modes (unlike the trailing edit controls below,
            // these are display-only, so readOnly doesn't hide them).
            subtitle: (route.styleTags.isEmpty && (route.stars ?? 0) <= 0)
                ? null
                : Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (route.styleTags.isNotEmpty)
                          Wrap(
                            spacing: 4,
                            runSpacing: 4,
                            children: [
                              for (final tag in route.styleTags)
                                _RouteStyleTagChip(routeId: route.id, tag: tag),
                            ],
                          ),
                        if ((route.stars ?? 0) > 0)
                          Row(
                            key: Key('route-stars-${route.id}'),
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              for (var i = 0; i < route.stars!; i++)
                                const Padding(
                                  padding: EdgeInsets.only(right: 1),
                                  child: MasiIcon('star_fill', size: 12),
                                ),
                            ],
                          ),
                      ],
                    ),
                  ),
            // Beta-video button renders in BOTH read-only and edit modes
            // (display-only external launch, not an editing affordance);
            // the log-ascent/visibility/delete cluster after it stays
            // gated on `readOnly` exactly as before.
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (route.betaVideoUrl != null)
                  IconButton(
                    key: Key('route-beta-${route.id}'),
                    tooltip: 'Watch beta video',
                    iconSize: 18,
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.all(4),
                    constraints: const BoxConstraints(),
                    icon: MasiIcon('globe'),
                    onPressed: () => launchBetaVideo(route.betaVideoUrl!),
                  ),
                if (!readOnly) ...[
                  if (onLogAscent != null)
                    IconButton(
                      key: Key('topo-log-ascent-${route.id}'),
                      tooltip: 'Log ascent',
                      iconSize: 18,
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.all(4),
                      constraints: const BoxConstraints(),
                      icon: MasiIcon('send_check', size: 18),
                      onPressed: () => onLogAscent!(route.id),
                    ),
                  IconButton(
                    key: Key('topo-route-visibility-${route.id}'),
                    tooltip: route.visible ? 'Hide route' : 'Show route',
                    iconSize: 18,
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.all(4),
                    constraints: const BoxConstraints(),
                    icon: route.visible
                        ? MasiIcon('eye')
                        : Icon(Icons.visibility_off_outlined),
                    onPressed: () => notifier.toggleRouteVisibility(route.id),
                  ),
                  IconButton(
                    key: Key('topo-route-delete-${route.id}'),
                    tooltip: 'Delete route',
                    iconSize: 18,
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.all(4),
                    constraints: const BoxConstraints(),
                    icon: MasiIcon('delete'),
                    onPressed: () => notifier.removeRoute(route.id),
                  ),
                ],
              ],
            ),
          );
        },
      ),
    );
  }
}

/// A small, non-interactive display chip for one of [TopoRoute.styleTags]:
/// a curated tag (see `core/routes/route_styles.dart`) shows its curated
/// [RouteStyle.label]; an arbitrary custom tag shows its raw stored string.
class _RouteStyleTagChip extends StatelessWidget {
  const _RouteStyleTagChip({required this.routeId, required this.tag});

  final int routeId;
  final String tag;

  @override
  Widget build(BuildContext context) {
    final colors = MasiColors.of(context);
    final resolved = resolveStyleTag(tag);
    return Container(
      key: Key('route-styletag-$routeId-$tag'),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: colors.surface2,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        resolved.displayLabel,
        style: TextStyle(fontSize: 10, fontWeight: FontWeight.w500, color: colors.ink2),
      ),
    );
  }
}
