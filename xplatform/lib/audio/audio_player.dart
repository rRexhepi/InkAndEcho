import 'dart:async';
import 'dart:io' show Platform;

import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart' as ja;
import 'package:just_audio_background/just_audio_background.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Same key as the Apple build's `AppSettings.playbackRateKey`.
const _kRatePref = 'inkandecho.playbackRate';

bool get _isMobile => Platform.isAndroid || Platform.isIOS;

/// `h:mm:ss` when ≥ 1 h, `mm:ss` otherwise.
String formatDuration(Duration d) {
  final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
  final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  final h = d.inHours;
  return h > 0 ? '$h:$m:$s' : '$m:$s';
}

/// Thin wrapper around just_audio that surfaces only what the reader needs:
/// load file, play/pause, ±15 s skip, rate (with pitch preserved), position
/// stream, total duration. Mirrors the surface of `AudioEngine.swift` from
/// the Apple build.
class InkAndEchoAudioPlayer extends ChangeNotifier {
  // Cap ExoPlayer's buffers aggressively. Default `AndroidLoadControl`
  // has `targetBufferBytes: null` (unbounded inside the time window), and
  // for high-bitrate 25-hour audiobooks ExoPlayer's Mp4Extractor can
  // grow into the gigabytes — the AVD killed us at 5.2 GB RSS in idle
  // last time. 20 s ahead / 8 MB byte cap is plenty for sequential
  // listening; seeking re-buffers from disk anyway.
  final ja.AudioPlayer _player = ja.AudioPlayer(
    audioLoadConfiguration: const ja.AudioLoadConfiguration(
      androidLoadControl: ja.AndroidLoadControl(
        minBufferDuration: Duration(seconds: 15),
        maxBufferDuration: Duration(seconds: 20),
        bufferForPlaybackDuration: Duration(seconds: 2),
        bufferForPlaybackAfterRebufferDuration: Duration(seconds: 4),
        targetBufferBytes: 8 * 1024 * 1024,
        prioritizeTimeOverSizeThresholds: false,
        backBufferDuration: Duration(seconds: 5),
      ),
    ),
  );
  String? _currentPath;
  bool _ready = false;
  double _rate = 1.0;
  Timer? _sleepTimer;
  Duration? _sleepRemaining;
  StreamSubscription<Duration>? _positionSub;
  StreamSubscription<ja.PlayerState>? _stateSub;

  InkAndEchoAudioPlayer() {
    _stateSub = _player.playerStateStream.listen((_) => notifyListeners());
    _positionSub = _player.positionStream.listen((_) => notifyListeners());
  }

  bool get isReady => _ready;
  bool get isPlaying => _player.playing;
  Duration get position => _player.position;
  Duration? get duration => _player.duration;
  double get rate => _rate;
  String? get currentPath => _currentPath;
  Duration? get sleepRemaining => _sleepRemaining;
  bool get hasSleepTimer => _sleepTimer != null;

  Future<void> initSession() async {
    if (!_isMobile) return; // audio_session is mobile-only
    final session = await AudioSession.instance;
    await session.configure(const AudioSessionConfiguration.speech());
  }

  /// Load a local audio file. `bookId`/`title`/`author` populate the
  /// background-playback MediaItem so the lock-screen / notification shade
  /// shows the book metadata. Falls back to a path-only source if the
  /// background plugin isn't initialised (tests, web, etc).
  Future<void> loadFile(
    String path, {
    String? bookId,
    String? title,
    String? author,
  }) async {
    _ready = false;
    _currentPath = path;
    notifyListeners();
    try {
      try {
        final source = _isMobile
            ? ja.AudioSource.uri(
                Uri.file(path),
                tag: MediaItem(
                  id: bookId ?? path,
                  title: title ?? 'Audiobook',
                  artist: author,
                ),
              )
            : ja.AudioSource.uri(Uri.file(path));
        await _player.setAudioSource(source);
      } catch (_) {
        // background plugin not initialised — degrade to plain file source
        await _player.setFilePath(path);
      }
      // Re-apply the persisted playback rate — a fresh player starts at 1x.
      try {
        final stored =
            (await SharedPreferences.getInstance()).getDouble(_kRatePref);
        if (stored != null && stored > 0) {
          _rate = stored;
          await _player.setSpeed(stored);
        }
      } catch (_) {
        // prefs unavailable (tests) — session keeps the default rate
      }
      _ready = true;
    } catch (_) {
      _ready = false;
    }
    notifyListeners();
  }

  Future<void> play() => _player.play();
  Future<void> pause() => _player.pause();

  Future<void> togglePlay() async {
    if (_player.playing) {
      await pause();
    } else {
      await play();
    }
  }

  Future<void> seekSeconds(double seconds) async {
    final d = duration;
    var clamped = seconds < 0 ? 0.0 : seconds;
    if (d != null && clamped > d.inMilliseconds / 1000.0) {
      clamped = d.inMilliseconds / 1000.0;
    }
    await _player.seek(Duration(milliseconds: (clamped * 1000).round()));
  }

  Future<void> skip(Duration delta) async {
    await seekSeconds(position.inMilliseconds / 1000.0 +
        delta.inMilliseconds / 1000.0);
  }

  /// Sets playback rate while preserving pitch — matches AVAudioUnitTimePitch
  /// behavior from the Apple build. just_audio's `setSpeed` keeps pitch
  /// constant by default on Android (stretches via the audio framework).
  Future<void> setRate(double rate) async {
    _rate = rate;
    await _player.setSpeed(rate);
    notifyListeners();
    try {
      await (await SharedPreferences.getInstance())
          .setDouble(_kRatePref, rate);
    } catch (_) {
      // prefs unavailable (tests) — rate still applies for this session
    }
  }

  /// Start a sleep timer that pauses playback after `duration`. Pass null
  /// to cancel any active timer.
  void setSleepTimer(Duration? duration) {
    _sleepTimer?.cancel();
    if (duration == null || duration <= Duration.zero) {
      _sleepTimer = null;
      _sleepRemaining = null;
      notifyListeners();
      return;
    }
    final endsAt = DateTime.now().add(duration);
    _sleepRemaining = duration;
    _sleepTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      final left = endsAt.difference(DateTime.now());
      if (left <= Duration.zero) {
        t.cancel();
        _sleepTimer = null;
        _sleepRemaining = null;
        pause();
      } else {
        _sleepRemaining = left;
      }
      notifyListeners();
    });
    notifyListeners();
  }

  @override
  Future<void> dispose() async {
    _sleepTimer?.cancel();
    await _positionSub?.cancel();
    await _stateSub?.cancel();
    await _player.dispose();
    super.dispose();
  }
}
