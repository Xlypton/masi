import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

/// Renders one of the app's `assets/icons/masi/masi_<name>.svg` glyphs.
///
/// By default ([tinted] `true`, unchanged from before this doc was added)
/// every existing call site keeps rendering as a single-tone glyph: the SVG
/// is flattened with a `BlendMode.srcIn` [ColorFilter] to [color] (or the
/// ambient [IconTheme]'s color, or [ColorScheme.onSurface] as a last
/// resort) — this is correct for the vast majority of icons in
/// `assets/icons/masi/`, which are intentionally single-color glyphs meant
/// to pick up whatever color the call site wants.
///
/// Pass `tinted: false` for the rare FULL-COLOR/multi-tone asset (currently
/// just `boulder_logo`) that must render in its own natural colors instead
/// — no [ColorFilter] is applied in that case, so [color] is ignored
/// entirely. This is purely additive: the default path (`tinted` omitted or
/// `true`) is byte-for-byte the same tinted `SvgPicture.asset` call as
/// before, so every pre-existing `MasiIcon(...)` call site is unaffected.
class MasiIcon extends StatelessWidget {
  const MasiIcon(this.name, {super.key, this.size, this.color, this.tinted = true});
  final String name;
  final double? size;
  final Color? color;

  /// When `true` (the default), the SVG is flattened to a single tone via a
  /// `BlendMode.srcIn` [ColorFilter]. When `false`, the SVG renders
  /// UN-TINTED in its own natural colors and [color] is ignored — for
  /// full-color/multi-tone assets like `boulder_logo`.
  final bool tinted;

  @override
  Widget build(BuildContext context) {
    final theme = IconTheme.of(context);
    final s = size ?? theme.size ?? 24;
    if (!tinted) {
      return SvgPicture.asset(
        'assets/icons/masi/masi_$name.svg',
        width: s,
        height: s,
      );
    }
    final c = color ?? theme.color ?? Theme.of(context).colorScheme.onSurface;
    return SvgPicture.asset(
      'assets/icons/masi/masi_$name.svg',
      width: s,
      height: s,
      colorFilter: ColorFilter.mode(c, BlendMode.srcIn),
    );
  }
}
