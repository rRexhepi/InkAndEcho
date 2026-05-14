import 'package:flutter/material.dart';

import '../platform/form_factor.dart';
import '../theme.dart';
import 'app_header.dart';

/// Top-level page chrome. Wires [header], [body], optional [primaryAction]
/// (rendered as a FAB on mobile, inline header trailing slot on desktop),
/// and an optional [bottomBar] (only painted on mobile, ignored on desktop).
class AppScaffold extends StatelessWidget {
  final AppHeader header;
  final Widget body;
  final Widget? primaryAction;
  final Widget? bottomBar;

  const AppScaffold({
    super.key,
    required this.header,
    required this.body,
    this.primaryAction,
    this.bottomBar,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    if (isMobile) {
      return Scaffold(
        backgroundColor: colors.canvas,
        appBar: header,
        body: body,
        floatingActionButton: primaryAction,
        bottomNavigationBar: bottomBar,
      );
    }
    return Scaffold(
      backgroundColor: colors.canvas,
      appBar: header,
      body: Column(
        children: [
          if (primaryAction != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Align(
                alignment: Alignment.centerRight,
                child: primaryAction!,
              ),
            ),
          Expanded(child: body),
        ],
      ),
    );
  }
}
