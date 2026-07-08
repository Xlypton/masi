import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:climbtopo/features/topo/application/draw_controller.dart';
import 'package:climbtopo/features/topo/domain/topo_route.dart';

/// Icon used for each [SymbolType] control in [SymbolPaletteBar].
const Map<SymbolType, IconData> _symbolIcons = {
  SymbolType.anchor: Icons.anchor,
  SymbolType.bolt: Icons.close,
  SymbolType.top: Icons.change_history,
  SymbolType.crux: Icons.star,
  SymbolType.rest: Icons.pause_circle_outline,
};

/// Tooltip/label used for each [SymbolType] control in [SymbolPaletteBar].
const Map<SymbolType, String> _symbolLabels = {
  SymbolType.anchor: 'Anchor',
  SymbolType.bolt: 'Bolt',
  SymbolType.top: 'Top',
  SymbolType.crux: 'Crux',
  SymbolType.rest: 'Rest',
};

/// A row of one control per [SymbolType]. Tapping a control makes it the
/// [DrawState.activeSymbol] (see [DrawController.setActiveSymbol]) so the
/// next tap on the topo canvas places that symbol on the currently selected
/// route; tapping the already-active control clears the active symbol.
class SymbolPaletteBar extends ConsumerWidget {
  const SymbolPaletteBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final activeSymbol = ref.watch(
      drawControllerProvider.select((s) => s.activeSymbol),
    );
    final notifier = ref.read(drawControllerProvider.notifier);
    final colorScheme = Theme.of(context).colorScheme;

    return ColoredBox(
      color: colorScheme.surfaceContainerHighest,
      child: SizedBox(
        height: 56,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            for (final type in SymbolType.values)
              _SymbolButton(
                type: type,
                isActive: activeSymbol == type,
                colorScheme: colorScheme,
                onTap: () => notifier.setActiveSymbol(
                  activeSymbol == type ? null : type,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _SymbolButton extends StatelessWidget {
  const _SymbolButton({
    required this.type,
    required this.isActive,
    required this.colorScheme,
    required this.onTap,
  });

  final SymbolType type;
  final bool isActive;
  final ColorScheme colorScheme;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      key: Key('topo-symbol-${type.name}'),
      onPressed: onTap,
      tooltip: _symbolLabels[type],
      icon: Icon(_symbolIcons[type]),
      color: isActive ? colorScheme.primary : colorScheme.onSurfaceVariant,
      style: IconButton.styleFrom(
        backgroundColor: isActive ? colorScheme.primaryContainer : null,
      ),
    );
  }
}
