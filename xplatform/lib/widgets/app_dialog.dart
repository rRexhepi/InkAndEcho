import 'package:flutter/material.dart';

import '../platform/form_factor.dart';
import '../theme.dart';

/// Adaptive confirmation prompt. Returns `true` if the user accepted,
/// `false` (or `null`) on cancel/dismiss.
///
/// Mobile: modal bottom sheet (matches Material/iOS conventions for
/// destructive confirms on touch devices).
/// Desktop: standard dialog with Cancel/Confirm buttons.
Future<bool> showAppConfirmDialog({
  required BuildContext context,
  required String title,
  required String message,
  String cancelLabel = 'Cancel',
  String confirmLabel = 'Confirm',
  bool destructive = false,
}) async {
  final colors = context.colors;
  final accent = destructive ? Colors.redAccent : colors.accent;

  if (isMobile) {
    final result = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: colors.canvas,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (sheet) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                width: 36,
                height: 4,
                margin: const EdgeInsets.only(bottom: 14),
                decoration: BoxDecoration(
                  color: colors.hairlineStrong,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              Text(
                title,
                style: TextStyle(
                  color: colors.ink,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
              Text(message, style: TextStyle(color: colors.inkSoft)),
              const SizedBox(height: 20),
              Row(
                children: [
                  Expanded(
                    child: TextButton(
                      onPressed: () => Navigator.of(sheet).pop(false),
                      child: Text(cancelLabel,
                          style: TextStyle(color: colors.inkSoft)),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextButton(
                      onPressed: () => Navigator.of(sheet).pop(true),
                      child: Text(confirmLabel,
                          style: TextStyle(color: accent)),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    return result == true;
  }

  final result = await showDialog<bool>(
    context: context,
    builder: (dialog) => AlertDialog(
      backgroundColor: colors.canvas,
      title: Text(title,
          style: TextStyle(color: colors.ink, fontSize: 16)),
      content: Text(message, style: TextStyle(color: colors.inkSoft)),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialog).pop(false),
          child:
              Text(cancelLabel, style: TextStyle(color: colors.inkSoft)),
        ),
        TextButton(
          onPressed: () => Navigator.of(dialog).pop(true),
          child: Text(confirmLabel, style: TextStyle(color: accent)),
        ),
      ],
    ),
  );
  return result == true;
}
