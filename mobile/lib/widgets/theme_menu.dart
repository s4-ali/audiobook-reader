import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/theme_controller.dart';
import '../theme.dart';

/// App-bar action that swaps the reader theme (Dark / Sepia / Light), mirroring the web
/// player's Display menu. Shows the active theme's icon; the menu marks the current choice.
class ThemeMenuButton extends StatelessWidget {
  const ThemeMenuButton({super.key});

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<ThemeController>();
    final current = themeChoices.firstWhere(
      (c) => c.id == controller.id,
      orElse: () => themeChoices.first,
    );
    return PopupMenuButton<String>(
      icon: Icon(current.icon),
      tooltip: 'Theme',
      onSelected: controller.select,
      itemBuilder: (_) => [
        for (final choice in themeChoices)
          PopupMenuItem<String>(
            value: choice.id,
            child: Row(
              children: [
                Icon(choice.icon, size: 20),
                const SizedBox(width: 12),
                Text(choice.label),
                const Spacer(),
                if (choice.id == controller.id)
                  Icon(Icons.check, size: 18, color: AppPalette.of(context).accent),
              ],
            ),
          ),
      ],
    );
  }
}
