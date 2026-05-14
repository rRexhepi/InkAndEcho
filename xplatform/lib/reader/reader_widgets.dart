// part-of header
part of 'reader_screen.dart';

class _PageView extends StatelessWidget {
  final ReaderPage page;
  final int pageIdx;
  final String chapterLabel;
  final AnnotationStore annotations;
  final String segmentId;
  final void Function(int pIndexInPage, String text, Offset globalPos)
      onParagraphLongPress;
  final void Function(int pIndexInPage, String text, int start, int end,
      _ParaActionType type)? onSelectionAction;

  const _PageView({
    required this.page,
    required this.pageIdx,
    required this.chapterLabel,
    required this.annotations,
    required this.segmentId,
    required this.onParagraphLongPress,
    this.onSelectionAction,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return ListenableBuilder(
      listenable: annotations,
      builder: (_, _) => Padding(
        padding: _kPagePadding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Chapter kicker — uppercase muted, 1.5 letter-spacing, matches
            // iOS `chapterHeader`. Only on the first page of a chapter.
            if (pageIdx == 0)
              Padding(
                padding: const EdgeInsets.only(bottom: 18),
                child: Text(
                  chapterLabel.toUpperCase(),
                  style: TextStyle(
                    color: colors.inkMuted,
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 1.5,
                  ),
                ),
              ),
            Expanded(
              // Pagination is by word count (170/page) and doesn't measure
              // rendered height, so a small / unmaximized window can let
              // a page overflow vertically. ClampingScrollPhysics lets the
              // user scroll only the overflowing tail; pages that fit
              // stay non-scrollable.
              child: SingleChildScrollView(
                physics: const ClampingScrollPhysics(),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (var i = 0; i < page.paragraphs.length; i++)
                      _ParagraphRow(
                        text: page.paragraphs[i],
                        isContinuationStart:
                            i == 0 && page.startsContinuation,
                        isContinuationEnd:
                            i == page.paragraphs.length - 1 &&
                                page.endsContinuation,
                        marks: _marksForParagraphInPage(i),
                        colors: colors,
                        onMenu: (globalPos) => onParagraphLongPress(
                            i, page.paragraphs[i], globalPos),
                        onSelectionAction: (type, start, end, quote) =>
                            onSelectionAction?.call(
                                i, page.paragraphs[i], start, end, type),
                      ),
                  ],
                ),
              ),
            ),
            // In-card page number footer, mono, centered. Matches iOS
            // `pageSurface` trailing `Text("\(pageIndex + 1)")`.
            Padding(
              padding: const EdgeInsets.only(top: 8, bottom: 4),
              child: Center(
                child: Text(
                  '${pageIdx + 1}',
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
              ),
            ),
          ],
        ),
      ),
    );
  }

  List<Annotation> _marksForParagraphInPage(int idx) {
    // We do NOT have the absolute paragraph index here — we only show
    // pertinent visual hints. The on-tap callback computes the absolute
    // index by re-walking pages on the parent state.
    return annotations
        .forSegment(segmentId)
        .where((a) =>
            page.paragraphs.length > idx &&
            (a.quote.startsWith(page.paragraphs[idx].substring(
                    0,
                    page.paragraphs[idx].length > 40
                        ? 40
                        : page.paragraphs[idx].length)) ||
                page.paragraphs[idx].startsWith(a.quote.substring(
                    0, a.quote.length > 40 ? 40 : a.quote.length))))
        .toList();
  }
}

class _ParagraphRow extends StatelessWidget {
  final String text;
  final bool isContinuationStart;
  final bool isContinuationEnd;
  final List<Annotation> marks;
  final PalimpsestColors colors;
  final ValueChanged<Offset> onMenu;
  final void Function(_ParaActionType type, int start, int end, String quote)?
      onSelectionAction;

  const _ParagraphRow({
    required this.text,
    required this.isContinuationStart,
    required this.isContinuationEnd,
    required this.marks,
    required this.colors,
    required this.onMenu,
    this.onSelectionAction,
  });

  @override
  Widget build(BuildContext context) {
    final wholeHighlight = marks
        .where((a) => a.kind == AnnotationKind.highlight && !a.isRange)
        .firstOrNull;
    final rangeHighlights = marks
        .where((a) => a.kind == AnnotationKind.highlight && a.isRange)
        .toList();
    final hasBookmark =
        marks.any((a) => a.kind == AnnotationKind.bookmark);
    final note = marks
        .where((a) => a.kind == AnnotationKind.note && a.note?.isNotEmpty == true)
        .firstOrNull;

    final baseStyle = TextStyle(
      color: colors.ink,
      fontSize: _kBodyFontSize,
      height: _kBodyLineHeight,
    );

    Widget paragraphText = SelectableText.rich(
      TextSpan(children: _composeSpans(text, rangeHighlights, baseStyle)),
      style: baseStyle,
      contextMenuBuilder: (ctx, state) =>
          _buildSelectionMenu(ctx, state, text),
    );

    if (wholeHighlight != null) {
      paragraphText = Container(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        decoration: BoxDecoration(
          color: wholeHighlight.color.fill,
          borderRadius: BorderRadius.circular(2),
        ),
        child: paragraphText,
      );
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (hasBookmark)
            Padding(
              padding: const EdgeInsets.only(top: 5, right: 6),
              child: Icon(Icons.bookmark, size: 12, color: colors.accent),
            ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                paragraphText,
                if (note != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Container(
                      padding: const EdgeInsets.fromLTRB(10, 6, 10, 8),
                      decoration: BoxDecoration(
                        color: colors.canvasCool,
                        borderRadius: BorderRadius.circular(4),
                        border: Border(
                            left: BorderSide(
                                color: colors.accent, width: 2)),
                      ),
                      child: Text(
                        note.note!,
                        style: TextStyle(
                          color: colors.inkSoft,
                          fontSize: 13,
                          fontStyle: FontStyle.italic,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          // ... button -- the only path to whole-paragraph actions
          // (bookmark, "play from here") now that SelectableText owns
          // long-press inside the body of the paragraph.
          SizedBox(
            width: 28,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapDown: (d) => onMenu(d.globalPosition),
              child: Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Icon(
                  Icons.more_horiz,
                  size: 18,
                  color: colors.inkMuted,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSelectionMenu(
      BuildContext ctx, EditableTextState state, String text) {
    final selection = state.textEditingValue.selection;
    if (!selection.isValid || selection.isCollapsed) {
      return AdaptiveTextSelectionToolbar.buttonItems(
        anchors: state.contextMenuAnchors,
        buttonItems: state.contextMenuButtonItems,
      );
    }
    final start = math.max(0, math.min(selection.start, text.length));
    final end = math.max(0, math.min(selection.end, text.length));
    final quote = text.substring(start, end);
    return AdaptiveTextSelectionToolbar.buttonItems(
      anchors: state.contextMenuAnchors,
      buttonItems: [
        ContextMenuButtonItem(
          label: 'Highlight',
          onPressed: () {
            state.hideToolbar();
            onSelectionAction?.call(
                _ParaActionType.highlight, start, end, quote);
          },
        ),
        ContextMenuButtonItem(
          label: 'Note',
          onPressed: () {
            state.hideToolbar();
            onSelectionAction?.call(
                _ParaActionType.note, start, end, quote);
          },
        ),
        ContextMenuButtonItem(
          type: ContextMenuButtonType.copy,
          onPressed: () {
            Clipboard.setData(ClipboardData(text: quote));
            state.hideToolbar();
          },
        ),
      ],
    );
  }
}

// Splits text into TextSpans, painting a background colour wherever a
// range highlight applies. Overlaps go to whoever sorted first; out-of-
// bounds offsets are clamped.
List<TextSpan> _composeSpans(
  String text,
  List<Annotation> rangeHighlights,
  TextStyle baseStyle,
) {
  if (rangeHighlights.isEmpty) {
    return [TextSpan(text: text, style: baseStyle)];
  }
  final ranges = rangeHighlights
      .map((a) {
        final s = math.max(0, math.min(a.quoteStart!, text.length));
        final e = math.max(0, math.min(a.quoteEnd!, text.length));
        return (start: s, end: e, color: a.color.fill);
      })
      .where((r) => r.start < r.end)
      .toList()
    ..sort((a, b) => a.start.compareTo(b.start));

  final spans = <TextSpan>[];
  var cursor = 0;
  for (final r in ranges) {
    if (r.end <= cursor) continue;
    final start = math.max(r.start, cursor);
    if (start > cursor) {
      spans.add(TextSpan(text: text.substring(cursor, start), style: baseStyle));
    }
    spans.add(TextSpan(
      text: text.substring(start, r.end),
      style: baseStyle.copyWith(backgroundColor: r.color),
    ));
    cursor = r.end;
  }
  if (cursor < text.length) {
    spans.add(TextSpan(text: text.substring(cursor), style: baseStyle));
  }
  return spans;
}

/// Slim attach-audiobook strip shown at the bottom of the reader when no
/// audio is attached. Mirrors `attachAudiobookBar` in
/// `App/ReaderView.swift`: speaker icon + "No audiobook attached" + saddle
/// `+ Attach…` pill.

class _AlignBanner extends StatefulWidget {
  final AlignStage stage;
  final PalimpsestColors colors;
  const _AlignBanner({required this.stage, required this.colors});

  @override
  State<_AlignBanner> createState() => _AlignBannerState();
}

class _AlignBannerState extends State<_AlignBanner> {
  Timer? _ticker;
  Duration _elapsed = Duration.zero;

  @override
  void initState() {
    super.initState();
    _resetForLabel(widget.stage.label);
  }

  @override
  void didUpdateWidget(covariant _AlignBanner old) {
    super.didUpdateWidget(old);
    if (widget.stage.label != old.stage.label) {
      _resetForLabel(widget.stage.label);
    }
  }

  /// Restart the elapsed counter at every phase boundary — transcribe is
  /// the long one, and the user only cares about elapsed time inside
  /// whichever phase is currently running. Re-aligns from chapter changes
  /// also start fresh.
  void _resetForLabel(String label) {
    _ticker?.cancel();
    _ticker = null;
    _elapsed = Duration.zero;
    if (_isLongRunning(label)) {
      _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
        if (!mounted) return;
        setState(() => _elapsed += const Duration(seconds: 1));
      });
    }
  }

  bool _isLongRunning(String label) {
    final s = label.toLowerCase();
    return s.contains('transcrib') || s.contains('align');
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.colors;
    final showElapsed = _ticker != null;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: c.canvasCool,
        border: Border(bottom: BorderSide(color: c.hairline)),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              value: widget.stage.fraction,
              valueColor: AlwaysStoppedAnimation(c.accent),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(widget.stage.label,
                style: TextStyle(color: c.inkSoft, fontSize: 13)),
          ),
          if (showElapsed)
            Text(_formatElapsed(_elapsed),
                style: TextStyle(
                  color: c.inkMuted,
                  fontSize: 12,
                  fontFeatures: const [FontFeature.tabularFigures()],
                )),
        ],
      ),
    );
  }
}

String _formatElapsed(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
  final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  return h > 0 ? '$h:$m:$s' : '$m:$s';
}

enum _ParaActionType { highlight, bookmark, note, play, playNeedsAlign, remove }

class _ParaAction {
  final _ParaActionType type;
  final HighlightColor? color;
  /// Set for `remove` actions — the specific annotation to drop. Null for
  /// every other action type.
  final String? annotationId;
  const _ParaAction.highlight(HighlightColor c)
      : type = _ParaActionType.highlight,
        color = c,
        annotationId = null;
  const _ParaAction.bookmark()
      : type = _ParaActionType.bookmark,
        color = null,
        annotationId = null;
  const _ParaAction.note()
      : type = _ParaActionType.note,
        color = null,
        annotationId = null;
  const _ParaAction.play()
      : type = _ParaActionType.play,
        color = null,
        annotationId = null;
  const _ParaAction.playNeedsAlign()
      : type = _ParaActionType.playNeedsAlign,
        color = null,
        annotationId = null;
  const _ParaAction.removeOne(String id)
      : type = _ParaActionType.remove,
        color = null,
        annotationId = id;
}

/// iOS-style selection menu with the saddle "Highlight" primary plus secondary
/// actions in a single rounded pill. Anchored near the touch point.
Future<_ParaAction?> _showSelectionMenu({
  required BuildContext context,
  required Offset anchor,
  required bool hasAlignment,
  required List<Annotation> existing,
}) {
  final colors = context.colors;
  final overlay =
      Overlay.of(context).context.findRenderObject() as RenderBox;
  final size = overlay.size;
  final menuWidth = (size.width - 32).clamp(220.0, 360.0);
  final left = (anchor.dx - menuWidth / 2)
      .clamp(16.0, size.width - menuWidth - 16.0);
  final tipDx = (anchor.dx - left).clamp(20.0, menuWidth - 20.0);
  final showAbove = anchor.dy > size.height / 2;
  // Approximate height grows with the number of removable rows we render.
  // Without this the menu clips off-screen when a paragraph has several
  // annotations stacked.
  final approxHeight = 178.0 + existing.length * 44.0;
  final menuTop = showAbove ? anchor.dy - approxHeight : anchor.dy + 12;

  return showGeneralDialog<_ParaAction>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Selection menu',
    barrierColor: Colors.black.withValues(alpha: 0.18),
    transitionDuration: const Duration(milliseconds: 140),
    pageBuilder: (_, _, _) => Stack(
      children: [
        Positioned(
          left: left,
          top: menuTop,
          width: menuWidth,
          child: _SelectionMenu(
            hasAlignment: hasAlignment,
            existing: existing,
            tipDx: tipDx,
            tipUp: !showAbove,
            colors: colors,
          ),
        ),
      ],
    ),
  );
}

class _SelectionMenu extends StatelessWidget {
  final bool hasAlignment;
  final List<Annotation> existing;
  final double tipDx;
  final bool tipUp;
  final PalimpsestColors colors;

  const _SelectionMenu({
    required this.hasAlignment,
    required this.existing,
    required this.tipDx,
    required this.tipUp,
    required this.colors,
  });

  @override
  Widget build(BuildContext context) {
    final menu = Material(
      color: Colors.transparent,
      child: Container(
        decoration: BoxDecoration(
          color: colors.canvas,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: colors.hairline),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.18),
              blurRadius: 28,
              offset: const Offset(0, 12),
            ),
          ],
        ),
        padding: const EdgeInsets.fromLTRB(10, 10, 10, 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                for (final c in HighlightColor.values)
                  GestureDetector(
                    onTap: () => Navigator.of(context)
                        .pop(_ParaAction.highlight(c)),
                    child: Container(
                      width: 30,
                      height: 30,
                      decoration: BoxDecoration(
                        color: c.swatch,
                        shape: BoxShape.circle,
                        border: Border.all(color: colors.hairline),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Divider(height: 1, color: colors.hairline),
            _MenuRow(
              icon: Icons.bookmark_outline,
              label: 'Bookmark',
              onTap: () =>
                  Navigator.of(context).pop(const _ParaAction.bookmark()),
              colors: colors,
            ),
            _MenuRow(
              icon: Icons.sticky_note_2_outlined,
              label: 'Add note',
              onTap: () =>
                  Navigator.of(context).pop(const _ParaAction.note()),
              colors: colors,
            ),
            // Always-visible discovery hook. When alignment hasn't run
            // yet, the row stays in the menu but tapping it pops a
            // `playNeedsAlign` action so the reader can surface an
            // "align audio first" snackbar instead of silently doing
            // nothing. Same rationale as iOS `ParagraphRow` keeping the
            // disabled Button visible.
            _MenuRow(
              icon: Icons.play_arrow_outlined,
              label: hasAlignment
                  ? 'Play audiobook from here'
                  : 'Play from here · align audio first',
              accent: hasAlignment,
              disabled: !hasAlignment,
              onTap: () => Navigator.of(context).pop(
                hasAlignment
                    ? const _ParaAction.play()
                    : const _ParaAction.playNeedsAlign(),
              ),
              colors: colors,
            ),
            for (final a in existing)
              _MenuRow(
                icon: _removalIcon(a.kind),
                label: _removalLabel(a),
                destructive: true,
                onTap: () => Navigator.of(context)
                    .pop(_ParaAction.removeOne(a.id)),
                colors: colors,
              ),
          ],
        ),
      ),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (tipUp)
          CustomPaint(
            size: Size(tipDx + 12, 8),
            painter: _TipPainter(colors: colors, dx: tipDx, up: true),
          ),
        menu,
        if (!tipUp)
          CustomPaint(
            size: Size(tipDx + 12, 8),
            painter: _TipPainter(colors: colors, dx: tipDx, up: false),
          ),
      ],
    );
  }
}

IconData _removalIcon(AnnotationKind kind) {
  switch (kind) {
    case AnnotationKind.highlight:
      return Icons.format_color_reset_outlined;
    case AnnotationKind.bookmark:
      return Icons.bookmark_remove_outlined;
    case AnnotationKind.note:
      return Icons.speaker_notes_off_outlined;
  }
}

String _removalLabel(Annotation a) {
  switch (a.kind) {
    case AnnotationKind.highlight:
      return 'Remove highlight';
    case AnnotationKind.bookmark:
      return 'Remove bookmark';
    case AnnotationKind.note:
      final preview = (a.note ?? '').trim();
      if (preview.isEmpty) return 'Remove note';
      final short = preview.length > 28
          ? '${preview.substring(0, 28)}…'
          : preview;
      return 'Remove note: $short';
  }
}

class _TipPainter extends CustomPainter {
  final PalimpsestColors colors;
  final double dx;
  final bool up;
  _TipPainter({required this.colors, required this.dx, required this.up});

  @override
  void paint(Canvas canvas, Size size) {
    final fill = Paint()..color = colors.canvas;
    final stroke = Paint()
      ..color = colors.hairline
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    final path = Path();
    if (up) {
      path.moveTo(dx - 6, size.height);
      path.lineTo(dx, 0);
      path.lineTo(dx + 6, size.height);
    } else {
      path.moveTo(dx - 6, 0);
      path.lineTo(dx, size.height);
      path.lineTo(dx + 6, 0);
    }
    path.close();
    canvas.drawPath(path, fill);
    canvas.drawPath(path, stroke);
  }

  @override
  bool shouldRepaint(covariant _TipPainter old) =>
      old.dx != dx || old.up != up;
}

class _MenuRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool accent;
  final bool destructive;
  final bool disabled;
  final VoidCallback onTap;
  final PalimpsestColors colors;
  const _MenuRow({
    required this.icon,
    required this.label,
    this.accent = false,
    this.destructive = false,
    this.disabled = false,
    required this.onTap,
    required this.colors,
  });

  @override
  Widget build(BuildContext context) {
    final color = disabled
        ? colors.inkMuted
        : destructive
            ? Colors.redAccent
            : accent
                ? colors.accent
                : colors.ink;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 10),
          child: Row(
            children: [
              Icon(icon, size: 18, color: color),
              const SizedBox(width: 10),
              Expanded(
                  child: Text(label,
                      style: TextStyle(
                          color: color,
                          fontSize: 14,
                          fontWeight: accent
                              ? FontWeight.w600
                              : FontWeight.w400))),
            ],
          ),
        ),
      ),
    );
  }
}

class _AnnotationsSheet extends StatelessWidget {
  final AnnotationStore annotations;
  final StoredBook book;
  final ValueChanged<Annotation> onJumpTo;
  const _AnnotationsSheet({
    required this.annotations,
    required this.book,
    required this.onJumpTo,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return DraggableScrollableSheet(
      initialChildSize: 0.55,
      minChildSize: 0.30,
      maxChildSize: 0.90,
      expand: false,
      builder: (_, scroll) => Container(
        decoration: BoxDecoration(
          color: colors.canvas,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
        ),
        child: ListenableBuilder(
          listenable: annotations,
          builder: (_, _) {
            final items = [...annotations.items]
              ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
            return Column(
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
                      Text('ANNOTATIONS',
                          style: TextStyle(
                              color: colors.inkMuted,
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              letterSpacing: 1.5)),
                      const Spacer(),
                      Text('${items.length}',
                          style: TextStyle(
                              color: colors.inkMuted, fontSize: 11)),
                    ],
                  ),
                ),
                if (items.isEmpty)
                  Expanded(
                    child: Center(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 36),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.bookmarks_outlined,
                                size: 44, color: colors.inkMuted),
                            const SizedBox(height: 12),
                            Text('No annotations yet.',
                                style: TextStyle(
                                    color: colors.ink, fontSize: 16)),
                            const SizedBox(height: 6),
                            Text(
                              'Long-press a paragraph to highlight, bookmark, or note it.',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                  color: colors.inkMuted, fontSize: 12),
                            ),
                          ],
                        ),
                      ),
                    ),
                  )
                else
                  Expanded(
                    child: ListView.separated(
                      controller: scroll,
                      itemCount: items.length,
                      separatorBuilder: (_, _) => Divider(
                          height: 1, color: colors.hairline),
                      itemBuilder: (_, i) {
                        final a = items[i];
                        final segTitle = book.segments
                                .firstWhere((s) => s.id == a.segmentId,
                                    orElse: () => book.segments.first)
                                .title ??
                            'Section';
                        return ListTile(
                          leading: _IconForKind(a: a, colors: colors),
                          title: Text(
                            a.quote,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(color: colors.ink),
                          ),
                          subtitle: Text(
                            a.note?.isNotEmpty == true
                                ? '$segTitle  ·  ${a.note}'
                                : segTitle,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(color: colors.inkMuted),
                          ),
                          trailing: IconButton(
                            icon: Icon(Icons.delete_outline,
                                color: colors.inkMuted),
                            onPressed: () => annotations.remove(a.id),
                          ),
                          onTap: () => onJumpTo(a),
                        );
                      },
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _IconForKind extends StatelessWidget {
  final Annotation a;
  final PalimpsestColors colors;
  const _IconForKind({required this.a, required this.colors});

  @override
  Widget build(BuildContext context) {
    switch (a.kind) {
      case AnnotationKind.highlight:
        return Container(
          width: 24,
          height: 24,
          decoration: BoxDecoration(
            color: a.color.swatch,
            shape: BoxShape.circle,
          ),
        );
      case AnnotationKind.bookmark:
        return Icon(Icons.bookmark, color: colors.accent);
      case AnnotationKind.note:
        return Icon(Icons.sticky_note_2_outlined, color: colors.inkSoft);
    }
  }
}

// ---------------------------------------------------------------------------
// Tablet layout — collapsible rail + expanded sidebar + full audio footer.
// Mirrors `iosCollapsedRail` / `iosExpandedSidebar` / `iosAudioFooter` from
// the iPad path in `App/ReaderView+iOS.swift`.
// ---------------------------------------------------------------------------

class _AlignmentFullscreen extends StatefulWidget {
  final StoredBook book;
  final AlignStage stage;
  final PalimpsestColors colors;
  final VoidCallback onContinueInBackground;
  const _AlignmentFullscreen({
    required this.book,
    required this.stage,
    required this.colors,
    required this.onContinueInBackground,
  });

  @override
  State<_AlignmentFullscreen> createState() => _AlignmentFullscreenState();
}

class _AlignmentFullscreenState extends State<_AlignmentFullscreen> {
  static const _phases = ['Downloading', 'Transcribing', 'Aligning'];

  Timer? _ticker;
  Duration _elapsed = Duration.zero;

  @override
  void initState() {
    super.initState();
    _resetForLabel(widget.stage.label);
  }

  @override
  void didUpdateWidget(covariant _AlignmentFullscreen old) {
    super.didUpdateWidget(old);
    if (widget.stage.label != old.stage.label) {
      _resetForLabel(widget.stage.label);
    }
  }

  /// `transcribeChunked` falls back to a single-call transcribe for audio
  /// short enough to fit in one whisper pass, and that path can't emit a
  /// real fraction. The elapsed timer kicks in only in those cases — it
  /// proves the work is alive while the indeterminate `LinearProgressIndicator`
  /// runs. Long audiobooks always have a real `i / N` fraction from the
  /// chunked path and skip this.
  void _resetForLabel(String label) {
    _ticker?.cancel();
    _ticker = null;
    _elapsed = Duration.zero;
    if (_isLongRunning(label)) {
      _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
        if (!mounted) return;
        setState(() => _elapsed += const Duration(seconds: 1));
      });
    }
  }

  bool _isLongRunning(String label) {
    final s = label.toLowerCase();
    return s.contains('transcrib') || s.contains('align');
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  int get _phaseIdx {
    final s = widget.stage.label.toLowerCase();
    if (s.startsWith('downloading') || s.startsWith('preparing')) return 0;
    if (s.contains('transcrib')) return 1;
    if (s.contains('align') || s.contains('done')) return 2;
    return 0;
  }

  @override
  Widget build(BuildContext context) {
    final stage = widget.stage;
    final book = widget.book;
    final colors = widget.colors;
    final onContinueInBackground = widget.onContinueInBackground;
    final pct = stage.fraction == null
        ? null
        : (stage.fraction!.clamp(0.0, 1.0) * 100).round();
    return Container(
      color: colors.canvas,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              const Spacer(),
              _CoverThumb(book: book, colors: colors),
              const SizedBox(height: 32),
              Text(
                'ALIGNING · DO NOT QUIT',
                style: TextStyle(
                  color: colors.accent,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 1.5,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                stage.label,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: colors.ink,
                  fontSize: 24,
                  fontWeight: FontWeight.w600,
                  height: 1.2,
                ),
              ),
              const SizedBox(height: 16),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 460),
                child: Text(
                  'Whisper is transcribing the audiobook on this device and anchoring each paragraph to where it lands in the audio. You can leave this screen open or read while it runs.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: colors.inkSoft,
                    fontSize: 14,
                    height: 1.45,
                  ),
                ),
              ),
              const SizedBox(height: 28),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 360),
                child: Column(
                  children: [
                    LinearProgressIndicator(
                      value: stage.fraction,
                      backgroundColor: colors.hairlineStrong,
                      valueColor:
                          AlwaysStoppedAnimation<Color>(colors.accent),
                      minHeight: 4,
                    ),
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            pct != null
                                ? '$pct%'
                                : (_ticker != null
                                    ? _formatElapsed(_elapsed)
                                    : ''),
                            style: TextStyle(
                                color: colors.inkMuted,
                                fontSize: 11,
                                fontFeatures: const [
                                  FontFeature.tabularFigures()
                                ]),
                          ),
                          Text(_phases[_phaseIdx],
                              style: TextStyle(
                                  color: colors.inkMuted, fontSize: 11)),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 28),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  for (var i = 0; i < _phases.length; i++) ...[
                    if (i > 0)
                      Container(
                        width: 32,
                        height: 1,
                        color: colors.hairline,
                      ),
                    _PhaseTick(
                      label: _phases[i],
                      isActive: i == _phaseIdx,
                      isDone: i < _phaseIdx,
                      colors: colors,
                    ),
                  ],
                ],
              ),
              const Spacer(),
              TextButton(
                onPressed: onContinueInBackground,
                child: Text(
                  'Continue in background',
                  style: TextStyle(
                    color: colors.inkSoft,
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }
}

