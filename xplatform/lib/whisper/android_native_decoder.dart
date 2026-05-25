import 'package:flutter/services.dart';

/// Dart wrapper for the `inkandecho/native_decoder` MethodChannel
/// implemented in `android/.../NativeAudioDecoder.kt`. The slot the
/// platform-agnostic `FfmpegRunner` skeleton plugs in on Android.
class AndroidNativeDecoder {
  static const _channel = MethodChannel('inkandecho/native_decoder');
  static const _streamChannel = EventChannel('inkandecho/native_decoder_stream');

  /// Decode (a range of) [sourcePath] into a 16-bit signed-little-endian
  /// WAV at [outputPath], downmixed to [channels] and resampled to
  /// [sampleRate]. Throws on failure; the caller maps that to the same
  /// non-zero-exit-code shape ffmpeg would have produced.
  static Future<void> decode({
    required String sourcePath,
    required String outputPath,
    double startSeconds = 0,
    double? durationSeconds,
    int sampleRate = 16000,
    int channels = 1,
  }) {
    return _channel.invokeMethod<void>('decode', {
      'source': sourcePath,
      'output': outputPath,
      'startSeconds': startSeconds,
      'durationSeconds': durationSeconds,
      'sampleRate': sampleRate,
      'channels': channels,
    });
  }

  /// Stream the entire [sourcePath] as raw s16le PCM at [sampleRate] Hz
  /// mono. Each event is a `Uint8List` of PCM bytes. The stream completes
  /// when the file is fully decoded. Mirrors the shape of desktop's
  /// ffmpeg stdout streaming so the transcriber can use one code path.
  static Stream<Uint8List> streamDecode({
    required String sourcePath,
    int sampleRate = 16000,
    int channels = 1,
  }) {
    return _streamChannel
        .receiveBroadcastStream({
          'source': sourcePath,
          'sampleRate': sampleRate,
          'channels': channels,
        })
        .map((data) => data as Uint8List);
  }

  /// Total media duration in seconds via `MediaMetadataRetriever`. Returns
  /// `0` rather than throwing so callers can fall back to other strategies.
  static Future<double> durationSeconds(String sourcePath) async {
    try {
      final result = await _channel.invokeMethod<num>('duration', {
        'source': sourcePath,
      });
      final v = result?.toDouble() ?? 0.0;
      return v.isFinite && v > 0 ? v : 0;
    } catch (_) {
      return 0;
    }
  }
}
