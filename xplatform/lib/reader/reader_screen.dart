import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../alignment/alignment_service.dart';
import '../alignment/alignment_types.dart';
import '../annotations/annotation_store.dart';
import '../annotations/annotation_types.dart';
import '../audio/audio_player.dart';
import '../persistence/library_storage.dart';
import '../platform/form_factor.dart';
import '../state/library_store.dart';
import '../theme.dart';
import 'audio_sheet.dart';
import 'curl_page_view.dart';
import 'paginator.dart';

part 'reader_widgets.dart';
part 'reader_header.dart';
part 'reader_audio_bar.dart';
part 'reader_chapter_nav.dart';
part 'reader_shell.dart';

const _kHeaderHeight = 44.0;
const _kPagePadding = EdgeInsets.fromLTRB(28, 14, 28, 12);
const _kBodyFontSize = 17.0;
const _kBodyLineHeight = 25.0 / 17.0;
const _kWordsPerPage = 170;

enum _SegmentKind { chapter, part, frontMatter }

// Heading types that group chapters (Part / Book / Volume / Section).
// Shown verbatim, never counted as a chapter.
final RegExp _partPrefixRe =
    RegExp(r'^(part|book|volume|section)\b', caseSensitive: false);

// Anything that smells like front/back matter. Substring match so e.g.
// "Author's Preface" or "Translator's Foreword" both hit.
final RegExp _frontMatterRe = RegExp(
  r'(preface|foreword|introduction|prologue|epilogue|afterword|interlude|'
  r'dedication|acknowledg|contents|cover|title\s+page|copyright|notes|'
  r'references|bibliography|glossary|index|appendix|about\s+the\s+(author|book)|'
  r'frontispiece|half\s*title|colophon|errata)',
  caseSensitive: false,
);

// Already-numbered titles (e.g. "Chapter 7") -- keep the wording, don't
// re-prefix.
final RegExp _chapterPrefixRe =
    RegExp(r'^chapter\b', caseSensitive: false);

_SegmentKind _classifySegmentTitle(String title) {
  if (_partPrefixRe.hasMatch(title)) return _SegmentKind.part;
  if (_frontMatterRe.hasMatch(title)) return _SegmentKind.frontMatter;
  return _SegmentKind.chapter;
}

class ReaderScreen extends StatefulWidget {
  final LibraryStore store;
  final StoredBook book;
  final bool animationsEnabled;
  final ValueChanged<String?>? onOpened;
  const ReaderScreen({
    super.key,
    required this.store,
    required this.book,
    this.animationsEnabled = true,
    this.onOpened,
  });

  @override
  State<ReaderScreen> createState() => _ReaderScreenState();
}

class _ReaderScreenState extends State<ReaderScreen> {
  late StoredBook _book;
  late int _segmentIndex;
  late CurlPageController _pageController;
  int _pageInChapter = 0;
  // Per-segment cache of paginated pages, keyed by segmentId.
  final Map<String, List<ReaderPage>> _pagesBySegment = {};
  // Flat index across all chapters. Each entry is (segmentIndex, pageInChapter).
  // Same model as iOS `flatGlobalIndex` so a horizontal swipe past the last
  // page of a chapter lands on the first page of the next, no chevron tap.
  final List<({int seg, int page})> _flatIndex = [];
  // Inverse map: cumulative page offset per segment so chapter jumps map
  // back to a global page index in O(1).
  final List<int> _segPageOffsets = [];

  final _player = PalimpsestAudioPlayer();
  late final AnnotationStore _annotations;
  AlignmentMap? _alignment;
  bool _aligning = false;
  // First-run alignment shows a fullscreen overlay (matches iOS
  // `alignmentFullscreen`). Dismissing it via "Continue in background"
  // leaves the inline `_AlignBanner` running.
  bool _showAlignFullscreen = false;
  AlignStage? _alignStage;
  Timer? _progressTimer;
  bool _chromeShown = true;

  // Desktop rail state — same model as iOS `iosSidebarVisible` / `sidebarTab`.
  bool _railExpanded = false;
  ReaderSidebarTab _railTab = ReaderSidebarTab.chapters;

  void _setRailExpanded(bool v) => setState(() => _railExpanded = v);
  void _setRailTab(ReaderSidebarTab t) => setState(() => _railTab = t);
  void _setRailTabAndExpand(ReaderSidebarTab t) => setState(() {
        _railTab = t;
        _railExpanded = true;
      });

  // Two-page spread (iPad-landscape parity, `.mid` spineLocation on iOS).
  // The PageView's controller swaps semantics between modes — single-page
  // granular vs spread-pair granular — so we recreate it on toggle.
  bool _spreadMode = false;

  @override
  void initState() {
    super.initState();
    _book = widget.book;
    _annotations = AnnotationStore(storage: widget.store.storage, book: _book);
    _annotations.load();
    _segmentIndex = _book.currentSegmentIndex.clamp(
      0,
      _book.segments.isEmpty ? 0 : _book.segments.length - 1,
    );
    // Pre-paginate every chapter so a single PageView can span the whole
    // book — same flat-index model the iOS pageCurl uses. Books typically
    // pre-paginate in <100ms even for long novels.
    _rebuildFlatIndex();
    final saved = _book.currentPageInChapter
        .clamp(0, _pagesForCurrentChapter().length - 1);
    _pageInChapter = saved;
    _pageController =
        CurlPageController(initialPage: _globalIndex(_segmentIndex, saved));
    widget.onOpened?.call(_book.id);
    _player.initSession();
    if (_book.audioPath != null) {
      _player
          .loadFile(_book.audioPath!,
              bookId: _book.id, title: _book.title, author: _book.author)
          .then((_) {
        if (_book.currentAudioSeconds != null) {
          _player.seekSeconds(_book.currentAudioSeconds!);
        }
      });
    }
    if (_book.alignmentPath != null) {
      widget.store.loadAlignment(_book).then((map) {
        if (mounted) setState(() => _alignment = map);
      });
    }
    _progressTimer =
        Timer.periodic(const Duration(seconds: 2), (_) => _persistProgress());
  }

  Future<void> _persistProgress() async {
    if (!mounted) return;
    await widget.store.updateProgress(
      _book,
      segmentIndex: _segmentIndex,
      pageInChapter: _pageInChapter,
      audioSeconds: _player.position.inMilliseconds / 1000.0,
    );
  }

  @override
  void dispose() {
    _progressTimer?.cancel();
    _persistProgress();
    _pageController.dispose();
    _player.dispose();
    _annotations.dispose();
    super.dispose();
  }

  TextSegment get _segment => _book.segments[_segmentIndex];

  // Chapter-bar label. Part/Book/Volume/Section headings, front/back
  // matter, and titles already starting with "Chapter " all pass
  // through unchanged. Anything else gets a "Chapter N · " prefix where
  // N counts chapter-kind segments only (front matter and Parts don't
  // bump the counter).
  String _displayChapterLabel(int idx) {
    final seg = _book.segments[idx];
    final raw = seg.title?.trim();
    if (raw == null || raw.isEmpty) return 'Section ${idx + 1}';

    final kind = _classifySegmentTitle(raw);
    if (kind != _SegmentKind.chapter) return raw;

    if (_chapterPrefixRe.hasMatch(raw)) return raw;

    var n = 0;
    for (var i = 0; i <= idx; i++) {
      final t = _book.segments[i].title?.trim() ?? '';
      if (t.isEmpty) continue;
      if (_classifySegmentTitle(t) == _SegmentKind.chapter) n++;
    }
    return 'Chapter $n · $raw';
  }

  List<ReaderPage> _pagesForSegment(TextSegment seg) {
    final cached = _pagesBySegment[seg.id];
    if (cached != null) return cached;
    final paragraphs = seg.text
        .split(RegExp(r'\n\s*\n'))
        .map((p) => p.replaceAll(RegExp(r'\s*\n\s*'), ' ').trim())
        .where((p) => p.isNotEmpty)
        .toList(growable: false);
    final pages = const Paginator(wordsPerPage: _kWordsPerPage)
        .paginate(paragraphs);
    final out = pages.isEmpty
        ? const [ReaderPage(paragraphs: ['(empty section)'])]
        : pages;
    _pagesBySegment[seg.id] = out;
    return out;
  }

  List<ReaderPage> _pagesForCurrentChapter() => _pagesForSegment(_segment);

  /// Build the (segmentIndex, pageInChapter) flat list once per session.
  /// Cheap — pagination is just word counting per paragraph.
  void _rebuildFlatIndex() {
    _flatIndex.clear();
    _segPageOffsets.clear();
    var offset = 0;
    for (var i = 0; i < _book.segments.length; i++) {
      _segPageOffsets.add(offset);
      final pages = _pagesForSegment(_book.segments[i]);
      for (var p = 0; p < pages.length; p++) {
        _flatIndex.add((seg: i, page: p));
      }
      offset += pages.length;
    }
  }

  int _globalIndex(int seg, int page) => _segPageOffsets[seg] + page;

  void _goToSegment(int i, {bool toLastPage = false}) {
    final pages = _pagesForSegment(_book.segments[i]);
    final targetPage = toLastPage ? pages.length - 1 : 0;
    setState(() {
      _segmentIndex = i;
      _pageInChapter = targetPage;
    });
    if (_pageController.hasClients) {
      final globalIdx = _globalIndex(i, targetPage);
      _pageController.jumpToPage(_spreadMode ? globalIdx & ~1 : globalIdx);
    }
  }

  void _onPageChanged(int idx) {
    if (idx < 0 || idx >= _flatIndex.length) return;
    final m = _flatIndex[idx];
    setState(() {
      if (m.seg != _segmentIndex) _segmentIndex = m.seg;
      _pageInChapter = m.page;
    });
    // Persist immediately on every turn — the 2-second timer alone misses
    // saves when the user flips a page and backs out of the reader inside
    // that window. dispose's `_persistProgress` is async and races against
    // the widget tear-down, so the safest place to commit is here.
    _persistProgress();
  }

  /// Swap `_pageController` to match the new spread mode. Old controller
  /// dispose is deferred to the next frame so any active PageView still has
  /// a valid client during the build that triggered the swap.
  void _swapControllerForMode(bool spread) {
    final old = _pageController;
    final globalIdx = _globalIndex(_segmentIndex, _pageInChapter);
    _pageController = CurlPageController(
      initialPage: spread ? globalIdx & ~1 : globalIdx,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      old.dispose();
    });
  }

  Future<void> _attachAudio() async {
    // Android: SAF greys out `.m4b` under `FileType.custom` (no registered
    // MIME), so we go `FileType.audio` to get the `audio/*` view that
    // surfaces every audiobook format.
    // Desktop (Linux/Windows): file_picker drives zenity/kdialog and its
    // `audio/*` MIME filter also drops `.m4b` on most installs, so we go
    // back to explicit extensions there.
    final result = Platform.isAndroid
        ? await FilePicker.platform.pickFiles(type: FileType.audio)
        : await FilePicker.platform.pickFiles(
            type: FileType.custom,
            allowedExtensions: const [
              'm4b', 'm4a', 'mp3', 'wav', 'aac',
              'flac', 'ogg', 'opus', 'mp4',
            ],
          );
    if (result == null || result.files.single.path == null) return;
    final updated =
        await widget.store.attachAudio(_book, File(result.files.single.path!));
    setState(() {
      _book = updated;
      // Drop the in-memory alignment too — `attachAudio` already deleted
      // the JSON and cleared the StoredBook's alignmentPath, but the
      // reader holds its own cached `_alignment` that gates "Play from
      // here" / "Re-align" labels. Without this, the reader keeps showing
      // "Re-align" against stale word anchors.
      _alignment = null;
    });
    await _player.loadFile(
      updated.audioPath!,
      bookId: _book.id,
      title: _book.title,
      author: _book.author,
    );
  }

  Future<void> _runAlign() async {
    setState(() {
      _aligning = true;
      // First-run shows the fullscreen overlay; re-aligns surface inline
      // since the user is already in the middle of reading.
      _showAlignFullscreen = _alignment == null;
      _alignStage = const AlignStage('Preparing…');
    });
    try {
      await for (final stage in widget.store.alignBook(_book)) {
        if (!mounted) return;
        setState(() => _alignStage = stage);
      }
      final fresh = widget.store.books.firstWhere((b) => b.id == _book.id);
      final map = await widget.store.loadAlignment(fresh);
      if (mounted) {
        setState(() {
          _book = fresh;
          _alignment = map;
        });
        // Visible completion feedback. Without this the fullscreen
        // dismisses and the reader returns to looking exactly as it did,
        // so the user can't tell whether anything actually happened.
        // We also distinguish 0-anchor outcomes (audio/text mismatch)
        // from real success, since "Play from here" silently does
        // nothing when there are no anchors for that segment.
        final wordCount = map?.words.length ?? 0;
        final messenger = ScaffoldMessenger.of(context);
        if (wordCount == 0) {
          messenger.showSnackBar(SnackBar(
            content: const Text(
                "Alignment finished but no anchors landed. The audiobook may not match this EPUB."),
            action: SnackBarAction(label: 'Retry', onPressed: _runAlign),
          ));
        } else {
          messenger.showSnackBar(SnackBar(
            content: Text(
                'Alignment complete · $wordCount paragraph anchors synced'),
          ));
        }
      }
    } catch (e, st) {
      debugPrint('alignment error: $e\n$st');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Alignment failed: $e'),
            action: SnackBarAction(label: 'Retry', onPressed: _runAlign),
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _aligning = false;
          _showAlignFullscreen = false;
        });
      }
    }
  }

  Future<void> _seekToParagraph(
      TextSegment segment, int paragraphIndex, String paragraphText) {
    if (_alignment == null) return Future.value();
    final approxOffset = segment.text.indexOf(paragraphText);
    final wordsBefore = approxOffset < 0
        ? 0
        : segment.text
            .substring(0, approxOffset)
            .split(RegExp(r'\s+'))
            .where((s) => s.isNotEmpty)
            .length;
    final t = AlignmentService.seekTimeForParagraph(
      _alignment!,
      segments: _book.segments,
      segmentId: segment.id,
      wordIndex: wordsBefore,
    );
    if (t == null) return Future.value();
    return _player.seekSeconds(t).then((_) => _player.play());
  }

  void _showChapters() => showReaderChapterSheet(
        context: context,
        book: _book,
        annotations: _annotations,
        currentSegmentIndex: _segmentIndex,
        onPickChapter: _goToSegment,
      );

  void _showOverflowMenu() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: context.colors.canvas,
      builder: (sheet) {
        final colors = sheet.colors;
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: Icon(Icons.bookmarks_outlined, color: colors.inkSoft),
                title: Text('All annotations',
                    style: TextStyle(color: colors.ink)),
                trailing: Text('${_annotations.items.length}',
                    style: TextStyle(color: colors.inkMuted)),
                onTap: () {
                  Navigator.of(sheet).pop();
                  _showAnnotations();
                },
              ),
              ListTile(
                leading: Icon(Icons.headphones_outlined, color: colors.inkSoft),
                title: Text(
                  _book.audioPath == null
                      ? 'Attach audiobook'
                      : 'Audio controls',
                  style: TextStyle(color: colors.ink),
                ),
                onTap: () {
                  Navigator.of(sheet).pop();
                  if (_book.audioPath == null) {
                    _attachAudio();
                  } else {
                    _showAudioSheet();
                  }
                },
              ),
              if (_book.audioPath != null)
                ListTile(
                  leading: Icon(
                    _alignment == null
                        ? Icons.auto_awesome
                        : Icons.refresh,
                    color: colors.accent,
                  ),
                  title: Text(
                    _alignment == null
                        ? 'Align audio with text'
                        : 'Re-align audio with text',
                    style: TextStyle(color: colors.accent),
                  ),
                  onTap: () {
                    Navigator.of(sheet).pop();
                    _runAlign();
                  },
                ),
              if (_book.audioPath != null)
                ListTile(
                  leading: Icon(Icons.swap_horiz, color: colors.inkSoft),
                  title: Text('Replace audiobook…',
                      style: TextStyle(color: colors.ink)),
                  onTap: () {
                    Navigator.of(sheet).pop();
                    _attachAudio();
                  },
                ),
            ],
          ),
        );
      },
    );
  }

  void _showAudioSheet() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (sheet) => AudioSheet(
        player: _player,
        book: _book,
        hasAlignment: _alignment != null,
        isAligning: _aligning,
        onAlign: () {
          Navigator.of(sheet).pop();
          _runAlign();
        },
      ),
    );
  }

  void _showAnnotations() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (sheet) => _AnnotationsSheet(
        annotations: _annotations,
        book: _book,
        onJumpTo: (a) {
          Navigator.of(sheet).pop();
          final i = _book.segments.indexWhere((s) => s.id == a.segmentId);
          if (i >= 0) _goToSegment(i);
        },
      ),
    );
  }

  // Map (chapter pageIdx, paragraph idx within page) -> absolute
  // paragraph index in the segment, accounting for continuation flags
  // so annotations survive re-pagination at different page sizes.
  int _absoluteParagraphIndex(
      TextSegment segment, int pageIdxInChapter, int pIndexInPage) {
    final pages = _pagesForSegment(segment);
    var idx = 0;
    for (var i = 0; i < pageIdxInChapter; i++) {
      idx += pages[i].paragraphs.length;
      if (pages[i].endsContinuation) idx -= 1;
    }
    idx += pIndexInPage;
    if (pages[pageIdxInChapter].startsContinuation) idx -= 1;
    return idx;
  }

  Future<void> _onParagraphLongPress(int segIdx, int pageIdxInChapter,
      int pIndexInPage, String text, Offset globalPos) async {
    final segment = _book.segments[segIdx];
    final segId = segment.id;
    final absoluteIdx =
        _absoluteParagraphIndex(segment, pageIdxInChapter, pIndexInPage);

    final action = await _showSelectionMenu(
      context: context,
      anchor: globalPos,
      hasAlignment: _alignment != null,
      existing: _annotations.forParagraph(segId, absoluteIdx),
    );
    if (action == null || !mounted) return;

    final colors = context.colors;
    final id = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
    switch (action.type) {
      case _ParaActionType.highlight:
        await _annotations.add(Annotation(
          id: id,
          segmentId: segId,
          paragraphIndex: absoluteIdx,
          kind: AnnotationKind.highlight,
          color: action.color!,
          quote: text,
          createdAt: DateTime.now().toUtc(),
        ));
      case _ParaActionType.bookmark:
        await _annotations.add(Annotation(
          id: id,
          segmentId: segId,
          paragraphIndex: absoluteIdx,
          kind: AnnotationKind.bookmark,
          quote: text,
          createdAt: DateTime.now().toUtc(),
        ));
      case _ParaActionType.note:
        if (!mounted) return;
        final note = await _promptForNote(initial: null);
        if (note != null && note.isNotEmpty) {
          await _annotations.add(Annotation(
            id: id,
            segmentId: segId,
            paragraphIndex: absoluteIdx,
            kind: AnnotationKind.note,
            color: HighlightColor.amber,
            quote: text,
            note: note,
            createdAt: DateTime.now().toUtc(),
          ));
        }
      case _ParaActionType.play:
        await _seekToParagraph(segment, absoluteIdx, text);
      case _ParaActionType.playNeedsAlign:
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text(
                'Run audio alignment first to play from a specific paragraph.'),
            action: _book.audioPath == null
                ? null
                : SnackBarAction(
                    label: 'Align now',
                    onPressed: _runAlign,
                  ),
          ),
        );
      case _ParaActionType.remove:
        if (action.annotationId != null) {
          await _annotations.remove(action.annotationId!);
        }
    }
    setState(() {}); // rerender to apply highlight color
    // Suppress unused colors warning
    colors.canvas;
  }

  // Called from the in-text selection toolbar (Highlight / Note).
  // start / end are char offsets inside paragraphText. We translate
  // the per-page paragraph index to the absolute one using the same
  // continuation-aware walk as _onParagraphLongPress.
  Future<void> _onSelectionAction(
    int segIdx,
    int pageIdxInChapter,
    int pIndexInPage,
    String paragraphText,
    int start,
    int end,
    _ParaActionType type,
  ) async {
    if (start >= end) return;
    final segment = _book.segments[segIdx];
    final segId = segment.id;
    final absoluteIdx =
        _absoluteParagraphIndex(segment, pageIdxInChapter, pIndexInPage);
    final quote = paragraphText.substring(start, end);
    final id = DateTime.now().microsecondsSinceEpoch.toRadixString(36);

    switch (type) {
      case _ParaActionType.highlight:
        await _annotations.add(Annotation(
          id: id,
          segmentId: segId,
          paragraphIndex: absoluteIdx,
          kind: AnnotationKind.highlight,
          color: HighlightColor.amber,
          quote: quote,
          quoteStart: start,
          quoteEnd: end,
          createdAt: DateTime.now().toUtc(),
        ));
      case _ParaActionType.note:
        if (!mounted) return;
        final note = await _promptForNote(initial: null);
        if (note != null && note.isNotEmpty) {
          await _annotations.add(Annotation(
            id: id,
            segmentId: segId,
            paragraphIndex: absoluteIdx,
            kind: AnnotationKind.note,
            color: HighlightColor.amber,
            quote: quote,
            quoteStart: start,
            quoteEnd: end,
            note: note,
            createdAt: DateTime.now().toUtc(),
          ));
        }
      case _ParaActionType.bookmark:
      case _ParaActionType.play:
      case _ParaActionType.playNeedsAlign:
      case _ParaActionType.remove:
        // Selection toolbar only offers highlight + note; the rest live
        // on the ... button for the whole paragraph.
        break;
    }
    if (!mounted) return;
    setState(() {});
  }

  Future<String?> _promptForNote({String? initial}) {
    final controller = TextEditingController(text: initial ?? '');
    return showDialog<String>(
      context: context,
      builder: (dialog) {
        final colors = dialog.colors;
        return AlertDialog(
          backgroundColor: colors.canvas,
          title: Text('Note', style: TextStyle(color: colors.ink)),
          content: TextField(
            controller: controller,
            autofocus: true,
            minLines: 3,
            maxLines: 6,
            style: TextStyle(color: colors.ink),
            decoration: InputDecoration(
              hintText: 'Type your note…',
              hintStyle: TextStyle(color: colors.inkMuted),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialog).pop(),
              child: Text('Cancel',
                  style: TextStyle(color: colors.inkSoft)),
            ),
            TextButton(
              onPressed: () =>
                  Navigator.of(dialog).pop(controller.text.trim()),
              child: Text('Save',
                  style: TextStyle(color: colors.accent)),
            ),
          ],
        );
      },
    );
  }

  void _flipBy(int direction) {
    if (!_pageController.hasClients || _flatIndex.isEmpty) return;
    final step = (_spreadMode ? 2 : 1) * direction;
    final target = _pageController.page + step;
    if (target < 0 || target >= _flatIndex.length) return;
    _pageController.animateToPage(target);
  }

  KeyEventResult _handleReaderKey(FocusNode _, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowRight ||
        event.logicalKey == LogicalKeyboardKey.pageDown ||
        event.logicalKey == LogicalKeyboardKey.space) {
      _flipBy(1);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowLeft ||
        event.logicalKey == LogicalKeyboardKey.pageUp) {
      _flipBy(-1);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final size = MediaQuery.sizeOf(context);
    // Two-page spread is desktop-only and follows window aspect: wide
    // window = facing pages, tall window = single. Toggling rebuilds the
    // PageView controller so granular page math swaps in lockstep.
    final wantsSpread = !isMobile && size.width > size.height;
    if (wantsSpread != _spreadMode) {
      _spreadMode = wantsSpread;
      _swapControllerForMode(wantsSpread);
    }
    // Mobile collapses chrome on tap to give the page maximum room.
    // Desktop keeps it visible since the window already has plenty.
    final showChrome = !isMobile || _chromeShown;

    return Focus(
      autofocus: true,
      onKeyEvent: _handleReaderKey,
      child: Scaffold(
        backgroundColor: colors.canvasCool,
        body: ListenableBuilder(
          listenable: _annotations,
          builder: (_, _) => Stack(
            children: [
              SafeArea(
                child: ReaderShell(
                  rail: isMobile ? null : _buildRail(),
                  header: showChrome ? _buildHeader() : null,
                  alignBanner: _aligning && _alignStage != null
                      ? _AlignBanner(stage: _alignStage!, colors: colors)
                      : null,
                  pageView: _readerPageView(spread: wantsSpread),
                  audioBar: showChrome ? _buildAudioBar() : null,
                ),
              ),
              if (_showAlignFullscreen && _alignStage != null)
                Positioned.fill(
                  child: _AlignmentFullscreen(
                    book: _book,
                    stage: _alignStage!,
                    colors: colors,
                    onContinueInBackground: () =>
                        setState(() => _showAlignFullscreen = false),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() => ReaderHeader(
        title: _displayChapterLabel(_segmentIndex),
        onBack: () => Navigator.of(context).pop(),
        onChapters: _showChapters,
        onOverflow: _showOverflowMenu,
      );

  Widget _buildAudioBar() => ReaderAudioBar(
        player: _player,
        book: _book,
        hasAlignment: _alignment != null,
        isAligning: _aligning,
        onAttach: _attachAudio,
        onAlign: _runAlign,
        onReplaceAudio: _attachAudio,
        onShowSheet: _showAudioSheet,
      );

  Widget _buildRail() => ReaderChapterRail(
        book: _book,
        annotations: _annotations,
        currentSegmentIndex: _segmentIndex,
        tab: _railTab,
        expanded: _railExpanded,
        onTabChange: _setRailTab,
        onTabAndExpand: _setRailTabAndExpand,
        onCollapse: () => _setRailExpanded(false),
        onExpand: () => _setRailExpanded(true),
        onPickChapter: _goToSegment,
        onJumpToAnnotation: (a) {
          final i = _book.segments.indexWhere((s) => s.id == a.segmentId);
          if (i >= 0) _goToSegment(i);
        },
        onSettings: _openSettingsSheet,
        onBackToLibrary: () => Navigator.of(context).pop(),
      );


  void _openSettingsSheet() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: context.colors.canvas,
      isScrollControlled: true,
      builder: (sheet) {
        final colors = sheet.colors;
        return SafeArea(
          child: ListView(
            shrinkWrap: true,
            children: [
              ListTile(
                leading: Icon(Icons.bookmarks_outlined, color: colors.inkSoft),
                title: Text('All annotations',
                    style: TextStyle(color: colors.ink)),
                onTap: () {
                  Navigator.of(sheet).pop();
                  _showAnnotations();
                },
              ),
              if (_book.audioPath != null)
                ListTile(
                  leading: Icon(
                    _alignment == null ? Icons.auto_awesome : Icons.refresh,
                    color: colors.accent,
                  ),
                  title: Text(
                    _alignment == null
                        ? 'Align audio with text'
                        : 'Re-align audio with text',
                    style: TextStyle(color: colors.accent),
                  ),
                  onTap: () {
                    Navigator.of(sheet).pop();
                    _runAlign();
                  },
                ),
            ],
          ),
        );
      },
    );
  }

  /// Page surface used by both phone and tablet. `spread` controls
  /// two-up vs one-up layout. The controller's `page` is the global
  /// page index in both modes — in spread mode it just rounds down to
  /// the nearest even number to anchor the displayed pair.
  Widget _readerPageView({required bool spread}) {
    final colors = context.colors;
    return CurlPageView(
      key: ValueKey(spread ? 'reader-spread' : 'reader-single'),
      controller: _pageController,
      pageCount: _flatIndex.length,
      spread: spread,
      animationsEnabled: widget.animationsEnabled,
      pageInsets: const EdgeInsets.fromLTRB(12, 12, 12, 8),
      onPageChanged: _onPageChanged,
      onMiddleTap: () => setState(() => _chromeShown = !_chromeShown),
      pageBuilder: (leafCtx, idx) {
        if (idx < 0 || idx >= _flatIndex.length) {
          return Container(color: colors.canvas);
        }
        return _buildFlatPage(leafCtx, idx);
      },
    );
  }

  Widget _buildFlatPage(BuildContext leafCtx, int idx) {
    final m = _flatIndex[idx];
    final seg = _book.segments[m.seg];
    final page = _pagesForSegment(seg)[m.page];
    final colors = context.colors;
    // Page card chrome — same cue as iOS: rounded corners + hairline +
    // drop shadow on a cooler canvas so the page reads as a real leaf
    // rather than pasted onto the device. Outer padding is supplied by
    // CurlPageView via `pageInsets` so the curl shader's container rect
    // matches the visible card. In spread mode we drop the rounding on
    // the spine-side corners so the two pages meet flush, like the
    // facing pages of a real book.
    final side = LeafSideScope.of(leafCtx);
    const outerRadius = Radius.circular(6);
    final borderRadius = switch (side) {
      LeafSide.single => const BorderRadius.all(outerRadius),
      LeafSide.left => const BorderRadius.only(
          topLeft: outerRadius, bottomLeft: outerRadius),
      LeafSide.right => const BorderRadius.only(
          topRight: outerRadius, bottomRight: outerRadius),
    };
    return Container(
      decoration: BoxDecoration(
        color: colors.canvas,
        borderRadius: borderRadius,
        border: Border.all(color: colors.hairlineStrong),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.18),
            blurRadius: 14,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: _PageView(
        page: page,
        pageIdx: m.page,
        chapterLabel: _displayChapterLabel(m.seg),
        annotations: _annotations,
        segmentId: seg.id,
        onParagraphLongPress: (pIdx, text, globalPos) =>
            _onParagraphLongPress(m.seg, m.page, pIdx, text, globalPos),
        onSelectionAction: (pIdx, text, start, end, type) =>
            _onSelectionAction(m.seg, m.page, pIdx, text, start, end, type),
      ),
    );
  }
}

