import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import '../alignment/alignment_service.dart';
import '../alignment/alignment_types.dart';
import '../alignment/transcription_task_handler.dart';
import '../import/ebook_importer.dart';
import '../import/mobi_importer.dart';
import '../import/pdf_importer.dart';
import '../persistence/library_storage.dart';

/// In-flight alignment for a single book. [stream] is a broadcast, so
/// late subscribers should read [lastStage] for the current snapshot
/// and listen for events from there.
class AlignmentJob extends ChangeNotifier {
  AlignmentJob(this.bookId);
  final String bookId;
  final _controller = StreamController<AlignStage>.broadcast();
  AlignStage _lastStage = const AlignStage('Preparing…');
  bool _completed = false;
  Object? _error;

  Stream<AlignStage> get stream => _controller.stream;
  AlignStage get lastStage => _lastStage;
  bool get isCompleted => _completed;
  Object? get error => _error;
  bool get failed => _error != null;

  void _emit(AlignStage stage) {
    _lastStage = stage;
    if (!_controller.isClosed) _controller.add(stage);
    notifyListeners();
  }

  void _complete() {
    _completed = true;
    if (!_controller.isClosed) _controller.close();
    notifyListeners();
  }

  void _fail(Object err) {
    _error = err;
    _completed = true;
    if (!_controller.isClosed) {
      _controller.addError(err);
      _controller.close();
    }
    notifyListeners();
  }

  @override
  void dispose() {
    if (!_controller.isClosed) _controller.close();
    super.dispose();
  }
}

class LibraryStore extends ChangeNotifier {
  final LibraryStorage storage;
  final AlignmentService alignment;
  final List<StoredBook> _books = [];
  final Map<String, AlignmentJob> _alignmentJobs = {};
  bool _loaded = false;
  bool _importing = false;
  String? _lastError;

  LibraryStore({LibraryStorage? storage, AlignmentService? alignment})
      : storage = storage ?? LibraryStorage(),
        alignment = alignment ??
            AlignmentService(storage: storage ?? LibraryStorage());

  List<StoredBook> get books => List.unmodifiable(_books);
  bool get isImporting => _importing;
  bool get isLoaded => _loaded;
  String? get lastError => _lastError;

  AlignmentJob? alignmentJobFor(String bookId) => _alignmentJobs[bookId];

  bool isAligning(String bookId) {
    final j = _alignmentJobs[bookId];
    return j != null && !j.isCompleted;
  }

  Future<void> load() async {
    try {
      final all = await storage.loadAll();
      _books
        ..clear()
        ..addAll(all);
    } catch (e) {
      // Path provider can be unavailable in widget tests; degrade gracefully
      // to an empty in-memory library rather than crashing the UI.
      _lastError = 'Failed to load library: $e';
    }
    _loaded = true;
    notifyListeners();
  }

  Future<StoredBook?> importViaCalibre(File source) async {
    _importing = true;
    _lastError = null;
    notifyListeners();
    Directory? tmpDir;
    final label = source.path.split('.').last.toUpperCase();
    try {
      tmpDir = await Directory.systemTemp.createTemp('palimp_calibre_');
      final tmpEpub = File('${tmpDir.path}/converted.epub');
      final exe = Platform.environment['PALIMPSEST_EBOOK_CONVERT'] ??
          (Platform.isWindows ? 'ebook-convert.exe' : 'ebook-convert');
      final proc = await Process.run(exe, [source.path, tmpEpub.path]);
      if (proc.exitCode != 0 || !tmpEpub.existsSync()) {
        _lastError =
            '$label conversion failed. Install Calibre and ensure '
            '`ebook-convert` is on PATH (or set PALIMPSEST_EBOOK_CONVERT).'
            '\n${proc.stderr}';
        return null;
      }
      // Hand off to the EPUB importer; clear the flag first so it can
      // re-set it without tripping the double-import guard.
      _importing = false;
      return await importEPUB(tmpEpub);
    } on ProcessException catch (e) {
      _lastError =
          '$label conversion failed: ${e.message}. '
          'Install Calibre and ensure `ebook-convert` is on PATH '
          '(or set PALIMPSEST_EBOOK_CONVERT).';
      return null;
    } catch (e) {
      _lastError = '$label conversion failed: $e';
      return null;
    } finally {
      try {
        tmpDir?.deleteSync(recursive: true);
      } catch (_) {}
      _importing = false;
      notifyListeners();
    }
  }

  Future<StoredBook?> importBook(File file) {
    final lower = file.path.toLowerCase();
    if (lower.endsWith('.epub')) return importEPUB(file);
    if (lower.endsWith('.mobi') ||
        lower.endsWith('.prc') ||
        lower.endsWith('.azw')) {
      return importMOBI(file);
    }
    if (lower.endsWith('.pdf') && Platform.isAndroid) return importPDF(file);
    return importViaCalibre(file);
  }

  Future<StoredBook?> importEPUB(File file) =>
      _runImport(file, 'book.epub', const EPUBImporter());

  Future<StoredBook?> importMOBI(File file) =>
      _runImport(file, 'book.mobi', const MOBIImporter());

  // Android only; desktop goes through importViaCalibre for better fidelity.
  Future<StoredBook?> importPDF(File file) =>
      _runImport(file, 'book.pdf', const PDFImporter());

  Future<StoredBook?> _runImport(
    File source,
    String storedFilename,
    EBookImporter importer,
  ) async {
    _importing = true;
    _lastError = null;
    notifyListeners();
    try {
      final imported = await importer.importBook(source);
      final id = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
      final dir = await storage.bookDir(id);
      final dest = File('${dir.path}/$storedFilename');
      await source.copy(dest.path);

      String? coverPath;
      if (imported.coverImageData != null) {
        final c = File('${dir.path}/cover');
        await c.writeAsBytes(imported.coverImageData!);
        coverPath = c.path;
      }

      final book = StoredBook(
        id: id,
        title: imported.title,
        author: imported.author,
        segments: imported.segments,
        coverPath: coverPath,
        addedAt: DateTime.now().toUtc(),
      );
      await storage.save(book);
      _books.insert(0, book);
      return book;
    } catch (e) {
      _lastError = e.toString();
      return null;
    } finally {
      _importing = false;
      notifyListeners();
    }
  }

  Future<StoredBook> attachAudio(StoredBook book, File audio) async {
    final dir = await storage.bookDir(book.id);
    final ext = audio.path.split('.').last;
    final dest = File('${dir.path}/audiobook.$ext');

    _clearStaleAudioArtifacts(dir);
    await audio.copy(dest.path);

    final updated = _withReplacedAudio(book, audioPath: dest.path);
    await _replace(updated);
    return updated;
  }

  /// Drops every prior `audiobook.*` file (the new pick may have a different
  /// extension) and the alignment JSON it was computed against. Without this,
  /// swapping in a different audiobook would leave a stale alignment.json
  /// that the next reader open would happily reload — wrong word timestamps,
  /// paragraphs jumping to the wrong audio position.
  void _clearStaleAudioArtifacts(Directory dir) {
    for (final entity in dir.listSync()) {
      if (entity is! File) continue;
      final name = entity.uri.pathSegments.last;
      if (name.startsWith('audiobook.') || name == 'alignment.json') {
        try {
          entity.deleteSync();
        } catch (_) {}
      }
    }
  }

  /// `copyWith` can't set `alignmentPath` back to null (its `?? this.x`
  /// keeps the old value when you pass null), so we build directly.
  StoredBook _withReplacedAudio(StoredBook book, {required String audioPath}) =>
      StoredBook(
        id: book.id,
        title: book.title,
        author: book.author,
        segments: book.segments,
        coverPath: book.coverPath,
        audioPath: audioPath,
        alignmentPath: null,
        addedAt: book.addedAt,
        currentSegmentIndex: book.currentSegmentIndex,
        currentPageInChapter: book.currentPageInChapter,
        currentAudioSeconds: book.currentAudioSeconds,
      );

  Future<AlignmentMap?> loadAlignment(StoredBook book) =>
      storage.loadAlignment(book);

  /// Returns the existing job for [book] if one is in flight, otherwise
  /// starts a new one. Detached from the caller — survives UI disposal.
  AlignmentJob startAlignment(StoredBook book) {
    final existing = _alignmentJobs[book.id];
    if (existing != null && !existing.isCompleted) return existing;
    final job = AlignmentJob(book.id);
    _alignmentJobs[book.id] = job;
    notifyListeners();
    // Detached: errors are routed through job._fail, not rethrown.
    // ignore: discarded_futures
    _runAlignmentJob(book, job);
    return job;
  }

  Future<void> _runAlignmentJob(StoredBook book, AlignmentJob job) async {
    try {
      // Android: foreground service so the OS won't kill the isolate
      // when the app is backgrounded. Other platforms run inline.
      if (Platform.isAndroid) {
        await _runAlignmentViaForegroundService(book, job);
      } else {
        await _runAlignmentInline(book, job);
      }
      final dir = await storage.bookDir(book.id);
      final fresh = _books.firstWhere(
        (b) => b.id == book.id,
        orElse: () => book,
      );
      final updated = fresh.copyWith(
        alignmentPath: '${dir.path}/alignment.json',
      );
      await _replace(updated);
      job._complete();
    } catch (e, st) {
      debugPrint('alignment error for ${book.id}: $e\n$st');
      job._fail(e);
    } finally {
      // Drop on the next microtask so subscribers attached during the
      // final emit still see the close event.
      scheduleMicrotask(() {
        _alignmentJobs.remove(book.id);
        notifyListeners();
      });
    }
  }

  Future<void> _runAlignmentInline(StoredBook book, AlignmentJob job) async {
    await for (final stage in alignment.alignBook(book)) {
      job._emit(stage);
    }
  }

  Future<void> _runAlignmentViaForegroundService(
    StoredBook book,
    AlignmentJob job,
  ) async {
    final completer = Completer<void>();
    void callback(Object data) {
      if (data is! String) return;
      final msg = jsonDecode(data) as Map<String, dynamic>;
      if (msg['bookId'] != book.id) return;
      switch (msg['event']) {
        case 'stage':
          final fraction = msg['fraction'];
          job._emit(AlignStage(
            msg['label'] as String,
            fraction: fraction is num ? fraction.toDouble() : null,
          ));
        case 'done':
          if (!completer.isCompleted) completer.complete();
        case 'error':
          if (!completer.isCompleted) {
            completer.completeError(StateError(msg['message'] as String));
          }
      }
    }

    FlutterForegroundTask.addTaskDataCallback(callback);
    try {
      await _ensureForegroundServiceInitialized();
      final permission =
          await FlutterForegroundTask.checkNotificationPermission();
      if (permission != NotificationPermission.granted) {
        final granted =
            await FlutterForegroundTask.requestNotificationPermission();
        if (granted != NotificationPermission.granted) {
          // Without notification grant the OS rejects the service silently;
          // fall back to inline so the user still gets their transcript.
          await _runAlignmentInline(book, job);
          return;
        }
      }
      // MethodChannel args don't reach TaskHandler.onStart; round-trip
      // the book id via the plugin's prefs store instead.
      await FlutterForegroundTask.saveData(key: 'bookId', value: book.id);
      final result = await FlutterForegroundTask.startService(
        serviceId: 5552,
        notificationTitle: 'Aligning audiobook',
        notificationText: 'Preparing ${book.title}',
        callback: startTranscriptionTaskHandler,
      );
      if (result is ServiceRequestFailure) {
        debugPrint('foreground service start failed: ${result.error}');
        await _runAlignmentInline(book, job);
        return;
      }
      await completer.future;
    } catch (e, st) {
      debugPrint('foreground service path threw, falling back inline: $e\n$st');
      await _runAlignmentInline(book, job);
    } finally {
      FlutterForegroundTask.removeTaskDataCallback(callback);
      if (await FlutterForegroundTask.isRunningService) {
        await FlutterForegroundTask.stopService();
      }
    }
  }

  bool _foregroundInitialized = false;
  Future<void> _ensureForegroundServiceInitialized() async {
    if (_foregroundInitialized) return;
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'com.rexhep.palimpsest.transcription',
        channelName: 'Audiobook transcription',
        channelDescription:
            'Progress for the audiobook alignment running in background.',
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
      ),
      iosNotificationOptions: const IOSNotificationOptions(),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.nothing(),
        autoRunOnBoot: false,
        autoRunOnMyPackageReplaced: false,
        allowWakeLock: true,
        allowWifiLock: false,
      ),
    );
    _foregroundInitialized = true;
  }

  Future<void> updateProgress(
    StoredBook book, {
    int? segmentIndex,
    int? pageInChapter,
    double? audioSeconds,
  }) async {
    final updated = book.copyWith(
      currentSegmentIndex: segmentIndex,
      currentPageInChapter: pageInChapter,
      currentAudioSeconds: audioSeconds,
    );
    await _replace(updated, notify: false);
  }

  Future<void> _replace(StoredBook updated, {bool notify = true}) async {
    final i = _books.indexWhere((b) => b.id == updated.id);
    if (i >= 0) _books[i] = updated;
    await storage.save(updated);
    if (notify) notifyListeners();
  }

  Future<void> delete(StoredBook book) async {
    await storage.delete(book.id);
    _books.removeWhere((b) => b.id == book.id);
    notifyListeners();
  }
}
