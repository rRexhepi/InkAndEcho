import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'android_native_decoder.dart';

/// Result of a single audio-decode invocation. `code` follows ffmpeg
/// convention (0 = success, non-zero = failure); `output` is the merged
/// stdout/stderr so callers can surface failures with real diagnostics.
class FfmpegResult {
  final int code;
  final String output;
  const FfmpegResult(this.code, this.output);
  bool get ok => code == 0;
}

/// Platform-dispatched audio decoder.
///
/// On Android we go through `AndroidNativeDecoder` — a `MediaExtractor`
/// / `MediaCodec` slot living in the Kotlin layer. We dropped the
/// `ffmpeg_kit_flutter_*` packages: every published x86_64 build crashes
/// at `JNI_OnLoad` on modern Android emulators, and MediaExtractor /
/// MediaCodec are first-party APIs available since API 16 that decode
/// every audio format the system knows. On Windows / Linux / macOS we
/// shell out to a system-installed `ffmpeg` / `ffprobe` on PATH (or
/// whatever `INK_AND_ECHO_FFMPEG` / `INK_AND_ECHO_FFPROBE` env vars point
/// at). The Apple iOS / macOS app isn't a Flutter target — it lives in
/// `App/` + `InkAndEchoCore/` and uses WhisperKit + AVFoundation, no
/// ffmpeg involved.
class FfmpegRunner {
  static final FfmpegRunner instance = FfmpegRunner._();
  FfmpegRunner._();

  bool get useNativeAndroid => Platform.isAndroid;

  /// Decode a (possibly trimmed) section of [inputPath] into a 16-bit
  /// PCM WAV at [outputPath]. Defaults match what the whisper pipeline
  /// wants: 16 kHz mono.
  Future<FfmpegResult> decodeToWav({
    required String inputPath,
    required String outputPath,
    double? startSeconds,
    double? durationSeconds,
    int sampleRate = 16000,
    int channels = 1,
  }) {
    if (useNativeAndroid) {
      return _decodeAndroidNative(
        inputPath: inputPath,
        outputPath: outputPath,
        startSeconds: startSeconds,
        durationSeconds: durationSeconds,
        sampleRate: sampleRate,
        channels: channels,
      );
    }
    return _decodeViaHostFfmpeg(
      inputPath: inputPath,
      outputPath: outputPath,
      startSeconds: startSeconds,
      durationSeconds: durationSeconds,
      sampleRate: sampleRate,
      channels: channels,
    );
  }

  /// Total duration of [inputPath] in seconds, or `0` if the probe fails.
  Future<double> probeDurationSeconds(String inputPath) async {
    if (useNativeAndroid) {
      return AndroidNativeDecoder.durationSeconds(inputPath);
    }
    final r = await _runHostBinary(_ffprobeBin, [
      '-v', 'quiet',
      '-show_entries', 'format=duration',
      '-of', 'default=noprint_wrappers=1:nokey=1',
      inputPath,
    ]);
    if (!r.ok) return 0;
    final seconds = double.tryParse(r.output.trim());
    return (seconds != null && seconds.isFinite && seconds > 0) ? seconds : 0;
  }

  /// Spawn ffmpeg with its stdout/stderr exposed for streaming consumption.
  /// Desktop-only. Callers must `await Process.exitCode` to reap the child.
  Future<Process> startFfmpeg(List<String> args) {
    if (useNativeAndroid) {
      throw UnsupportedError(
        'startFfmpeg is desktop-only. On Android, use startNativeStream().',
      );
    }
    return Process.start(_ffmpegBin, args, runInShell: false);
  }

  /// Start a streaming decode of [inputPath] on Android via EventChannel.
  /// Returns a stream of raw s16le PCM bytes, same shape as ffmpeg stdout.
  Stream<Uint8List> startNativeStream({
    required String inputPath,
    int sampleRate = 16000,
    int channels = 1,
  }) {
    if (!useNativeAndroid) {
      throw UnsupportedError('startNativeStream is Android-only.');
    }
    return AndroidNativeDecoder.streamDecode(
      sourcePath: inputPath,
      sampleRate: sampleRate,
      channels: channels,
    );
  }

  bool get supportsStreaming => true;

  Future<FfmpegResult> _decodeAndroidNative({
    required String inputPath,
    required String outputPath,
    double? startSeconds,
    double? durationSeconds,
    int sampleRate = 16000,
    int channels = 1,
  }) async {
    try {
      await AndroidNativeDecoder.decode(
        sourcePath: inputPath,
        outputPath: outputPath,
        startSeconds: startSeconds ?? 0,
        durationSeconds: durationSeconds,
        sampleRate: sampleRate,
        channels: channels,
      );
      return const FfmpegResult(0, '');
    } catch (e) {
      return FfmpegResult(1, 'NativeAudioDecoder.decode failed: $e');
    }
  }

  Future<FfmpegResult> _decodeViaHostFfmpeg({
    required String inputPath,
    required String outputPath,
    double? startSeconds,
    double? durationSeconds,
    int sampleRate = 16000,
    int channels = 1,
  }) {
    final args = <String>['-y'];
    if (startSeconds != null && startSeconds > 0) {
      args.addAll(['-ss', startSeconds.toString()]);
    }
    if (durationSeconds != null && durationSeconds > 0) {
      args.addAll(['-t', durationSeconds.toString()]);
    }
    args.addAll([
      '-i', inputPath,
      '-ar', '$sampleRate',
      '-ac', '$channels',
      '-c:a', 'pcm_s16le',
      outputPath,
    ]);
    return _runHostBinary(_ffmpegBin, args);
  }

  String get _ffmpegBin =>
      Platform.environment['INK_AND_ECHO_FFMPEG'] ?? 'ffmpeg';
  String get _ffprobeBin =>
      Platform.environment['INK_AND_ECHO_FFPROBE'] ?? 'ffprobe';

  Future<FfmpegResult> _runHostBinary(String exe, List<String> args) async {
    try {
      final result = await Process.run(exe, args, runInShell: false);
      final out = '${result.stdout}\n${result.stderr}'.trim();
      return FfmpegResult(result.exitCode, out);
    } on ProcessException catch (e) {
      return FfmpegResult(
        127,
        'Failed to launch "$exe": ${e.message}. '
        'Install ffmpeg/ffprobe and ensure they are on PATH, or set '
        'INK_AND_ECHO_FFMPEG / INK_AND_ECHO_FFPROBE.',
      );
    }
  }
}
