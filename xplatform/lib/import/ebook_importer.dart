import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:xml/xml.dart';

import '../alignment/alignment_types.dart';

/// Result of importing an ebook: enough metadata for the library + the
/// segmented text the aligner needs.
class ImportedBook {
  final String title;
  final String author;
  final Uint8List? coverImageData;
  final List<TextSegment> segments;

  const ImportedBook({
    required this.title,
    required this.author,
    this.coverImageData,
    required this.segments,
  });
}

class ImporterError implements Exception {
  final String message;
  const ImporterError(this.message);
  @override
  String toString() => 'ImporterError: $message';
}

abstract class EBookImporter {
  Future<ImportedBook> importBook(File file);
}

/// Pure-Dart port of `EPUBImporter` from InkAndEchoCore/Import/EBookImporter.swift.
/// Parses an EPUB 2 or EPUB 3 archive into the same shape the Apple build
/// produces, so an `alignment.json` from either platform aligns the same
/// ebook to the same `segmentId`s.
class EPUBImporter implements EBookImporter {
  const EPUBImporter();

  @override
  Future<ImportedBook> importBook(File file) async {
    final bytes = await file.readAsBytes();
    final Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(bytes);
    } catch (e) {
      throw ImporterError('Cannot open archive: $e');
    }

    final containerXml = _extractText(archive, 'META-INF/container.xml');
    final opfPath = _parseContainer(containerXml);
    final opf = _parseOPF(_extractText(archive, opfPath));
    final opfDir = _dirname(opfPath);

    final tocEntries = _loadToc(archive, opf, opfDir);
    final segments = _buildSegments(archive, opf, opfDir, tocEntries);
    final cover = _extractCover(archive, opf, opfDir);

    return ImportedBook(
      title: opf.title,
      author: opf.author,
      coverImageData: cover,
      segments: segments,
    );
  }

  List<_TocEntry> _loadToc(Archive archive, _OPFData opf, String opfDir) {
    if (opf.navHref != null) {
      final navPath = _resolvePath(opf.navHref!, opfDir);
      final xhtml = _extractTextOrNull(archive, navPath);
      if (xhtml != null) {
        final entries = _parseNavTOC(xhtml);
        if (entries.isNotEmpty) return entries;
      }
    }
    if (opf.ncxHref != null) {
      final ncxPath = _resolvePath(opf.ncxHref!, opfDir);
      final xml = _extractTextOrNull(archive, ncxPath);
      if (xml != null) return _parseNCXTOC(xml);
    }
    return const [];
  }

  List<TextSegment> _buildSegments(
    Archive archive,
    _OPFData opf,
    String opfDir,
    List<_TocEntry> tocEntries,
  ) {
    final segments = <TextSegment>[];
    for (final itemref in opf.spine) {
      final item = opf.manifest[itemref];
      if (item == null) continue;
      final path = _resolvePath(item.href, opfDir);
      final xhtml = _extractTextOrNull(archive, path) ?? '';
      if (xhtml.isEmpty) continue;
      _appendSpineSegments(
        segments: segments,
        itemref: itemref,
        itemHref: item.href,
        xhtml: xhtml,
        tocEntries: tocEntries,
      );
    }
    return segments;
  }

  Uint8List? _extractCover(Archive archive, _OPFData opf, String opfDir) {
    if (opf.coverID == null) return null;
    final item = opf.manifest[opf.coverID];
    if (item == null) return null;
    final path = _resolvePath(item.href, opfDir);
    return _extractDataOrNull(archive, path);
  }
}

// MARK: - Archive helpers

String _extractText(Archive archive, String path) {
  final data = _extractData(archive, path);
  try {
    return utf8.decode(data);
  } catch (_) {
    throw ImporterError('Non-UTF8 entry: $path');
  }
}

String? _extractTextOrNull(Archive archive, String path) {
  try {
    return _extractText(archive, path);
  } catch (_) {
    return null;
  }
}

Uint8List _extractData(Archive archive, String path) {
  final entry = archive.findFile(path);
  if (entry == null) throw ImporterError('Missing entry: $path');
  return entry.content;
}

Uint8List? _extractDataOrNull(Archive archive, String path) {
  try {
    return _extractData(archive, path);
  } catch (_) {
    return null;
  }
}

String _resolvePath(String relative, String base) =>
    base.isEmpty ? relative : '$base/$relative';

String _dirname(String path) {
  final i = path.lastIndexOf('/');
  return i < 0 ? '' : path.substring(0, i);
}

// MARK: - container.xml

String _parseContainer(String xml) {
  final XmlDocument doc;
  try {
    doc = XmlDocument.parse(xml);
  } catch (e) {
    throw ImporterError('container.xml parse failed: $e');
  }
  final rootfile = doc.descendants
      .whereType<XmlElement>()
      .firstWhere((e) => _localName(e.name.qualified) == 'rootfile',
          orElse: () => throw const ImporterError('container.xml: no rootfile'));
  final path = rootfile.getAttribute('full-path');
  if (path == null || path.isEmpty) {
    throw const ImporterError('container.xml: rootfile missing full-path');
  }
  return path;
}

// MARK: - OPF

class _ManifestItem {
  final String id;
  final String href;
  final String mediaType;
  final String properties;
  const _ManifestItem({
    required this.id,
    required this.href,
    required this.mediaType,
    required this.properties,
  });
}

class _OPFData {
  final String title;
  final String author;
  final String? coverID;
  final Map<String, _ManifestItem> manifest;
  final List<String> spine;
  final String? navHref;
  final String? ncxHref;
  const _OPFData({
    required this.title,
    required this.author,
    this.coverID,
    required this.manifest,
    required this.spine,
    this.navHref,
    this.ncxHref,
  });
}

_OPFData _parseOPF(String xml) {
  final XmlDocument doc;
  try {
    doc = XmlDocument.parse(xml);
  } catch (e) {
    throw ImporterError('OPF parse failed: $e');
  }

  String? title;
  String? author;
  String? coverID;
  String? ncxId;
  final manifest = <String, _ManifestItem>{};
  final spine = <String>[];

  for (final el in doc.descendants.whereType<XmlElement>()) {
    switch (_localName(el.name.qualified)) {
      case 'title':
        title ??= el.innerText.trim().isEmpty ? null : el.innerText.trim();
        break;
      case 'creator':
        author ??= el.innerText.trim().isEmpty ? null : el.innerText.trim();
        break;
      case 'spine':
        ncxId = el.getAttribute('toc');
        break;
      case 'item':
        final id = el.getAttribute('id');
        final href = el.getAttribute('href');
        if (id == null || href == null) break;
        final properties = el.getAttribute('properties') ?? '';
        manifest[id] = _ManifestItem(
          id: id,
          href: href,
          mediaType: el.getAttribute('media-type') ?? '',
          properties: properties,
        );
        if (properties.contains('cover-image')) {
          coverID = id;
        }
        break;
      case 'itemref':
        final idref = el.getAttribute('idref');
        if (idref != null) spine.add(idref);
        break;
      case 'meta':
        final name = el.getAttribute('name');
        final content = el.getAttribute('content');
        if (name == 'cover' && content != null && coverID == null) {
          coverID = content;
        }
        break;
    }
  }

  if (title == null || manifest.isEmpty) {
    throw const ImporterError('OPF missing required title or manifest');
  }

  // Heuristic fallback when neither EPUB 3 properties="cover-image" nor
  // EPUB 2 <meta name="cover"> is present. Calibre-built EPUBs frequently
  // declare the cover only via <guide><reference type="cover"> pointing at
  // a title page, leaving the image findable only by filename.
  if (coverID == null) {
    for (final entry in manifest.entries) {
      final mt = entry.value.mediaType.toLowerCase();
      final href = entry.value.href.toLowerCase();
      if (mt.startsWith('image/') && href.contains('cover')) {
        coverID = entry.key;
        break;
      }
    }
  }

  String? navHref;
  for (final item in manifest.values) {
    if (item.properties.contains('nav')) {
      navHref = item.href;
      break;
    }
  }
  final ncxHref = ncxId != null ? manifest[ncxId]?.href : null;

  return _OPFData(
    title: title,
    author: author ?? 'Unknown',
    coverID: coverID,
    manifest: manifest,
    spine: spine,
    navHref: navHref,
    ncxHref: ncxHref,
  );
}

String _localName(String qualified) {
  final i = qualified.indexOf(':');
  return i < 0 ? qualified : qualified.substring(i + 1);
}

// Two paths matter: direct href match, and fragment-only match against
// anchors in the xhtml. The latter exists for Calibre-split EPUBs whose
// TOC hrefs all point at a virtual _toc.html that doesn't ship in the
// archive.
void _appendSpineSegments({
  required List<TextSegment> segments,
  required String itemref,
  required String itemHref,
  required String xhtml,
  required List<_TocEntry> tocEntries,
}) {
  final splits = _collectSplits(itemHref, xhtml, tocEntries);

  if (splits.isEmpty) {
    final plain = stripHTML(xhtml);
    if (plain.isEmpty) return;
    segments.add(TextSegment(
      id: itemref,
      title: _extractChapterTitle(xhtml),
      text: plain,
    ));
    return;
  }

  _appendPreamble(segments, itemref, xhtml, splits.first.offset);
  String? pendingTitle;
  for (var i = 0; i < splits.length; i++) {
    final start = splits[i].offset;
    final end = i + 1 < splits.length ? splits[i + 1].offset : xhtml.length;
    final plain = stripHTML(xhtml.substring(start, end));
    if (plain.isEmpty) continue;
    final hasBodyContent = plain.length > 120 || plain.contains('\n\n');
    if (!hasBodyContent && i + 1 < splits.length) {
      pendingTitle = splits[i].entry.title;
      continue;
    }
    final title = pendingTitle ?? splits[i].entry.title;
    pendingTitle = null;
    final fragKey = splits[i].entry.fragment ?? '$i';
    segments.add(TextSegment(
      id: '${itemref}_$fragKey',
      title: title,
      text: plain,
    ));
  }
  if (pendingTitle != null && segments.isNotEmpty) {
    final last = segments.last;
    segments[segments.length - 1] = TextSegment(
      id: last.id, title: pendingTitle, text: last.text,
    );
  }
}

class _Split {
  const _Split(this.entry, this.offset);
  final _TocEntry entry;
  final int offset;
}

List<_Split> _collectSplits(
    String itemHref, String xhtml, List<_TocEntry> tocEntries) {
  final hrefKey = itemHref.split('#').first;
  final splits = <_Split>[];
  final seen = <int>{};
  for (final e in tocEntries) {
    final hrefMatches = e.href == hrefKey;
    final int? offset = e.fragment == null
        ? (hrefMatches ? 0 : null)
        : _findAnchorOffset(xhtml, e.fragment!);
    if (offset == null) continue;
    // Drop Prev / Next / Up nav labels that happen to land on a real anchor.
    if (!hrefMatches &&
        !_looksLikeChapterTitle(e.title) &&
        _looksLikeNavLabel(e.title)) {
      continue;
    }
    if (!seen.add(offset)) continue;
    splits.add(_Split(e, offset));
  }
  splits.sort((a, b) => a.offset.compareTo(b.offset));
  return splits;
}

void _appendPreamble(
    List<TextSegment> out, String itemref, String xhtml, int firstSplitOffset) {
  if (firstSplitOffset <= 0) return;
  final preambleXhtml = xhtml.substring(0, firstSplitOffset);
  final preamble = stripHTML(preambleXhtml);
  if (preamble.length < _kPreambleMinChars) return;
  out.add(TextSegment(
    id: '${itemref}_preamble',
    title: _extractChapterTitle(preambleXhtml),
    text: preamble,
  ));
}

// Drop pre-first-anchor fragments shorter than this; below the threshold
// they're typically running-header reruns rather than real content.
const int _kPreambleMinChars = 150;

final RegExp _navLabelRe = RegExp(
  r'^\s*(prev(ious)?|next|up|back|home|top|continue|menu|index|table\s+of\s+contents)\s*$',
  caseSensitive: false,
);

bool _looksLikeNavLabel(String title) => _navLabelRe.hasMatch(title);

const _chapterishPrefixes = [
  'chapter', 'part', 'book', 'volume', 'prologue', 'epilogue',
  'preface', 'foreword', 'introduction', 'afterword', 'dedication',
];

bool _looksLikeChapterTitle(String title) {
  final t = title.trim().toLowerCase();
  if (t.isEmpty) return false;
  if (t.contains('appendix')) return true;
  return _chapterishPrefixes.any(t.startsWith);
}

int? _findAnchorOffset(String xhtml, String fragment) {
  final pattern =
      RegExp('\\bid=["\']${RegExp.escape(fragment)}["\']');
  final match = pattern.firstMatch(xhtml);
  if (match == null) return null;
  final tagStart = xhtml.lastIndexOf('<', match.start);
  return tagStart >= 0 ? tagStart : 0;
}

class _TocEntry {
  final String href;
  final String? fragment;
  final String title;
  const _TocEntry({required this.href, this.fragment, required this.title});
}

({String href, String? fragment}) _splitHref(String raw) {
  final i = raw.indexOf('#');
  if (i < 0) return (href: raw, fragment: null);
  return (
    href: raw.substring(0, i),
    fragment: i + 1 < raw.length ? raw.substring(i + 1) : null,
  );
}

// EPUB 3: walk every <a href> inside <nav epub:type="toc"> (or the
// first <nav> if none is explicitly tagged).
List<_TocEntry> _parseNavTOC(String xhtml) {
  final XmlDocument doc;
  try {
    doc = XmlDocument.parse(xhtml);
  } catch (_) {
    return const [];
  }
  final entries = <_TocEntry>[];

  XmlElement? tocNav;
  XmlElement? firstNav;
  for (final el in doc.descendants.whereType<XmlElement>()) {
    if (_localName(el.name.qualified) != 'nav') continue;
    firstNav ??= el;
    final type = el.getAttribute('epub:type') ??
        el.getAttribute('type') ??
        el.getAttribute('role') ??
        '';
    if (type.contains('toc')) {
      tocNav = el;
      break;
    }
  }
  final nav = tocNav ?? firstNav;
  if (nav == null) return const [];

  for (final a in nav.descendants.whereType<XmlElement>()) {
    if (_localName(a.name.qualified) != 'a') continue;
    final raw = a.getAttribute('href');
    if (raw == null) continue;
    final title = a.innerText.trim();
    if (title.isEmpty) continue;
    final parts = _splitHref(raw);
    entries.add(_TocEntry(
      href: parts.href,
      fragment: parts.fragment,
      title: title,
    ));
  }
  return entries;
}

// EPUB 2 NCX: each navPoint has a content[src] and a navLabel/text.
List<_TocEntry> _parseNCXTOC(String xml) {
  final XmlDocument doc;
  try {
    doc = XmlDocument.parse(xml);
  } catch (_) {
    return const [];
  }
  final entries = <_TocEntry>[];
  for (final np in doc.descendants.whereType<XmlElement>()) {
    if (_localName(np.name.qualified) != 'navPoint') continue;
    String? src;
    String? title;
    for (final c in np.children.whereType<XmlElement>()) {
      final ln = _localName(c.name.qualified);
      if (ln == 'content') {
        src = c.getAttribute('src');
      } else if (ln == 'navLabel') {
        for (final t in c.descendants.whereType<XmlElement>()) {
          if (_localName(t.name.qualified) == 'text') {
            title = t.innerText.trim();
            break;
          }
        }
      }
    }
    if (src != null && title != null && title.isNotEmpty) {
      final parts = _splitHref(src);
      entries.add(_TocEntry(
        href: parts.href,
        fragment: parts.fragment,
        title: title,
      ));
    }
  }
  return entries;
}

// MARK: - Chapter title extraction

String? _extractChapterTitle(String xhtml) {
  for (final tag in const ['h1', 'h2', 'h3', 'title']) {
    final m = RegExp('<$tag\\b[^>]*>([\\s\\S]*?)</$tag>',
            caseSensitive: false)
        .firstMatch(xhtml);
    if (m == null) continue;
    final cleaned = stripHTML(m.group(1) ?? '').trim();
    if (cleaned.isNotEmpty) return cleaned;
  }
  return null;
}

// MARK: - HTML stripping

final _scriptRe = RegExp(r'<script[^>]*>[\s\S]*?</script>', caseSensitive: false);
final _styleRe = RegExp(r'<style[^>]*>[\s\S]*?</style>', caseSensitive: false);
final _tagRe = RegExp(r'<[^>]+>');
final _numericEntityRe = RegExp(r'&#\d+;');
final _spacesTabsRe = RegExp(r'[ \t]+');
final _newlineSpaceRe = RegExp(r'\n[ \t]+');
final _multiNewlineRe = RegExp(r'\n{3,}');

String stripHTML(String html) {
  var text = html.replaceAll(_scriptRe, '').replaceAll(_styleRe, '');

  const blockEnds = [
    '</p>', '</div>', '</h1>', '</h2>', '</h3>',
    '</h4>', '</h5>', '</li>', '</blockquote>', '</section>',
  ];
  for (final tag in blockEnds) {
    text = text.replaceAll(RegExp(RegExp.escape(tag), caseSensitive: false), '\n\n');
  }
  for (final br in const ['<br/>', '<br />', '<br>']) {
    text = text.replaceAll(RegExp(RegExp.escape(br), caseSensitive: false), '\n');
  }

  text = text.replaceAll(_tagRe, '');

  const entities = {
    '&amp;': '&',
    '&lt;': '<',
    '&gt;': '>',
    '&quot;': '"',
    '&apos;': "'",
    '&#39;': "'",
    '&nbsp;': ' ',
    '&mdash;': '—',
    '&ndash;': '–',
    '&hellip;': '…',
    '&ldquo;': '“',
    '&rdquo;': '”',
    '&lsquo;': '‘',
    '&rsquo;': '’',
  };
  entities.forEach((k, v) => text = text.replaceAll(k, v));
  text = text.replaceAll(_numericEntityRe, '');

  text = text
      .replaceAll(_spacesTabsRe, ' ')
      .replaceAll(_newlineSpaceRe, '\n')
      .replaceAll(_multiNewlineRe, '\n\n');

  return text.trim();
}
