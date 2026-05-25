import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as so;

import '../alignment/aligner.dart';
import 'ffmpeg_runner.dart';
import 'whisper_config.dart';
import 'whisper_isolate.dart';

class TranscribeProgress {
  final String label;
  final double? fraction;
  /// Non-null only on the final emit of a streaming transcribe — carries
  /// the full word list back to the caller.
  final List<AudioWord>? words;
  const TranscribeProgress(this.label, {this.fraction, this.words});
}

/// Whisper transcription on top of `sherpa_onnx` (ONNX Runtime + Whisper).
///
/// On Android, ONNX Runtime dispatches to the **NNAPI** execution provider
/// when available, routing matrix math to the device NPU/GPU (Hexagon on
/// Pixel, Tensor on Galaxy) with transparent CPU fallback otherwise.
/// Mirrors iOS's WhisperKit / Core ML / Apple Neural Engine path.
///
/// Model files (encoder.int8.onnx, decoder.int8.onnx, tokens.txt) are
/// downloaded on first run from k2-fsa's HuggingFace mirror — ~270 MB
/// for base.en int8 quantized, matching the model the iOS aligner uses.
class WhisperTranscriber {
  static bool _bindingsInitialized = false;

  String get _huggingFaceRoot =>
      'https://huggingface.co/csukuangfj/sherpa-onnx-whisper-base.en/resolve/main';

  /// Names of the three files we expect to land under the model dir. The
  /// recognizer init fails loudly if any of them is missing or zero-byte.
  /// `base.en` matches the iOS WhisperAligner default — the model the
  /// standalone macOS app shipped with. ~270 MB int8 quantized vs ~80 MB
  /// for tiny.en, but meaningfully better word recognition translates to
  /// more usable anchors per audiobook.
  static const _encoderName = 'base.en-encoder.int8.onnx';
  static const _decoderName = 'base.en-decoder.int8.onnx';
  static const _tokensName = 'base.en-tokens.txt';

  /// Pool of worker isolates that own the actual `OfflineRecognizer`s and
  /// run `decode` off the UI thread. Replaces the in-process recognizer
  /// the transcriber used to construct directly. The pool is built on
  /// first use (after the model files have finished downloading) and
  /// disposed in [dispose].
  WhisperWorkerPool? _pool;
  Future<WhisperWorkerPool>? _poolSpawning;

  WhisperTranscriber({WhisperConfig? config}) : _configOverride = config {
    if (!_bindingsInitialized) {
      so.initBindings();
      _bindingsInitialized = true;
    }
  }

  /// When null, the pool reads [WhisperConfig.forHost] on each spawn.
  final WhisperConfig? _configOverride;
  WhisperConfig get _config => _configOverride ?? WhisperConfig.forHost();

  Future<Directory> _modelDir() async {
    final base = await getApplicationSupportDirectory();
    final dir = Directory('${base.path}/sherpa_onnx_whisper_base_en');
    if (!dir.existsSync()) await dir.create(recursive: true);
    return dir;
  }

  Future<bool> isModelDownloaded() async {
    final dir = await _modelDir();
    for (final name in const [_encoderName, _decoderName, _tokensName]) {
      final f = File('${dir.path}/$name');
      if (!f.existsSync() || f.lengthSync() == 0) return false;
    }
    return true;
  }

  /// Stream the model download with progress fractions in [0, 1].
  ///
  /// We download three files in sequence (encoder, decoder, tokens). The
  /// fraction we emit is the global byte progress across all three so the
  /// UI bar advances monotonically instead of resetting per file.
  Stream<TranscribeProgress> downloadModel() async* {
    if (await isModelDownloaded()) {
      yield const TranscribeProgress('Model ready.', fraction: 1.0);
      return;
    }
    yield const TranscribeProgress(
      'Downloading base.en model…',
      fraction: 0.0,
    );

    final dir = await _modelDir();
    final files = const [_encoderName, _decoderName, _tokensName];

    // Windows: Dart's HttpClient uses BoringSSL with bundled roots and
    // rejects certs that Schannel (and curl.exe) would accept — most
    // visibly when an AV is inspecting TLS. Shell out to curl.exe so
    // verification uses the Windows certificate store instead.
    if (Platform.isWindows) {
      yield* _downloadModelViaCurl(dir, files);
      return;
    }

    // First pass: HEAD each URL to get total bytes so the fraction below
    // is meaningful. If a HEAD fails we still proceed; the bar just runs
    // indeterminate until that file finishes.
    final client = HttpClient();
    try {
      var totalBytes = 0;
      final sizes = <String, int>{};
      for (final name in files) {
        final req = await client.headUrl(Uri.parse('$_huggingFaceRoot/$name'));
        final resp = await req.close();
        final len = resp.contentLength;
        if (len > 0) sizes[name] = len;
        totalBytes += len > 0 ? len : 0;
        await resp.drain();
      }

      var written = 0;
      for (final name in files) {
        final dest = File('${dir.path}/$name');
        final tmp = File('${dest.path}.part');
        if (tmp.existsSync()) await tmp.delete();

        final req = await client.getUrl(Uri.parse('$_huggingFaceRoot/$name'));
        final resp = await req.close();
        final sink = tmp.openWrite();
        await for (final chunk in resp) {
          sink.add(chunk);
          written += chunk.length;
          if (totalBytes > 0) {
            yield TranscribeProgress(
              'Downloading model… '
              '${(written / 1024 / 1024).toStringAsFixed(0)} MB',
              fraction: written / totalBytes,
            );
          }
        }
        await sink.close();
        await tmp.rename(dest.path);
      }

      yield const TranscribeProgress('Model ready.', fraction: 1.0);
    } finally {
      client.close(force: false);
    }
  }

  Stream<TranscribeProgress> _downloadModelViaCurl(
    Directory dir,
    List<String> files,
  ) async* {
    final sizes = <String, int>{};
    var totalBytes = 0;
    for (final name in files) {
      final r = await Process.run(
        'curl.exe',
        ['-sIL', '--max-time', '30', '$_huggingFaceRoot/$name'],
      );
      final len = _parseContentLength(r.stdout.toString());
      if (len > 0) {
        sizes[name] = len;
        totalBytes += len;
      }
    }

    var written = 0;
    for (final name in files) {
      final dest = File('${dir.path}/$name');
      final tmp = File('${dest.path}.part');
      if (tmp.existsSync()) await tmp.delete();

      final base = written;
      final process = await Process.start(
        'curl.exe',
        ['-fL', '-s', '-o', tmp.path, '$_huggingFaceRoot/$name'],
      );
      final stderrBuf = StringBuffer();
      process.stderr.transform(utf8.decoder).listen(stderrBuf.write);
      final exitFuture = process.exitCode;
      var done = false;
      // ignore: unawaited_futures
      exitFuture.whenComplete(() => done = true);

      while (!done) {
        await Future<void>.delayed(const Duration(milliseconds: 250));
        if (tmp.existsSync() && totalBytes > 0) {
          final cur = base + tmp.lengthSync();
          yield TranscribeProgress(
            'Downloading model… '
            '${(cur / 1024 / 1024).toStringAsFixed(0)} MB',
            fraction: (cur / totalBytes).clamp(0.0, 1.0),
          );
        }
      }

      final code = await exitFuture;
      if (code != 0) {
        throw Exception(
          'curl failed for $name (exit $code): ${stderrBuf.toString().trim()}',
        );
      }
      written = base + (sizes[name] ?? (tmp.existsSync() ? tmp.lengthSync() : 0));
      await tmp.rename(dest.path);
    }

    yield const TranscribeProgress('Model ready.', fraction: 1.0);
  }

  static int _parseContentLength(String headers) {
    final re = RegExp(r'^content-length:\s*(\d+)', caseSensitive: false);
    for (final line in const LineSplitter().convert(headers)) {
      final m = re.firstMatch(line);
      if (m != null) return int.parse(m.group(1)!);
    }
    return 0;
  }

  /// Lazily spin up the worker isolate pool. Each worker holds its own
  /// `OfflineRecognizer`; the pool dispatches chunks across them in
  /// parallel so the UI thread never sees a `decode()` call and total
  /// transcription wall-clock scales with core count.
  ///
  /// CPU on every platform. NNAPI on Android trades alignment quality
  /// for speed -- the per-platform output diverged enough to matter.
  Future<WhisperWorkerPool> _ensurePool() {
    final existing = _pool;
    if (existing != null) return Future.value(existing);
    final spawning = _poolSpawning;
    if (spawning != null) return spawning;

    final future = () async {
      final dir = await _modelDir();
      final pool = await WhisperWorkerPool.spawn(
        encoderPath: '${dir.path}/$_encoderName',
        decoderPath: '${dir.path}/$_decoderName',
        tokensPath: '${dir.path}/$_tokensName',
        useNNAPI: _config.useNNAPI,
        count: _config.workerCount,
        numThreadsPerWorker: _config.threadsPerWorker,
      );
      _pool = pool;
      _poolSpawning = null;
      return pool;
    }();
    _poolSpawning = future;
    return future;
  }

  /// Run transcription on a whole file. Used only when the audio is short
  /// enough to fit in one whisper pass — long audiobooks always go
  /// through [transcribeChunked].
  Future<List<AudioWord>> transcribe(File audio) async {
    final wavPath = await _toWav(audio);
    try {
      return _transcribeWav(wavPath);
    } finally {
      if (wavPath != audio.path) {
        try { await File(wavPath).delete(); } catch (_) {}
      }
    }
  }

  /// Chunked transcribe.
  ///
  /// **Whisper's encoder accepts exactly 30 seconds of audio.** Anything
  /// longer than 30 s gets silently truncated by sherpa-onnx; anything
  /// shorter gets padded with silence. Earlier versions of this code fed
  /// 600 s chunks and got back only ~70 words per chunk — that's because
  /// only the first 30 s of each chunk was actually transcribed. We now
  /// chunk at the native window: 28 s of fresh audio plus 2 s overlap =
  /// 30 s per Whisper call. The 2 s overlap covers words straddling
  /// boundaries; duplicates are pruned in [_appendWithOverlapDedup].
  ///
  /// Desktop uses a single long-lived ffmpeg process that decodes the
  /// whole audiobook once and streams 16 kHz mono s16le PCM to stdout.
  /// Dart slices the byte stream into overlap-aware chunks and feeds the
  /// recognizer's `acceptWaveform` directly.
  ///
  /// Mobile keeps a per-chunk decode (MediaCodec on Android, no live PCM
  /// pipe), but uses the same overlap + dedup.
  Stream<TranscribeProgress> transcribeChunked(
    File audio, {
    int chunkSeconds = 28,
    int overlapSeconds = 2,
  }) async* {
    yield const TranscribeProgress('Preparing audio…', fraction: 0);

    final totalSeconds = await _probeDurationSeconds(audio);
    if (totalSeconds <= 0 || totalSeconds <= chunkSeconds.toDouble()) {
      yield const TranscribeProgress('Transcribing audiobook…', fraction: null);
      final words = await transcribe(audio);
      yield TranscribeProgress('Transcribed.', fraction: 1.0, words: words);
      return;
    }

    yield* _transcribeStreaming(
      audio,
      totalSeconds: totalSeconds,
      chunkSeconds: chunkSeconds,
      overlapSeconds: overlapSeconds,
    );
  }

  /// Streaming path: one decode source for the whole file, raw PCM
  /// streamed to Dart. Desktop uses a long-lived ffmpeg process on stdout.
  /// Android uses an EventChannel backed by MediaExtractor + MediaCodec.
  Stream<TranscribeProgress> _transcribeStreaming(
    File audio, {
    required double totalSeconds,
    required int chunkSeconds,
    required int overlapSeconds,
  }) async* {
    const sampleRate = 16000;
    const bytesPerSample = 2;
    final chunkBytes = chunkSeconds * sampleRate * bytesPerSample;
    final overlapBytes = overlapSeconds * sampleRate * bytesPerSample;

    final runner = FfmpegRunner.instance;
    final Stream<List<int>> pcmStream;
    Process? proc;
    StreamSubscription<String>? stderrSub;
    final stderrBuf = StringBuffer();

    if (runner.useNativeAndroid) {
      pcmStream = runner.startNativeStream(inputPath: audio.path);
    } else {
      proc = await runner.startFfmpeg([
        '-nostdin',
        '-loglevel', 'error',
        '-i', audio.path,
        '-ar', '$sampleRate',
        '-ac', '1',
        '-f', 's16le',
        '-',
      ]);
      stderrSub = proc.stderr.transform(utf8.decoder).listen(stderrBuf.write);
      pcmStream = proc.stdout;
    }

    final acc = BytesBuilder(copy: false);
    var chunkIndex = 0;
    Uint8List carryOver = Uint8List(0);
    final allWords = <AudioWord>[];
    final pool = await _ensurePool();
    final maxInFlight = pool.size;
    final pending = <_PendingChunk>[];

    void dispatchChunk(Uint8List newBytes, {required bool isLast}) {
      final Uint8List samplesBytes = carryOver.isEmpty
          ? newBytes
          : (Uint8List(carryOver.length + newBytes.length)
            ..setRange(0, carryOver.length, carryOver)
            ..setRange(
                carryOver.length, carryOver.length + newBytes.length, newBytes));
      final chunkStartTime = chunkIndex == 0
          ? 0.0
          : (chunkIndex * chunkSeconds - overlapSeconds).toDouble();
      final overlapEndsAt = (chunkIndex * chunkSeconds).toDouble();
      final ci = chunkIndex;

      final samples = _s16leToFloat32(samplesBytes);
      pending.add(_PendingChunk(
        index: ci,
        chunkStartTime: chunkStartTime,
        overlapEndGlobalTime: overlapEndsAt,
        isFirstChunk: ci == 0,
        future: pool.transcribe(samples, sampleRate),
      ));

      carryOver = (!isLast && samplesBytes.length >= overlapBytes)
          ? Uint8List.fromList(
              samplesBytes.sublist(samplesBytes.length - overlapBytes))
          : Uint8List(0);
      chunkIndex++;
    }

    try {
      await for (final part in pcmStream) {
        acc.add(part);
        while (acc.length >= chunkBytes) {
          final all = acc.takeBytes();
          final chunkPiece = Uint8List.sublistView(all, 0, chunkBytes);
          if (all.length > chunkBytes) {
            acc.add(Uint8List.sublistView(all, chunkBytes));
          }
          dispatchChunk(chunkPiece, isLast: false);

          while (pending.length > maxInFlight) {
            final c = await _drainOldestPending(pending, allWords);
            yield _progressFor(
              c,
              label: 'Transcribing… '
                  '${(c.chunkStartTime / 60).toStringAsFixed(0)}'
                  ' / ${(totalSeconds / 60).toStringAsFixed(0)} min',
              totalSeconds: totalSeconds,
              chunkSeconds: chunkSeconds,
            );
          }
        }
      }

      if (acc.length > 0) {
        final tail = acc.takeBytes();
        dispatchChunk(tail, isLast: true);
      }

      while (pending.isNotEmpty) {
        final c = await _drainOldestPending(pending, allWords);
        yield _progressFor(
          c,
          label: 'Transcribing final chunks…',
          totalSeconds: totalSeconds,
          chunkSeconds: chunkSeconds,
        );
      }

      if (proc != null) {
        final code = await proc.exitCode;
        if (code != 0 && allWords.isEmpty) {
          throw StateError(
            'ffmpeg exited with code $code while streaming '
            '${audio.path}:\n${stderrBuf.toString().trim()}',
          );
        }
      }

      yield TranscribeProgress(
        'Transcribed ${allWords.length} words.',
        fraction: 1.0,
        words: allWords,
      );
    } finally {
      await stderrSub?.cancel();
      try {
        proc?.kill(ProcessSignal.sigterm);
      } catch (_) {}
    }
  }

  Future<_PendingChunk> _drainOldestPending(
    List<_PendingChunk> pending,
    List<AudioWord> allWords,
  ) async {
    final c = pending.removeAt(0);
    final words = await c.future;
    _appendWithOverlapDedup(
      allWords,
      words,
      chunkStartTime: c.chunkStartTime,
      overlapEndGlobalTime: c.overlapEndGlobalTime,
      isFirstChunk: c.isFirstChunk,
    );
    return c;
  }

  TranscribeProgress _progressFor(
    _PendingChunk c, {
    required String label,
    required double totalSeconds,
    required int chunkSeconds,
  }) =>
      TranscribeProgress(
        label,
        fraction: totalSeconds > 0
            ? (c.chunkStartTime + chunkSeconds) / totalSeconds
            : null,
      );

  /// Hand a Float32 sample buffer off to the worker pool. Inference runs
  /// on a background isolate; the UI thread keeps responding to OS
  /// heartbeats while we await.
  Future<List<AudioWord>> _transcribeSamples(
    Float32List samples,
    int sampleRate,
  ) async {
    final pool = await _ensurePool();
    return pool.transcribe(samples, sampleRate);
  }

  /// Run sherpa_onnx on a prepared 16 kHz mono PCM WAV. Whisper emits BPE
  /// tokens (sub-word pieces); they're regrouped into words by
  /// [_tokensToWords] downstream.
  Future<List<AudioWord>> _transcribeWav(String wavPath) async {
    final wave = so.readWave(wavPath);
    if (wave.samples.isEmpty) {
      throw StateError('Cannot read WAV: $wavPath');
    }
    return _transcribeSamples(wave.samples, wave.sampleRate);
  }

  /// Decode raw s16le PCM (the format ffmpeg streams when invoked with
  /// `-f s16le`) into a Float32List normalized to `[-1, 1]`, which is what
  /// sherpa_onnx's `acceptWaveform` expects.
  static Float32List _s16leToFloat32(Uint8List bytes) {
    final n = bytes.length ~/ 2;
    final out = Float32List(n);
    final view = ByteData.sublistView(bytes);
    for (var i = 0; i < n; i++) {
      out[i] = view.getInt16(i * 2, Endian.little) / 32768.0;
    }
    return out;
  }

  /// Append a chunk's worth of words to `target`, skipping any that fall
  /// inside the overlap zone *and* duplicate a word the previous chunk
  /// already emitted. Identity is "same normalized text within 0.5 s of an
  /// already-emitted word."
  static void _appendWithOverlapDedup(
    List<AudioWord> target,
    List<AudioWord> chunkWords, {
    required double chunkStartTime,
    required double overlapEndGlobalTime,
    required bool isFirstChunk,
  }) {
    for (final w in chunkWords) {
      final gstart = w.startSeconds + chunkStartTime;
      final gend = w.endSeconds + chunkStartTime;
      if (!isFirstChunk && gstart < overlapEndGlobalTime) {
        final normT = _normalizeForDedup(w.text);
        var dup = false;
        // Scan backward through recently-emitted words. Once we're more
        // than ~6 seconds older than the candidate we're well outside any
        // plausible overlap window — stop.
        for (var i = target.length - 1; i >= 0; i--) {
          final e = target[i];
          if (gstart - e.startSeconds > 6.0) break;
          if ((e.startSeconds - gstart).abs() < 0.5 &&
              _normalizeForDedup(e.text) == normT) {
            dup = true;
            break;
          }
        }
        if (dup) continue;
      }
      target.add(AudioWord(
        text: w.text,
        startSeconds: gstart,
        endSeconds: gend,
        confidence: w.confidence,
      ));
    }
  }

  static final RegExp _dedupPunctSpace =
      RegExp(r'^[\s\p{P}]+|[\s\p{P}]+$', unicode: true);

  static String _normalizeForDedup(String s) =>
      s.replaceAll(_dedupPunctSpace, '').toLowerCase();

  /// Audio probe. Returns 0 on any failure so chunked transcribe falls
  /// back to the single-call path rather than guessing.
  Future<double> _probeDurationSeconds(File audio) =>
      FfmpegRunner.instance.probeDurationSeconds(audio.path);

  /// Ensure the audio is in the shape sherpa_onnx expects: 16 kHz mono
  /// pcm_s16le WAV. Skips conversion if the input already ends in `.wav`
  /// — `readWave` will reject the file with samples.isEmpty if the
  /// header doesn't match, and the caller will see that as a clear error.
  Future<String> _toWav(File audio) async {
    if (audio.path.toLowerCase().endsWith('.wav')) return audio.path;
    final tmp = await getTemporaryDirectory();
    final outPath =
        '${tmp.path}/palimp_full_${DateTime.now().millisecondsSinceEpoch}.wav';
    final result = await FfmpegRunner.instance.decodeToWav(
      inputPath: audio.path,
      outputPath: outPath,
    );
    if (!result.ok) {
      throw StateError('ffmpeg conversion failed: ${result.output}');
    }
    return outPath;
  }

  Future<void> dispose() async {
    try {
      _pool?.dispose();
    } catch (e) {
      debugPrint('WhisperWorkerPool dispose: $e');
    }
    _pool = null;
    _poolSpawning = null;
  }

  /// Disposes the worker pool. Next transcribe respawns it from the
  /// current [WhisperConfig.forHost].
  Future<void> resetPool() => dispose();
}

/// A chunk that's been handed off to the worker pool but whose words
/// haven't been welded into [allWords] yet. The streaming loop tracks
/// these in submission order so dedup is deterministic regardless of
/// which worker finishes first.
class _PendingChunk {
  _PendingChunk({
    required this.index,
    required this.chunkStartTime,
    required this.overlapEndGlobalTime,
    required this.isFirstChunk,
    required this.future,
  });
  final int index;
  final double chunkStartTime;
  final double overlapEndGlobalTime;
  final bool isFirstChunk;
  final Future<List<AudioWord>> future;
}
