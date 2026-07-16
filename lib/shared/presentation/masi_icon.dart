import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

class MasiIcon extends StatelessWidget {
  const MasiIcon(this.name, {super.key, this.size, this.color});
  final String name;
  final double? size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final theme = IconTheme.of(context);
    final c = color ?? theme.color ?? Theme.of(context).colorScheme.onSurface;
    final s = size ?? theme.size ?? 24;
    return SvgPicture.asset(
      'assets/icons/masi/masi_$name.svg',
      width: s,
      height: s,
      colorFilter: ColorFilter.mode(c, BlendMode.srcIn),
    );
  }
}
