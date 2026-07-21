import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:climbtopo/app/theme.dart';
import 'package:climbtopo/features/topo/application/draw_controller.dart';
import 'package:climbtopo/features/topo/domain/topo_route.dart';
import 'package:climbtopo/features/topo/presentation/canvas_chrome.dart';
import 'package:climbtopo/shared/presentation/masi_icon.dart';

/// Overall height of [SymbolPaletteBar]. Bumped from the historical `56`
/// (an icon-only row) to fit an icon PLUS a short text label per control —
/// see [_SymbolButton] and the class doc's "unlabeled symbols" bug fix.
/// Exposed as a named constant (rather than a bare literal in the widget)
/// so callers/tests that need to reason about this bar's footprint (e.g.
/// the "SymbolPaletteBar + TopoCanvas symbol placement" test group in
/// `test/widget_test.dart`, which lays out a fixed-size canvas directly
/// below this bar) have one source of truth for it.
const double kSymbolPaletteBarHeight = 68.0;

/// Widget builder for each [SymbolType] control in [SymbolPaletteBar].
///
/// Bug fix (unlabeled + ambiguous glyphs): [SymbolType.bolt] used to reuse
/// `Icons.close` ("X"), which reads as "close/delete" rather than a
/// climbing bolt; it now uses `MasiIcon('bolt')` (a plain filled
/// dot — the standard topo-diagram glyph for a bolt) so it's not confused
/// with a dismiss/cancel action. [SymbolType.rest] uses
/// `Icons.self_improvement` (a seated/resting figure glyph), which reads
/// unambiguously as "rest" once paired with its text label.
/// [SymbolType.anchor]/[SymbolType.top]/[SymbolType.crux] use Masi
/// equivalents, while [SymbolType.rest] keeps Material (no equivalent).
///
/// [SymbolType.disabledHold] (feature #43, per-route excluded hold) uses
/// `MasiIcon('close')` -- the brand set has no dedicated "off/no/ban" glyph,
/// so the "X" close glyph is the closest available match (a substitution,
/// not a perfect semantic fit, but MasiIcon-only per this app's icon
/// mandate: no `Icons.`/`CupertinoIcons.` allowed). The on-canvas marker
/// itself (see `TopoPainter._paintSymbol`) is a distinct hand-drawn
/// prohibition/no-entry sign (circle + diagonal slash) regardless of this
/// palette glyph choice.
Widget _symbolIconWidget(SymbolType type, {Color? color, double? size}) {
  switch (type) {
    case SymbolType.anchor:
      return MasiIcon('anchor', color: color, size: size);
    case SymbolType.bolt:
      return MasiIcon('bolt', color: color, size: size);
    case SymbolType.top:
      return MasiIcon('finish_flag', color: color, size: size);
    case SymbolType.crux:
      return MasiIcon('crux', color: color, size: size);
    case SymbolType.rest:
      return Icon(Icons.self_improvement, color: color, size: size);
    case SymbolType.disabledHold:
      return MasiIcon('close', color: color, size: size);
  }
}

/// Tooltip/label used for each [SymbolType] control in [SymbolPaletteBar].
const Map<SymbolType, String> _symbolLabels = {
  SymbolType.anchor: 'Anchor',
  SymbolType.bolt: 'Bolt',
  SymbolType.top: 'Top',
  SymbolType.crux: 'Crux',
  SymbolType.rest: 'Rest',
  SymbolType.disabledHold: 'Off',
};

/// A row with a leading "Route" tool (keyed `symbol-tool-route`) followed by
/// one control per [SymbolType]. The Route tool represents the route-LINE
/// draw action -- [DrawState.activeSymbol] == null -- rather than a new
/// [SymbolType] member (there's deliberately no such member: adding one
/// would ripple into [TopoPainter]/`topo_route.dart`'s symbol-rendering
/// switches for a tool that isn't a placeable symbol at all). It renders
/// SELECTED whenever `activeSymbol == null`, which is also [DrawState]'s
/// default, so a topo freshly switched into draw mode shows Route selected
/// with no explicit wiring needed. Tapping a [SymbolType] control makes it
/// the active symbol (see [DrawController.setActiveSymbol]) and visibly
/// deselects Route; tapping the already-active control clears it (falling
/// back to Route); tapping Route itself calls `setActiveSymbol(null)`
/// directly and re-selects it. Exactly one control is ever selected.
///
/// Bug fix ("the symbol palette buttons are unlabeled and users can't tell
/// what they do"): each control is now icon-over-TEXT-LABEL (in addition to
/// the [Tooltip] it already carried, which only surfaces on long-press and
/// so was easy to miss) — see [_SymbolButton].
///
/// Canvas look rework: this used to be an OPAQUE `ColoredBox` (the app's
/// `surfaceContainerHighest`) laid out IN-FLOW as a reserved band in
/// [TopoCanvasScreen]/`TopoCanvasBody`'s Column, directly above the photo —
/// which both collided visually with the photo's own top edge (an opaque
/// white/light strip butting against the image) and permanently ate into
/// the canvas's available height even in view mode, where it never shows.
/// It now renders on [GlassChrome] (the SAME translucent-blur material the
/// title pill and bottom toolbar cluster use — DESIGN.md "Chrome floats,
/// content is king": "one consistent glass"), and [TopoCanvasScreen] floats
/// it as a Stack overlay directly under the title pill instead of reserving
/// space for it — see that screen's `build` for the floating placement and
/// the removed reserved slot.
class SymbolPaletteBar extends ConsumerWidget {
  const SymbolPaletteBar({super.key, required this.wallId});

  /// FIX #6: family key for [drawControllerProvider] — see that provider's
  /// doc. Always the same wallId as the owning [TopoCanvasScreen].
  final String wallId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final activeSymbol = ref.watch(
      drawControllerProvider(wallId).select((s) => s.activeSymbol),
    );
    final notifier = ref.read(drawControllerProvider(wallId).notifier);
    final colorScheme = Theme.of(context).colorScheme;
    final colors = MasiColors.of(context);

    return GlassChrome(
      child: SizedBox(
        height: kSymbolPaletteBarHeight,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            // The Route tool is FIRST, ahead of every SymbolType control —
            // see the class doc. It has no `SymbolType` of its own, so
            // unlike the loop below it calls `setActiveSymbol(null)`
            // directly on tap (rather than toggling against a `type`) and
            // is marked active by the absence of any active symbol.
            Expanded(
              child: _SymbolButton(
                buttonKey: const Key('symbol-tool-route'),
                iconBuilder: (color, size) =>
                    MasiIcon('route', color: color, size: size),
                label: 'Route',
                isActive: activeSymbol == null,
                colorScheme: colorScheme,
                labelColor: colors.ink2,
                onTap: () => notifier.setActiveSymbol(null),
              ),
            ),
            for (final type in SymbolType.values)
              Expanded(
                child: _SymbolButton(
                  buttonKey: Key('topo-symbol-${type.name}'),
                  iconBuilder: (color, size) =>
                      _symbolIconWidget(type, color: color, size: size),
                  label: _symbolLabels[type] ?? '',
                  isActive: activeSymbol == type,
                  colorScheme: colorScheme,
                  labelColor: colors.ink2,
                  onTap: () => notifier.setActiveSymbol(
                    activeSymbol == type ? null : type,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Shared button shell for both the Route tool and every [SymbolType]
/// control — generalized (rather than keyed strictly off a `SymbolType`) so
/// the Route tool can render through the exact same selected/unselected
/// visuals without needing a `SymbolType` member of its own.
class _SymbolButton extends StatelessWidget {
  const _SymbolButton({
    required this.buttonKey,
    required this.iconBuilder,
    required this.label,
    required this.isActive,
    required this.colorScheme,
    required this.labelColor,
    required this.onTap,
  });

  /// Key applied to the tappable [Material] region, e.g.
  /// `Key('topo-symbol-${type.name}')` or `Key('symbol-tool-route')`.
  final Key buttonKey;

  /// Builds this button's glyph given its resolved active/inactive [color]
  /// and icon [size].
  final Widget Function(Color color, double size) iconBuilder;
  final String label;
  final bool isActive;
  final ColorScheme colorScheme;
  final Color labelColor;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final activeColor = isActive ? colorScheme.primary : colorScheme.onSurfaceVariant;
    return Tooltip(
      message: label,
      child: Material(
        key: buttonKey,
        type: MaterialType.transparency,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(MasiRadii.control),
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 6),
            decoration: BoxDecoration(
              color: isActive ? colorScheme.primaryContainer : null,
              borderRadius: BorderRadius.circular(MasiRadii.control),
            ),
            // Bug fix (RenderFlex overflow at large text-scale factors): the
            // bar's slot height (kSymbolPaletteBarHeight) is deliberately
            // FIXED — see that constant's doc — so it can't grow to
            // accommodate a tripled label line-box at e.g. a 3.0x
            // accessibility text scale, which used to overflow this Column
            // by ~12px. FittedBox(fit: scaleDown) scales the icon+label
            // group down AS A UNIT to fit whatever height is actually
            // available (only ever shrinking, never enlarging — at normal
            // 1.0x scale, where the Column already fits, this is a no-op),
            // which eliminates the overflow at any text scale while keeping
            // the icon and its label legible and proportional to each
            // other, rather than e.g. clamping just the Text's textScaler
            // and leaving the Icon fixed (which would desync their relative
            // sizes at large scales).
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  iconBuilder(activeColor, 22),
                  const SizedBox(height: 2),
                  // Caption/Footnote-sized label per DESIGN.md's type scale —
                  // this is the main "unlabeled symbols" fix: a short,
                  // always-visible name under each glyph rather than relying
                  // solely on the (easy-to-miss, long-press-only) Tooltip.
                  Text(
                    label,
                    style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      color: isActive ? colorScheme.primary : labelColor,
                      fontSize: 11,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
