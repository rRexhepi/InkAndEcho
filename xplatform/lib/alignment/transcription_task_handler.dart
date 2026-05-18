import 'dart:async';
import 'dart:convert';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import '../persistence/library_storage.dart';
import 'alignment_service.dart';

/// Foreground-service isolate entry point. The book id is read from
/// [FlutterForegroundTask]'s key/value store rather than handler args
/// because plain MethodChannel arguments aren't bridged into onStart.
@pragma('vm:entry-point')
void startTranscriptionTaskHandler() {
  // Re-register plugin instances for this service isolate; path_provider
  // and friends won't resolve their MethodChannels without it.
  DartPluginRegistrant.ensureInitialized();
  FlutterForegroundTask.setTaskHandler(_TranscriptionTaskHandler());
}

class _TranscriptionTaskHandler extends TaskHandler {
  StreamSubscription? _sub;
  String? _bookId;

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    final bookId = await FlutterForegroundTask.getData<String>(key: 'bookId');
    if (bookId == null) {
      await _failAndStop('Missing bookId for alignment service.');
      return;
    }
    _bookId = bookId;

    final storage = LibraryStorage();
    final book = await storage.find(bookId);
    if (book == null) {
      await _failAndStop('No book with id=$bookId on storage.');
      return;
    }
    if (book.audioPath == null) {
      await _failAndStop('Book has no audio to transcribe.');
      return;
    }

    final service = AlignmentService(storage: storage);
    _sub = service.alignBook(book).listen(
      (stage) {
        final pct = stage.fraction == null
            ? null
            : (stage.fraction!.clamp(0.0, 1.0) * 100).round();
        FlutterForegroundTask.updateService(
          notificationTitle: 'Aligning audiobook',
          notificationText: pct == null
              ? '${stage.label} · ${book.title}'
              : '$pct% · ${stage.label}',
        );
        FlutterForegroundTask.sendDataToMain(jsonEncode({
          'event': 'stage',
          'bookId': bookId,
          'label': stage.label,
          'fraction': stage.fraction,
        }));
      },
      onError: (Object e, StackTrace st) async {
        debugPrint('alignment service error: $e\n$st');
        FlutterForegroundTask.sendDataToMain(jsonEncode({
          'event': 'error',
          'bookId': bookId,
          'message': '$e',
        }));
        await FlutterForegroundTask.stopService();
      },
      onDone: () async {
        FlutterForegroundTask.sendDataToMain(jsonEncode({
          'event': 'done',
          'bookId': bookId,
        }));
        await FlutterForegroundTask.stopService();
      },
    );
  }

  Future<void> _failAndStop(String message) async {
    FlutterForegroundTask.sendDataToMain(jsonEncode({
      'event': 'error',
      'bookId': _bookId,
      'message': message,
    }));
    await FlutterForegroundTask.stopService();
  }

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {
    await _sub?.cancel();
    _sub = null;
  }

  @override
  void onRepeatEvent(DateTime timestamp) {}
}
