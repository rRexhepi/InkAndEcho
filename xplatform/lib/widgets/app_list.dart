import 'package:flutter/material.dart';

import '../platform/form_factor.dart';
import '../theme.dart';

/// Uppercase muted section header. Identical on both platforms,
/// here so screens never re-write the same TextStyle.
class AppSectionHeader extends StatelessWidget {
  final String label;
  const AppSectionHeader(this.label, {super.key});

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 6),
      child: Text(
        label.toUpperCase(),
        style: TextStyle(
          color: colors.inkMuted,
          fontSize: 11,
          fontWeight: FontWeight.w600,
          letterSpacing: 1.5,
        ),
      ),
    );
  }
}

/// Adaptive list tile. Mobile uses standard touch-target padding,
/// desktop is denser to match macOS/Windows list conventions.
class AppListTile extends StatelessWidget {
  final Widget? leading;
  final Widget title;
  final Widget? subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;
  final Color? selectedColor;
  final bool selected;

  const AppListTile({
    super.key,
    this.leading,
    required this.title,
    this.subtitle,
    this.trailing,
    this.onTap,
    this.selectedColor,
    this.selected = false,
  });

  @override
  Widget build(BuildContext context) {
    final padding = isMobile
        ? const EdgeInsets.symmetric(horizontal: 16, vertical: 12)
        : const EdgeInsets.symmetric(horizontal: 16, vertical: 8);
    return Material(
      color: selected
          ? (selectedColor ?? context.colors.canvasCool)
          : Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: padding,
          child: Row(
            children: [
              if (leading != null) ...[
                leading!,
                const SizedBox(width: 14),
              ],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    DefaultTextStyle.merge(
                      style: TextStyle(
                        color: context.colors.ink,
                        fontSize: 14,
                      ),
                      child: title,
                    ),
                    if (subtitle != null) ...[
                      const SizedBox(height: 2),
                      DefaultTextStyle.merge(
                        style: TextStyle(
                          color: context.colors.inkMuted,
                          fontSize: 12,
                        ),
                        child: subtitle!,
                      ),
                    ],
                  ],
                ),
              ),
              if (trailing != null) ...[
                const SizedBox(width: 12),
                trailing!,
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Switch row paired with title/subtitle. Uses [AppListTile] for layout
/// so platform density is consistent.
class AppSwitchTile extends StatelessWidget {
  final Widget title;
  final Widget? subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  const AppSwitchTile({
    super.key,
    required this.title,
    required this.value,
    required this.onChanged,
    this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    return AppListTile(
      title: title,
      subtitle: subtitle,
      onTap: () => onChanged(!value),
      trailing: Switch(
        value: value,
        activeThumbColor: context.colors.accent,
        onChanged: onChanged,
      ),
    );
  }
}
