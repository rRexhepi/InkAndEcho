import 'package:flutter/material.dart';

import '../platform/form_factor.dart';
import '../theme.dart';

/// One menu entry shown by [AppContextMenu].
class AppContextMenuItem<T> {
  final T value;
  final IconData icon;
  final String label;
  final Color? color;
  const AppContextMenuItem({
    required this.value,
    required this.icon,
    required this.label,
    this.color,
  });
}

/// Adaptive context-menu wrapper.
///
/// Wraps [child] with the right gestures for the current platform:
/// - Mobile: long-press opens a bottom sheet menu.
/// - Desktop: secondary tap (right-click) opens a popup menu near the cursor.
///   Long-press on desktop is also forwarded for parity with touch laptops.
///
/// Selection is delivered via [onSelected]. Returns the parent's child
/// untouched when [items] is empty so the wrapper is safe to leave in place
/// while menus are computed lazily.
class AppContextMenu<T> extends StatelessWidget {
  final Widget child;
  final List<AppContextMenuItem<T>> items;
  final ValueChanged<T> onSelected;
  final VoidCallback? onPrimaryTap;

  const AppContextMenu({
    super.key,
    required this.child,
    required this.items,
    required this.onSelected,
    this.onPrimaryTap,
  });

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return child;
    if (isMobile) {
      return InkWell(
        onTap: onPrimaryTap,
        onLongPress: () => _openMobileSheet(context),
        child: child,
      );
    }
    return InkWell(
      onTap: onPrimaryTap,
      onLongPress: () => _openMobileSheet(context),
      onSecondaryTapDown: (d) => _openDesktopPopup(context, d.globalPosition),
      child: child,
    );
  }

  Future<void> _openMobileSheet(BuildContext context) async {
    final colors = context.colors;
    final picked = await showModalBottomSheet<T>(
      context: context,
      backgroundColor: colors.canvas,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (sheet) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 36,
              height: 4,
              margin: const EdgeInsets.symmetric(vertical: 10),
              decoration: BoxDecoration(
                color: colors.hairlineStrong,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            for (final it in items)
              ListTile(
                leading: Icon(it.icon, color: it.color ?? colors.inkSoft),
                title: Text(
                  it.label,
                  style: TextStyle(color: it.color ?? colors.ink),
                ),
                onTap: () => Navigator.of(sheet).pop(it.value),
              ),
          ],
        ),
      ),
    );
    if (picked != null) onSelected(picked);
  }

  Future<void> _openDesktopPopup(
      BuildContext context, Offset globalPosition) async {
    final colors = context.colors;
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox;
    final picked = await showMenu<T>(
      context: context,
      color: colors.canvas,
      position: RelativeRect.fromRect(
        Rect.fromLTWH(globalPosition.dx, globalPosition.dy, 0, 0),
        Offset.zero & overlay.size,
      ),
      items: [
        for (final it in items)
          PopupMenuItem<T>(
            value: it.value,
            child: Row(
              children: [
                Icon(it.icon,
                    size: 18, color: it.color ?? colors.inkSoft),
                const SizedBox(width: 10),
                Text(it.label,
                    style: TextStyle(color: it.color ?? colors.ink)),
              ],
            ),
          ),
      ],
    );
    if (picked != null) onSelected(picked);
  }
}
