import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:masi/app/theme.dart';
import 'package:masi/features/topo/application/draw_controller.dart';
import 'package:masi/features/topo/domain/topo_route.dart';
import 'package:masi/features/topo/presentation/canvas_chrome.dart';
import 'package:masi/shared/presentation/masi_icon.dart';

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
/// with a dismiss/cancel action. [SymbolType.anchor]/[SymbolType.top]/
/// [SymbolType.crux] use their own Masi equivalents.
///
/// [SymbolType.disabledHold] (feature #43, per-route excluded hold) uses
/// `MasiIcon('ban')`. It used to borrow `MasiIcon('close')` because the brand
/// set had no "off/no/ban" glyph — so the palette advertised an X while the
/// marker it placed was a prohibition sign, and the tool did not look like
/// what it drew (user report, 2026-08-11: "the off drawing too should have
/// the same banned sign as on the drawing"). `masi_ban.svg` was added for
/// this: a stroked circle with one NW->SE diagonal slash, the same geometry
/// `TopoPainter._paintSymbol` hand-draws for this marker (radius 8 and a
/// slash at 0.707r in a 24x24 box), so the palette and the canvas now show
/// one symbol.
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
    case SymbolType.disabledHold:
      return MasiIcon('ban', color: color, size: size);
  }
}

/// Tooltip/label used for each [SymbolType] control in [SymbolPaletteBar].
const Map<SymbolType, String> _symbolLabels = {
  SymbolType.anchor: 'Anchor',
  SymbolType.bolt: 'Bolt',
  SymbolType.top: 'Top',
  SymbolType.crux: 'Crux',
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
/// so was easy to miss) — see [_SymbolButton]. Past
/// [_kSymbolLabelMaxTextScale] that label is dropped again and the
/// [Tooltip] carries the meaning alone, so that a LARGER accessibility text
/// scale never makes the glyphs themselves smaller — see that constant.
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

/// Font size of a control's text label — Caption/Footnote-sized per
/// DESIGN.md's type scale. Named (rather than a bare `11` on the [TextStyle])
/// because [_SymbolButton] also has to ASK the ambient [TextScaler] what it
/// would do to this exact size, see [_kSymbolLabelMaxTextScale].
const double _kSymbolLabelFontSize = 11;

/// Effective text scale past which each control's text label is DROPPED
/// entirely, leaving the glyph alone under the [Tooltip] every control
/// already carries (and which, being a `Tooltip`, is also what supplies the
/// control's accessibility label — so nothing is lost to a screen reader
/// when the visible label goes away).
///
/// Bug fix (accessibility inversion): the icon+label group used to be
/// wrapped as a UNIT in `FittedBox(fit: scaleDown)` to keep it inside the
/// bar's deliberately fixed [kSymbolPaletteBarHeight] slot at large
/// accessibility text scales. That worked, but backwards: the binding
/// constraint is the button's WIDTH (six controls share the bar's width, so
/// each gets ~a sixth of it), a bigger label is a wider label, and
/// `scaleDown` shrinks *everything it wraps* — so raising the system text
/// size made the CANVAS TOOL GLYPHS smaller (measured: 22px at 1.0x →
/// 21.2px at 2.0x → 14.3px at 3.0x), i.e. the accessibility setting made
/// the core editing surface harder to see and to hit. Now only the label is
/// inside a `FittedBox` (so a long label still shrinks to fit its column
/// rather than ellipsizing, exactly as before), the glyph is a fixed-size
/// sibling OUTSIDE it, and past this scale the label — the thing that
/// actually doesn't fit — is what gives way.
///
/// Why 1.3 specifically: it's the largest scale at which a worst-case label
/// ("Anchor") still fits one control's share of the bar on the narrowest
/// phone we target (~320pt wide → (320 − 32 screen padding − 16 glass
/// padding) / 6 ≈ 45pt per control), and it leaves the fixed-height slot
/// comfortable too (6 + 22 + 2 + a 1.3x label line + 6 ≈ 55 of the 68px
/// available). Below it nothing changes at all; at 1.0x this whole branch
/// is inert and the bar renders exactly as it always has.
const double _kSymbolLabelMaxTextScale = 1.3;

/// Minimum height of a control's tappable/highlighted region.
///
/// Inert at normal text scale — with its label showing, a control is
/// naturally ~51px tall — but once the label is dropped (see
/// [_kSymbolLabelMaxTextScale]) the glyph plus its 6px vertical padding
/// alone would collapse the tap target to ~34px, under the 44pt minimum.
/// The user turning text size UP is the last user who should get a smaller
/// target, so the shell holds this floor instead.
const double _kSymbolButtonMinHeight = 44;

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
    // Ask the ambient scaler what it would ACTUALLY do to this label's font
    // size rather than reading a scale *factor* off it: the platform text
    // scalers are non-linear (a 11pt caption and a 34pt headline are not
    // multiplied by the same number), and `TextScaler` deliberately exposes
    // no factor, so `scale(size)` on the size we actually use is the only
    // honest way to ask "how much bigger is THIS text about to get".
    final scaledLabelFontSize = MediaQuery.textScalerOf(
      context,
    ).scale(_kSymbolLabelFontSize);
    final showLabel =
        scaledLabelFontSize <=
        _kSymbolLabelFontSize * _kSymbolLabelMaxTextScale;
    return Tooltip(
      message: label,
      child: Material(
        key: buttonKey,
        type: MaterialType.transparency,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(MasiRadii.control),
          child: Container(
            // See [_kSymbolButtonMinHeight]: a no-op while the label shows,
            // a 44pt tap-target floor once it's dropped.
            constraints: const BoxConstraints(
              minHeight: _kSymbolButtonMinHeight,
            ),
            padding: const EdgeInsets.symmetric(vertical: 6),
            decoration: BoxDecoration(
              color: isActive ? colorScheme.primaryContainer : null,
              borderRadius: BorderRadius.circular(MasiRadii.control),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              // Only ever bites when the min-height floor above stretches
              // this Column past its intrinsic height (i.e. label dropped);
              // at its natural size, centering and packing are identical.
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // Fixed size, and deliberately OUTSIDE the label's FittedBox
                // — the glyph must never shrink as text scale grows. See
                // [_kSymbolLabelMaxTextScale] for the bug this fixes.
                iconBuilder(activeColor, 22),
                if (showLabel) ...[
                  const SizedBox(height: 2),
                  // Caption/Footnote-sized label per DESIGN.md's type scale —
                  // this is the main "unlabeled symbols" fix: a short,
                  // always-visible name under each glyph rather than relying
                  // solely on the (easy-to-miss, long-press-only) Tooltip.
                  //
                  // The FittedBox wraps ONLY this label: six controls share
                  // the bar's width, so on a narrow phone a scaled-up label
                  // can outgrow its column, and shrinking it to fit is both
                  // what this bar has always done and kinder than an
                  // ellipsis on a 4–6 character word. `scaleDown` never
                  // enlarges, so at 1.0x, where the label already fits, it
                  // is a no-op and this renders exactly as it always has.
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      label,
                      style: Theme.of(context).textTheme.labelMedium?.copyWith(
                        color: isActive ? colorScheme.primary : labelColor,
                        fontSize: _kSymbolLabelFontSize,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
