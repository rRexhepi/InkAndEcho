import 'package:flutter/material.dart';

import '../platform/form_factor.dart';
import '../theme.dart';

/// Primary screen-level action. Mobile renders as a Material FAB anchored
/// bottom-right via the [Scaffold.floatingActionButton] slot. Desktop
/// renders as an inline pill-style button intended to live in the header
/// trailing-actions slot or above the body.
///
/// Use [AppPrimaryAction.scaffoldFloating] when you want the mobile FAB
/// behaviour (returns null on desktop so the [Scaffold] hides the slot).
/// Use [AppPrimaryAction] directly to render inline on either platform.
class AppPrimaryAction extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final bool busy;

  const AppPrimaryAction({
    super.key,
    required this.icon,
    required this.label,
    required this.onPressed,
    this.busy = false,
  });

  /// Returns the platform-appropriate FAB or `null` on desktop. Wire into
  /// `Scaffold(floatingActionButton: AppPrimaryAction.scaffoldFloating(...))`.
  static Widget? scaffoldFloating({
    required IconData icon,
    required String label,
    required VoidCallback? onPressed,
    bool busy = false,
  }) {
    if (!isMobile) return null;
    return _MobileFab(
      icon: icon, label: label, onPressed: onPressed, busy: busy);
  }

  @override
  Widget build(BuildContext context) {
    return isMobile
        ? _MobileFab(
            icon: icon, label: label, onPressed: onPressed, busy: busy)
        : _DesktopButton(
            icon: icon, label: label, onPressed: onPressed, busy: busy);
  }
}

class _MobileFab extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final bool busy;
  const _MobileFab({
    required this.icon,
    required this.label,
    required this.onPressed,
    required this.busy,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return FloatingActionButton.extended(
      onPressed: busy ? null : onPressed,
      backgroundColor: colors.accent,
      foregroundColor: colors.onAccent,
      icon: busy
          ? SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                valueColor: AlwaysStoppedAnimation(colors.onAccent),
              ),
            )
          : Icon(icon),
      label: Text(label),
    );
  }
}

class _DesktopButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final bool busy;
  const _DesktopButton({
    required this.icon,
    required this.label,
    required this.onPressed,
    required this.busy,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Material(
      color: colors.accent,
      borderRadius: BorderRadius.circular(6),
      child: InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: busy ? null : onPressed,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              busy
                  ? SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        valueColor: AlwaysStoppedAnimation(colors.onAccent),
                      ),
                    )
                  : Icon(icon, size: 16, color: colors.onAccent),
              const SizedBox(width: 8),
              Text(
                label,
                style: TextStyle(
                  color: colors.onAccent,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
