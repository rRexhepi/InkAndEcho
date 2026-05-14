part of 'reader_screen.dart';

/// Persistent left rail used by the desktop reader. Switches between a
/// collapsed icon strip and an expanded sidebar. Mobile does not use this
/// widget — it triggers [showReaderChapterSheet] from the header instead.
class ReaderChapterRail extends StatelessWidget {
  final StoredBook book;
  final AnnotationStore annotations;
  final int currentSegmentIndex;
  final ReaderSidebarTab tab;
  final bool expanded;
  final ValueChanged<ReaderSidebarTab> onTabChange;
  final ValueChanged<ReaderSidebarTab> onTabAndExpand;
  final VoidCallback onCollapse;
  final VoidCallback onExpand;
  final ValueChanged<int> onPickChapter;
  final ValueChanged<Annotation> onJumpToAnnotation;
  final VoidCallback onSettings;
  final VoidCallback onBackToLibrary;

  const ReaderChapterRail({
    super.key,
    required this.book,
    required this.annotations,
    required this.currentSegmentIndex,
    required this.tab,
    required this.expanded,
    required this.onTabChange,
    required this.onTabAndExpand,
    required this.onCollapse,
    required this.onExpand,
    required this.onPickChapter,
    required this.onJumpToAnnotation,
    required this.onSettings,
    required this.onBackToLibrary,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    if (expanded) {
      return _ExpandedSidebar(
        book: book,
        annotations: annotations,
        currentSegmentIndex: currentSegmentIndex,
        tab: tab,
        onTab: onTabChange,
        onPickChapter: onPickChapter,
        onJumpToAnnotation: onJumpToAnnotation,
        onCollapse: onCollapse,
        colors: colors,
      );
    }
    return _CollapsedRail(
      currentTab: tab,
      onTab: onTabAndExpand,
      onToggleExpand: onExpand,
      onSettings: onSettings,
      onBackToLibrary: onBackToLibrary,
      colors: colors,
    );
  }
}

/// Mobile-only chapter picker. Shows a draggable bottom sheet listing every
/// chapter; the desktop reader exposes the same data via [ReaderChapterRail]
/// instead.
Future<void> showReaderChapterSheet({
  required BuildContext context,
  required StoredBook book,
  required AnnotationStore annotations,
  required int currentSegmentIndex,
  required ValueChanged<int> onPickChapter,
}) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    builder: (sheet) => _ChapterDrawer(
      book: book,
      annotations: annotations,
      currentSegmentIndex: currentSegmentIndex,
      onPickChapter: (i) {
        Navigator.of(sheet).pop();
        onPickChapter(i);
      },
    ),
  );
}
enum ReaderSidebarTab { chapters, bookmarks, notes }

class _ChapterDrawer extends StatelessWidget {
  final StoredBook book;
  final AnnotationStore annotations;
  final int currentSegmentIndex;
  final ValueChanged<int> onPickChapter;

  const _ChapterDrawer({
    required this.book,
    required this.annotations,
    required this.currentSegmentIndex,
    required this.onPickChapter,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return DraggableScrollableSheet(
      initialChildSize: 0.65,
      minChildSize: 0.35,
      maxChildSize: 0.92,
      expand: false,
      builder: (_, scroll) => Container(
        decoration: BoxDecoration(
          color: colors.canvas,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
        ),
        child: Column(
          children: [
            const SizedBox(height: 8),
            Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: colors.hairlineStrong,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 6),
              child: Row(
                children: [
                  Text('CHAPTERS',
                      style: TextStyle(
                          color: colors.inkMuted,
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 1.5)),
                  const Spacer(),
                  Text('${book.segments.length}',
                      style: TextStyle(
                          color: colors.inkMuted,
                          fontSize: 11,
                          fontFamilyFallback: const [
                            'JetBrains Mono',
                            'Cascadia Code',
                            'Roboto Mono',
                            'monospace',
                          ])),
                ],
              ),
            ),
            Expanded(
              child: ListView.separated(
                controller: scroll,
                itemCount: book.segments.length,
                separatorBuilder: (_, _) =>
                    Divider(height: 1, color: colors.hairline),
                itemBuilder: (_, i) {
                  final s = book.segments[i];
                  final selected = i == currentSegmentIndex;
                  final title =
                      s.title?.trim().isNotEmpty == true ? s.title!.trim() : 'Section ${i + 1}';
                  return Material(
                    color: selected ? colors.canvasCool : Colors.transparent,
                    child: InkWell(
                      onTap: () => onPickChapter(i),
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(20, 14, 20, 14),
                        child: Row(
                          children: [
                            if (selected)
                              Container(
                                width: 3,
                                height: 18,
                                decoration: BoxDecoration(
                                  color: colors.accent,
                                  borderRadius: BorderRadius.circular(2),
                                ),
                              )
                            else
                              const SizedBox(width: 3),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                title,
                                style: TextStyle(
                                  color:
                                      selected ? colors.accent : colors.ink,
                                  fontSize: 14,
                                  fontWeight: selected
                                      ? FontWeight.w600
                                      : FontWeight.w400,
                                ),
                              ),
                            ),
                            Text(
                              '${i + 1}',
                              style: TextStyle(
                                color: colors.inkMuted,
                                fontSize: 11,
                                fontFamilyFallback: const [
                                  'JetBrains Mono',
                                  'Cascadia Code',
                                  'Roboto Mono',
                                  'monospace',
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CollapsedRail extends StatelessWidget {
  final ReaderSidebarTab currentTab;
  final ValueChanged<ReaderSidebarTab> onTab;
  final VoidCallback onToggleExpand;
  final VoidCallback onSettings;
  final VoidCallback onBackToLibrary;
  final PalimpsestColors colors;
  const _CollapsedRail({
    required this.currentTab,
    required this.onTab,
    required this.onToggleExpand,
    required this.onSettings,
    required this.onBackToLibrary,
    required this.colors,
  });

  IconData _iconFor(ReaderSidebarTab t) {
    switch (t) {
      case ReaderSidebarTab.chapters:
        return Icons.list;
      case ReaderSidebarTab.bookmarks:
        return Icons.bookmark_outline;
      case ReaderSidebarTab.notes:
        return Icons.text_snippet_outlined;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 64,
      color: colors.canvasCool,
      child: Column(
        children: [
          const SizedBox(height: 14),
          // Top button used to also be "expand sidebar", which made it look
          // identical to the chapters tab beneath. Replaced with a return-
          // to-library affordance so there's a clear way out of the reader
          // on tablet / desktop where the phone's back chevron isn't shown.
          _RailButton(
            icon: CupertinoIcons.chevron_back,
            colors: colors,
            isSelected: false,
            onTap: onBackToLibrary,
          ),
          const SizedBox(height: 14),
          for (final t in ReaderSidebarTab.values)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: _RailButton(
                icon: _iconFor(t),
                colors: colors,
                isSelected: t == currentTab,
                onTap: () => onTab(t),
              ),
            ),
          const Spacer(),
          _RailButton(
            icon: Icons.settings_outlined,
            colors: colors,
            isSelected: false,
            onTap: onSettings,
          ),
          const SizedBox(height: 12),
        ],
      ),
    );
  }
}

class _RailButton extends StatelessWidget {
  final IconData icon;
  final bool isSelected;
  final VoidCallback onTap;
  final PalimpsestColors colors;
  const _RailButton({
    required this.icon,
    required this.isSelected,
    required this.onTap,
    required this.colors,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            color: isSelected
                ? colors.accent.withValues(alpha: 0.14)
                : Colors.transparent,
          ),
          child: Icon(
            icon,
            size: 18,
            color: isSelected ? colors.accent : colors.inkMuted,
          ),
        ),
      ),
    );
  }
}

class _ExpandedSidebar extends StatelessWidget {
  final StoredBook book;
  final AnnotationStore annotations;
  final int currentSegmentIndex;
  final ReaderSidebarTab tab;
  final ValueChanged<ReaderSidebarTab> onTab;
  final ValueChanged<int> onPickChapter;
  final ValueChanged<Annotation> onJumpToAnnotation;
  final VoidCallback onCollapse;
  final PalimpsestColors colors;

  const _ExpandedSidebar({
    required this.book,
    required this.annotations,
    required this.currentSegmentIndex,
    required this.tab,
    required this.onTab,
    required this.onPickChapter,
    required this.onJumpToAnnotation,
    required this.onCollapse,
    required this.colors,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 280,
      color: colors.canvasCool,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 16, 12, 14),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        book.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: colors.ink,
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        book.author,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            color: colors.inkMuted,
                            fontSize: 12,
                            fontStyle: FontStyle.italic),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  onPressed: onCollapse,
                  icon: Icon(Icons.menu_open,
                      size: 18, color: colors.inkMuted),
                ),
              ],
            ),
          ),
          Container(height: 1, color: colors.hairline),
          _SidebarTabBar(
            current: tab,
            onTab: onTab,
            colors: colors,
          ),
          Container(height: 1, color: colors.hairline),
          Expanded(
            child: ListenableBuilder(
              listenable: annotations,
              builder: (_, _) {
                switch (tab) {
                  case ReaderSidebarTab.chapters:
                    return _ChapterList(
                      book: book,
                      currentSegmentIndex: currentSegmentIndex,
                      onPickChapter: onPickChapter,
                      colors: colors,
                    );
                  case ReaderSidebarTab.bookmarks:
                    return _AnnotationList(
                      annotations: annotations.items
                          .where((a) =>
                              a.kind == AnnotationKind.bookmark ||
                              a.kind == AnnotationKind.highlight)
                          .toList(),
                      book: book,
                      onJumpTo: onJumpToAnnotation,
                      colors: colors,
                      emptyLabel:
                          'Long-press a paragraph to bookmark or highlight it.',
                    );
                  case ReaderSidebarTab.notes:
                    return _AnnotationList(
                      annotations: annotations.items
                          .where((a) => a.kind == AnnotationKind.note)
                          .toList(),
                      book: book,
                      onJumpTo: onJumpToAnnotation,
                      colors: colors,
                      emptyLabel: 'Long-press a paragraph to add a note.',
                    );
                }
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _SidebarTabBar extends StatelessWidget {
  final ReaderSidebarTab current;
  final ValueChanged<ReaderSidebarTab> onTab;
  final PalimpsestColors colors;
  const _SidebarTabBar({
    required this.current,
    required this.onTab,
    required this.colors,
  });

  String _labelFor(ReaderSidebarTab t) {
    switch (t) {
      case ReaderSidebarTab.chapters:
        return 'Chapters';
      case ReaderSidebarTab.bookmarks:
        return 'Bookmarks';
      case ReaderSidebarTab.notes:
        return 'Notes';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: Row(
        children: [
          for (final t in ReaderSidebarTab.values)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: GestureDetector(
                onTap: () => onTab(t),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                    color: t == current
                        ? colors.accent.withValues(alpha: 0.14)
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(
                      color: t == current ? colors.accent : colors.hairline,
                    ),
                  ),
                  child: Text(
                    _labelFor(t),
                    style: TextStyle(
                      color: t == current ? colors.accent : colors.inkMuted,
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _ChapterList extends StatelessWidget {
  final StoredBook book;
  final int currentSegmentIndex;
  final ValueChanged<int> onPickChapter;
  final PalimpsestColors colors;
  const _ChapterList({
    required this.book,
    required this.currentSegmentIndex,
    required this.onPickChapter,
    required this.colors,
  });

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 4),
      itemCount: book.segments.length,
      separatorBuilder: (_, _) =>
          Divider(height: 1, color: colors.hairline),
      itemBuilder: (_, i) {
        final s = book.segments[i];
        final selected = i == currentSegmentIndex;
        final title = s.title?.trim().isNotEmpty == true
            ? s.title!.trim()
            : 'Section ${i + 1}';
        return Material(
          color: selected ? colors.canvas : Colors.transparent,
          child: InkWell(
            onTap: () => onPickChapter(i),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(18, 12, 12, 12),
              child: Row(
                children: [
                  Container(
                    width: 3,
                    height: 16,
                    color: selected ? colors.accent : Colors.transparent,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      title,
                      style: TextStyle(
                        color: selected ? colors.accent : colors.ink,
                        fontSize: 13,
                        fontWeight:
                            selected ? FontWeight.w600 : FontWeight.w400,
                      ),
                    ),
                  ),
                  Text(
                    '${i + 1}',
                    style: TextStyle(
                      color: colors.inkMuted,
                      fontSize: 10,
                      fontFamilyFallback: const [
                        'JetBrains Mono',
                        'Cascadia Code',
                        'Roboto Mono',
                        'monospace',
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _AnnotationList extends StatelessWidget {
  final List<Annotation> annotations;
  final StoredBook book;
  final ValueChanged<Annotation> onJumpTo;
  final String emptyLabel;
  final PalimpsestColors colors;
  const _AnnotationList({
    required this.annotations,
    required this.book,
    required this.onJumpTo,
    required this.emptyLabel,
    required this.colors,
  });

  @override
  Widget build(BuildContext context) {
    if (annotations.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Text(
            emptyLabel,
            textAlign: TextAlign.center,
            style: TextStyle(color: colors.inkMuted, fontSize: 12),
          ),
        ),
      );
    }
    final sorted = [...annotations]
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 4),
      itemCount: sorted.length,
      separatorBuilder: (_, _) =>
          Divider(height: 1, color: colors.hairline),
      itemBuilder: (_, i) {
        final a = sorted[i];
        final segTitle = book.segments
                .firstWhere((s) => s.id == a.segmentId,
                    orElse: () => book.segments.first)
                .title ??
            'Section';
        return InkWell(
          onTap: () => onJumpTo(a),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 10, 12, 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  segTitle.toUpperCase(),
                  style: TextStyle(
                    color: colors.inkMuted,
                    fontSize: 9,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 1.2,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  a.quote,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: colors.ink, fontSize: 12),
                ),
                if (a.note?.isNotEmpty == true) ...[
                  const SizedBox(height: 4),
                  Text(
                    a.note!,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: colors.inkSoft,
                      fontSize: 11,
                      fontStyle: FontStyle.italic,
                    ),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}


