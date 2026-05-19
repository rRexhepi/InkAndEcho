import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:sherpa_onnx/sherpa_onnx.dart' as so;

import '../alignment/aligner.dart';

/// Configuration handed to a freshly spawned worker isolate so it can stand
/// up its own [so.OfflineRecognizer] without needing any shared state
/// from the host.
class _WorkerInit {
  const _WorkerInit({
    required this.mainPort,
    required this.encoderPath,
    required this.decoderPath,
    required this.tokensPath,
    required this.useNNAPI,
    required this.numThreads,
  });

  final SendPort mainPort;
  final String encoderPath;
  final String decoderPath;
  final String tokensPath;
  final bool useNNAPI;
  final int numThreads;
}

/// One transcribe request shipped from host → worker. Carries the PCM
/// samples as [TransferableTypedData] so the buffer moves zero-copy.
class _Request {
  const _Request({
    required this.id,
    required this.samples,
    required this.sampleCount,
    required this.sampleRate,
  });

  final int id;
  final TransferableTypedData samples;
  final int sampleCount;
  final int sampleRate;
}

class _Response {
  const _Response({required this.id, this.words, this.error});
  final int id;
  final List<AudioWord>? words;
  final String? error;
}

/// A single Whisper inference worker, backed by a dedicated Dart isolate.
/// The isolate owns its own sherpa_onnx [so.OfflineRecognizer]; the host
/// just hands it sample buffers and awaits the resulting [AudioWord]s.
///
/// One worker handles one request at a time — [WhisperWorkerPool] is what
/// spreads work across N of these.
class WhisperWorker {
  WhisperWorker._();

  Isolate? _isolate;
  SendPort? _sendPort;
  final ReceivePort _receivePort = ReceivePort();
  int _nextId = 0;
  Completer<List<AudioWord>>? _pending;
  bool _disposed = false;

  bool get isBusy => _pending != null;

  /// Spawn the worker and wait for it to load the model. Throws if the
  /// recognizer fails to initialise.
  static Future<WhisperWorker> spawn({
    required String encoderPath,
    required String decoderPath,
    required String tokensPath,
    required bool useNNAPI,
    required int numThreads,
  }) async {
    final worker = WhisperWorker._();
    final ready = Completer<SendPort>();

    worker._receivePort.listen((msg) {
      if (msg is SendPort && !ready.isCompleted) {
        ready.complete(msg);
        return;
      }
      if (msg is _Response) {
        final c = worker._pending;
        worker._pending = null;
        if (c == null) return;
        if (msg.error != null) {
          c.completeError(StateError(msg.error!));
        } else {
          c.complete(msg.words ?? const []);
        }
      }
    });

    worker._isolate = await Isolate.spawn<_WorkerInit>(
      _entry,
      _WorkerInit(
        mainPort: worker._receivePort.sendPort,
        encoderPath: encoderPath,
        decoderPath: decoderPath,
        tokensPath: tokensPath,
        useNNAPI: useNNAPI,
        numThreads: numThreads,
      ),
    );

    worker._sendPort = await ready.future;
    return worker;
  }

  /// Send a chunk of PCM samples to the worker. One request at a time —
  /// callers should consult [isBusy] and route to a different worker if so.
  Future<List<AudioWord>> transcribe(
    Float32List samples,
    int sampleRate,
  ) {
    if (_disposed) {
      throw StateError('WhisperWorker is disposed');
    }
    if (_pending != null) {
      throw StateError(
        'WhisperWorker is already processing a request; use a WhisperWorkerPool',
      );
    }
    final c = Completer<List<AudioWord>>();
    _pending = c;
    // Wrap as a Uint8List view bounded to the actual sample bytes so
    // TransferableTypedData doesn't transfer extra padding when `samples`
    // is a view into a larger buffer.
    final bytes = Uint8List.view(
      samples.buffer,
      samples.offsetInBytes,
      samples.lengthInBytes,
    );
    final ttd = TransferableTypedData.fromList([bytes]);
    _sendPort!.send(_Request(
      id: _nextId++,
      samples: ttd,
      sampleCount: samples.length,
      sampleRate: sampleRate,
    ));
    return c.future;
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _receivePort.close();
    final c = _pending;
    _pending = null;
    if (c != null && !c.isCompleted) {
      c.completeError(StateError('WhisperWorker disposed'));
    }
  }
}

/// Manages a pool of [WhisperWorker]s. Callers dispatch transcribe
/// requests through [transcribe]; the pool blocks them until a worker is
/// free, providing natural backpressure so we never have more than
/// [_workers.length] sample buffers in flight.
class WhisperWorkerPool {
  WhisperWorkerPool._(this._workers);

  final List<WhisperWorker> _workers;
  final List<Completer<void>> _waiters = [];
  bool _disposed = false;

  int get size => _workers.length;

  /// Spawn [count] workers in parallel.
  static Future<WhisperWorkerPool> spawn({
    required String encoderPath,
    required String decoderPath,
    required String tokensPath,
    required bool useNNAPI,
    required int count,
    required int numThreadsPerWorker,
  }) async {
    final workers = await Future.wait([
      for (var i = 0; i < count; i++)
        WhisperWorker.spawn(
          encoderPath: encoderPath,
          decoderPath: decoderPath,
          tokensPath: tokensPath,
          useNNAPI: useNNAPI,
          numThreads: numThreadsPerWorker,
        ),
    ]);
    return WhisperWorkerPool._(workers);
  }

  /// Send a chunk for transcription. Resolves with the resulting word list
  /// when one of the workers finishes processing it. If all workers are
  /// busy, the call awaits until one frees up — that's the pool's
  /// backpressure mechanism, capping memory at `size * chunkBytes`.
  Future<List<AudioWord>> transcribe(
    Float32List samples,
    int sampleRate,
  ) async {
    if (_disposed) {
      throw StateError('WhisperWorkerPool is disposed');
    }
    final worker = await _acquire();
    final result = await worker.transcribe(samples, sampleRate);
    _release();
    return result;
  }

  Future<WhisperWorker> _acquire() async {
    while (true) {
      for (final w in _workers) {
        if (!w.isBusy) return w;
      }
      // No idle worker — park a waiter and let _release wake us up when
      // a worker finishes. _release pops the oldest waiter, so requests
      // are dispatched FIFO.
      final c = Completer<void>();
      _waiters.add(c);
      await c.future;
    }
  }

  void _release() {
    if (_waiters.isEmpty) return;
    _waiters.removeAt(0).complete();
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final w in _workers) {
      w.dispose();
    }
    for (final c in _waiters) {
      if (!c.isCompleted) c.completeError(StateError('Pool disposed'));
    }
    _waiters.clear();
  }
}

// --- Worker isolate entry point ------------------------------------------

void _entry(_WorkerInit init) {
  so.initBindings();

  final whisper = so.OfflineWhisperModelConfig(
    encoder: init.encoderPath,
    decoder: init.decoderPath,
    language: 'en',
    task: 'transcribe',
    enableTokenTimestamps: true,
  );
  // XNNPACK is the same numerical precision as the default CPU EP
  // (no NNAPI-style int8 drift) but its hand-tuned NEON kernels give
  // ~30-50% faster matmul on ARM. Keep desktop on the stock CPU EP
  // where ORT's MKL/oneDNN path is already well-optimized.
  final provider = init.useNNAPI
      ? 'nnapi'
      : (Platform.isAndroid ? 'xnnpack' : 'cpu');
  final modelConfig = so.OfflineModelConfig(
    whisper: whisper,
    tokens: init.tokensPath,
    modelType: 'whisper',
    numThreads: init.numThreads,
    provider: provider,
  );
  final config = so.OfflineRecognizerConfig(model: modelConfig);
  final recognizer = so.OfflineRecognizer(config);

  final port = ReceivePort();
  init.mainPort.send(port.sendPort);

  port.listen((message) {
    if (message is! _Request) return;
    try {
      // Materialise the samples on this isolate's heap (zero-copy from
      // the sender) and view them as Float32 without allocating again.
      final bytes = message.samples.materialize().asUint8List();
      final samples = Float32List.view(
        bytes.buffer,
        bytes.offsetInBytes,
        message.sampleCount,
      );

      final stream = recognizer.createStream();
      try {
        stream.acceptWaveform(
          samples: samples,
          sampleRate: message.sampleRate,
        );
        recognizer.decode(stream);
        final result = recognizer.getResult(stream);
        final words = _tokensToWords(
          tokens: result.tokens,
          timestamps: result.timestamps,
          clipDurationSeconds: samples.length / message.sampleRate,
        );
        init.mainPort.send(_Response(id: message.id, words: words));
      } finally {
        stream.free();
      }
    } catch (e) {
      init.mainPort.send(_Response(id: message.id, error: e.toString()));
    }
  });
}

/// Worker-side copy of the BPE-token-to-word grouping. Mirrors the host's
/// `_tokensToWords` in `whisper_transcriber.dart` — kept in this file so
/// the worker isolate doesn't pull in anything from the host that isn't
/// strictly needed.
///
/// Includes the same empty/zero-timestamps fallback (sherpa-onnx whisper
/// ONNX exports without cross-attention output return an empty timestamps
/// array; we distribute word starts linearly across the clip so the
/// aligner has *some* per-word time to work with).
List<AudioWord> _tokensToWords({
  required List<String> tokens,
  required List<double> timestamps,
  required double clipDurationSeconds,
}) {
  if (tokens.isEmpty) return const [];

  final hasRealTimestamps = timestamps.length >= tokens.length &&
      timestamps.any((t) => t > 0);

  final words = <AudioWord>[];
  final pending = StringBuffer();
  double? pendingStart;

  void flush(double end) {
    if (pendingStart == null) return;
    final text = pending.toString().trim();
    pending.clear();
    if (text.isEmpty) {
      pendingStart = null;
      return;
    }
    words.add(AudioWord(
      text: text,
      startSeconds: pendingStart!,
      endSeconds: end,
      confidence: 1.0,
    ));
    pendingStart = null;
  }

  for (var i = 0; i < tokens.length; i++) {
    final t = tokens[i];
    if (t.startsWith('<|') && t.endsWith('|>')) continue;
    final ts = hasRealTimestamps ? timestamps[i] : 0.0;
    final startsWord = t.startsWith(' ');
    if (startsWord) flush(ts);
    pending.write(t);
    pendingStart ??= ts;
  }
  flush(clipDurationSeconds);

  final emitted =
      words.where((w) => w.text.isNotEmpty).toList(growable: false);
  if (hasRealTimestamps || emitted.isEmpty) return emitted;

  final dt = clipDurationSeconds / emitted.length;
  return [
    for (var i = 0; i < emitted.length; i++)
      AudioWord(
        text: emitted[i].text,
        startSeconds: i * dt,
        endSeconds: (i + 1) * dt,
        confidence: emitted[i].confidence,
      ),
  ];
}

