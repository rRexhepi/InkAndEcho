import 'package:flutter/material.dart';

import '../platform/form_factor.dart';
import '../theme.dart';

/// Adaptive top header used by every screen.
///
/// Mobile: 44pt iOS-style strip with circular icon buttons.
/// Desktop: Material AppBar with denser chrome and explicit action buttons.
///
/// Both variants honour `leading` (typically a back arrow), `actions`
/// (right-side icons), and `title`.
class AppHeader extends StatelessWidget implements PreferredSizeWidget {
  final String title;
  final AppHeaderAction? leading;
  final List<AppHeaderAction> actions;

  const AppHeader({
    super.key,
    required this.title,
    this.leading,
    this.actions = const [],
  });

  @override
  Size get preferredSize => Size.fromHeight(isMobile ? 44 : kToolbarHeight);

  @override
  Widget build(BuildContext context) {
    return isMobile
        ? _MobileHeader(title: title, leading: leading, actions: actions)
        : _DesktopHeader(title: title, leading: leading, actions: actions);
  }
}

class AppHeaderAction {
  final IconData icon;
  final VoidCallback onTap;
  final String? tooltip;
  const AppHeaderAction({
    required this.icon,
    required this.onTap,
    this.tooltip,
  });
}

class _MobileHeader extends StatelessWidget {
  final String title;
  final AppHeaderAction? leading;
  final List<AppHeaderAction> actions;
  const _MobileHeader({
    required this.title,
    required this.leading,
    required this.actions,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Material(
      color: colors.canvas,
      child: SizedBox(
        height: 44,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Row(
            children: [
              if (leading != null)
                _CircleIcon(action: leading!, colors: colors),
              Expanded(
                child: Text(
                  title,
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: colors.ink,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              for (final a in actions) _CircleIcon(action: a, colors: colors),
              if (actions.isEmpty) const SizedBox(width: 36),
            ],
          ),
        ),
      ),
    );
  }
}

class _DesktopHeader extends StatelessWidget implements PreferredSizeWidget {
  final String title;
  final AppHeaderAction? leading;
  final List<AppHeaderAction> actions;
  const _DesktopHeader({
    required this.title,
    required this.leading,
    required this.actions,
  });

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return AppBar(
      title: Text(title),
      backgroundColor: colors.canvas,
      leading: leading == null
          ? null
          : IconButton(
              icon: Icon(leading!.icon),
              tooltip: leading!.tooltip,
              onPressed: leading!.onTap,
            ),
      actions: [
        for (final a in actions)
          IconButton(
            icon: Icon(a.icon),
            tooltip: a.tooltip,
            onPressed: a.onTap,
          ),
      ],
    );
  }
}

class _CircleIcon extends StatelessWidget {
  final AppHeaderAction action;
  final PalimpsestColors colors;
  const _CircleIcon({required this.action, required this.colors});

  @override
  Widget build(BuildContext context) {
    final btn = Material(
      color: Colors.transparent,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: action.onTap,
        child: Container(
          width: 36,
          height: 36,
          alignment: Alignment.center,
          child: Icon(action.icon, size: 18, color: colors.inkSoft),
        ),
      ),
    );
    return action.tooltip == null
        ? btn
        : Tooltip(message: action.tooltip!, child: btn);
  }
}
