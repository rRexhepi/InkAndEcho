import 'package:flutter/material.dart';

import '../main.dart' show AppThemeChoice;
import '../theme.dart';
import '../widgets/app_header.dart';
import '../widgets/app_list.dart';
import '../widgets/app_scaffold.dart';

class SettingsScreen extends StatelessWidget {
  final AppThemeChoice currentTheme;
  final ValueChanged<AppThemeChoice> onThemeChanged;
  final bool animationsEnabled;
  final ValueChanged<bool> onAnimationsChanged;

  const SettingsScreen({
    super.key,
    required this.currentTheme,
    required this.onThemeChanged,
    required this.animationsEnabled,
    required this.onAnimationsChanged,
  });

  static String _themeLabel(AppThemeChoice c) {
    switch (c) {
      case AppThemeChoice.system:
        return 'Match system';
      case AppThemeChoice.light:
        return 'Light';
      case AppThemeChoice.dark:
        return 'Dark';
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return AppScaffold(
      header: AppHeader(
        title: 'Settings',
        leading: AppHeaderAction(
          icon: Icons.chevron_left,
          onTap: () => Navigator.of(context).pop(),
          tooltip: 'Back',
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          const AppSectionHeader('Appearance'),
          RadioGroup<AppThemeChoice>(
            groupValue: currentTheme,
            onChanged: (v) {
              if (v != null) onThemeChanged(v);
            },
            child: Column(
              children: [
                for (final choice in AppThemeChoice.values)
                  AppListTile(
                    leading: Radio<AppThemeChoice>(
                      value: choice,
                      activeColor: colors.accent,
                    ),
                    title: Text(_themeLabel(choice)),
                    onTap: () => onThemeChanged(choice),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          const AppSectionHeader('Reading'),
          AppSwitchTile(
            title: const Text('Page-turn animations'),
            subtitle: const Text(
                'Curl on tap and arrow keys. Drag always shows the curl.'),
            value: animationsEnabled,
            onChanged: onAnimationsChanged,
          ),
          const SizedBox(height: 8),
          const AppSectionHeader('About'),
          const AppListTile(
            title: Text('Palimpsest'),
            subtitle: Text(
                'Audiobook + ebook sync reader. Cross-platform port from the Apple build.'),
          ),
        ],
      ),
    );
  }
}
