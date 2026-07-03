import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:path_provider/path_provider.dart';

import '../alignment/alignment_types.dart';

/// Per-book on-disk record under the platform's application support dir:
/// `Books/<id>/book.epub`, `book.json` (metadata + segments),
/// `audiobook.<ext>` (optional), `alignment.json` (optional, AlignmentMap),
/// `cover` (optional bytes). Mirrors the Apple build's layout under
/// `~/Library/Application Support/InkAndEcho/Books/...` so a future sync
/// feature can ship without a migration.
class StoredBook {
  final String id;
  final String title;
  final String author;
  final List<TextSegment> segments;
  final String? coverPath;
  final String? audioPath;
  final String? alignmentPath;
  final DateTime addedAt;
  final int currentSegmentIndex;
  final int currentPageInChapter;
  final double? currentAudioSeconds;

  const StoredBook({
    required this.id,
    required this.title,
    required this.author,
    required this.segments,
    this.coverPath,
    this.audioPath,
    this.alignmentPath,
    required this.addedAt,
    this.currentSegmentIndex = 0,
    this.currentPageInChapter = 0,
    this.currentAudioSeconds,
  });

  StoredBook copyWith({
    String? audioPath,
    String? alignmentPath,
    int? currentSegmentIndex,
    int? currentPageInChapter,
    double? currentAudioSeconds,
  }) =>
      StoredBook(
        id: id,
        title: title,
        author: author,
        segments: segments,
        coverPath: coverPath,
        audioPath: audioPath ?? this.audioPath,
        alignmentPath: alignmentPath ?? this.alignmentPath,
        addedAt: addedAt,
        currentSegmentIndex: currentSegmentIndex ?? this.currentSegmentIndex,
        currentPageInChapter:
            currentPageInChapter ?? this.currentPageInChapter,
        currentAudioSeconds: currentAudioSeconds ?? this.currentAudioSeconds,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'author': author,
        'segments': segments
            .map((s) => {'id': s.id, 'title': s.title, 'text': s.text})
            .toList(growable: false),
        'coverPath': coverPath,
        'audioPath': audioPath,
        'alignmentPath': alignmentPath,
        'addedAt': addedAt.toUtc().toIso8601String(),
        'currentSegmentIndex': currentSegmentIndex,
        'currentPageInChapter': currentPageInChapter,
        'currentAudioSeconds': currentAudioSeconds,
      };

  factory StoredBook.fromJson(Map<String, dynamic> j) => StoredBook(
        id: j['id'] as String,
        title: j['title'] as String,
        author: j['author'] as String,
        segments: (j['segments'] as List)
            .map((e) => TextSegment(
                  id: (e as Map<String, dynamic>)['id'] as String,
                  title: e['title'] as String?,
                  text: e['text'] as String,
                ))
            .toList(growable: false),
        coverPath: j['coverPath'] as String?,
        audioPath: j['audioPath'] as String?,
        alignmentPath: j['alignmentPath'] as String?,
        addedAt: DateTime.parse(j['addedAt'] as String),
        currentSegmentIndex: (j['currentSegmentIndex'] as int?) ?? 0,
        currentPageInChapter: (j['currentPageInChapter'] as int?) ?? 0,
        currentAudioSeconds: (j['currentAudioSeconds'] as num?)?.toDouble(),
      );
}

class LibraryStorage {
  Directory? _root;

  Future<Directory> _ensureRoot() async {
    if (_root != null) return _root!;
    final base = await getApplicationSupportDirectory();
    final root = Directory('${base.path}/Books');
    if (!root.existsSync()) await root.create(recursive: true);
    _root = root;
    return root;
  }

  Future<Directory> bookDir(String id) async {
    final root = await _ensureRoot();
    final dir = Directory('${root.path}/$id');
    if (!dir.existsSync()) await dir.create(recursive: true);
    return dir;
  }

  Future<List<StoredBook>> loadAll() async {
    final root = await _ensureRoot();
    final out = <StoredBook>[];
    for (final entity in root.listSync()) {
      if (entity is! Directory) continue;
      final manifest = File('${entity.path}/book.json');
      if (!manifest.existsSync()) continue;
      try {
        final j = jsonDecode(await manifest.readAsString())
            as Map<String, dynamic>;
        out.add(StoredBook.fromJson(j));
      } catch (_) {
        // Corrupt manifest — skip rather than crash the library load.
      }
    }
    out.sort((a, b) => b.addedAt.compareTo(a.addedAt));
    return out;
  }

  Future<void> save(StoredBook book) async {
    final dir = await bookDir(book.id);
    await File('${dir.path}/book.json')
        .writeAsString(jsonEncode(book.toJson()));
  }

  /// Load a single book by id. Returns null if the manifest is missing
  /// or corrupt; never throws.
  Future<StoredBook?> find(String id) async {
    final dir = await bookDir(id);
    final manifest = File('${dir.path}/book.json');
    if (!manifest.existsSync()) return null;
    try {
      final j = jsonDecode(await manifest.readAsString())
          as Map<String, dynamic>;
      return StoredBook.fromJson(j);
    } catch (_) {
      return null;
    }
  }

  Future<void> delete(String id) async {
    final dir = await bookDir(id);
    if (dir.existsSync()) await dir.delete(recursive: true);
  }

  Future<AlignmentMap?> loadAlignment(StoredBook book) async {
    if (book.alignmentPath == null) return null;
    final f = File(book.alignmentPath!);
    if (!f.existsSync()) return null;
    // Multi-MB JSON: parse off the main isolate so opening an aligned book
    // doesn't jank the UI. (Isolate.run rather than compute() keeps this
    // file Flutter-free.)
    final json = await f.readAsString();
    return Isolate.run(() => AlignmentMap.fromJsonString(json));
  }

  Future<String> writeAlignment(
    StoredBook book,
    AlignmentMap map,
  ) async {
    final dir = await bookDir(book.id);
    final f = File('${dir.path}/alignment.json');
    await f.writeAsString(map.toJsonString());
    return f.path;
  }
}
