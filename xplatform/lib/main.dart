import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:just_audio_background/just_audio_background.dart';
import 'package:just_audio_media_kit/just_audio_media_kit.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'annotations/annotation_types.dart';
import 'library/library_screen.dart';
import 'onboarding/onboarding_screen.dart';
import 'reader/reader_screen.dart';
import 'state/library_store.dart';
import 'theme.dart';
import 'whisper/whisper_config.dart';

const _kThemePref = 'palimpsest.theme';
const _kLastBookPref = 'palimpsest.lastOpenedBookID';
const _kOnboardedPref = 'palimpsest.hasCompletedOnboarding';
const _kAnimationsPref = 'palimpsest.animationsEnabled';
const _kHighlightColorPref = 'palimpsest.defaultHighlightColor';
const _kSwipeToFlipPref = 'palimpsest.swipeToFlipEnabled';
const _kTranscriptionPerfPref = 'palimpsest.transcriptionPerformance';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (Platform.isAndroid || Platform.isIOS) {
    try {
      await JustAudioBackground.init(
        androidNotificationChannelId: 'com.rexhep.palimpsest.audio',
        androidNotificationChannelName: 'Audiobook playback',
        androidNotificationOngoing: true,
      );
    } catch (_) {}
  } else {
    // Windows / Linux / macOS — route just_audio through libmpv.
    JustAudioMediaKit.ensureInitialized();
  }
  if (Platform.isAndroid) {
    // Bridges the transcription service isolate's sendDataToMain calls
    // to the main isolate's task-data callbacks. Without it, progress
    // events get dropped and the UI never advances past "Preparing…".
    FlutterForegroundTask.initCommunicationPort();
  }
  runApp(const PalimpsestApp());
}

enum AppThemeChoice { system, light, dark }

class PalimpsestApp extends StatefulWidget {
  const PalimpsestApp({super.key});

  @override
  State<PalimpsestApp> createState() => _PalimpsestAppState();
}

class _PalimpsestAppState extends State<PalimpsestApp> {
  final _store = LibraryStore();
  AppThemeChoice _theme = AppThemeChoice.system;
  bool _bootstrapped = false;
  bool _onboarded = true;
  bool _animationsEnabled = true;
  HighlightColor _defaultHighlightColor = HighlightColor.amber;
  bool _swipeToFlipEnabled = true;
  TranscriptionPerformance _transcriptionPerformance =
      WhisperConfig.defaultForHost;
  String? _lastBookId;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    SharedPreferences? prefs;
    try {
      prefs = await SharedPreferences.getInstance();
    } catch (_) {}
    final raw = prefs?.getString(_kThemePref);
    final choice = AppThemeChoice.values
            .where((t) => t.name == raw)
            .firstOrNull ??
        AppThemeChoice.system;
    _lastBookId = prefs?.getString(_kLastBookPref);
    _onboarded = prefs?.getBool(_kOnboardedPref) ?? false;
    _animationsEnabled = prefs?.getBool(_kAnimationsPref) ?? true;
    final hcRaw = prefs?.getString(_kHighlightColorPref);
    _defaultHighlightColor = HighlightColor.values
            .where((c) => c.name == hcRaw)
            .firstOrNull ??
        HighlightColor.amber;
    // Default OFF on desktop so the gesture stops intercepting drag-
    // selection; ON elsewhere where swipe is the natural navigation.
    final isDesktop = Platform.isWindows || Platform.isLinux || Platform.isMacOS;
    _swipeToFlipEnabled = prefs?.getBool(_kSwipeToFlipPref) ?? !isDesktop;
    _transcriptionPerformance = TranscriptionPerformanceCodec.parse(
      prefs?.getString(_kTranscriptionPerfPref),
    );
    activeTranscriptionPerformance.value = _transcriptionPerformance;
    setState(() {
      _theme = choice;
      _bootstrapped = true;
    });
    await _store.load();
  }

  Future<void> setTheme(AppThemeChoice choice) async {
    setState(() => _theme = choice);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kThemePref, choice.name);
  }

  Future<void> setAnimationsEnabled(bool enabled) async {
    setState(() => _animationsEnabled = enabled);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kAnimationsPref, enabled);
  }

  Future<void> setDefaultHighlightColor(HighlightColor color) async {
    setState(() => _defaultHighlightColor = color);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kHighlightColorPref, color.name);
  }

  Future<void> setSwipeToFlipEnabled(bool enabled) async {
    setState(() => _swipeToFlipEnabled = enabled);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kSwipeToFlipPref, enabled);
  }

  Future<void> setTranscriptionPerformance(
      TranscriptionPerformance level) async {
    setState(() => _transcriptionPerformance = level);
    activeTranscriptionPerformance.value = level;
    // Dispose the existing worker pool so the next transcribe respawns
    // with the new thread/worker counts. No-op if the user hasn't run
    // alignment yet this session.
    await _store.alignment.resetTranscriberPool();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kTranscriptionPerfPref, level.name);
  }

  Future<void> rememberLastBook(String? id) async {
    _lastBookId = id;
    final prefs = await SharedPreferences.getInstance();
    if (id == null) {
      await prefs.remove(_kLastBookPref);
    } else {
      await prefs.setString(_kLastBookPref, id);
    }
  }

  Future<void> _completeOnboarding() async {
    setState(() => _onboarded = true);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kOnboardedPref, true);
  }

  @override
  void dispose() {
    _store.dispose();
    super.dispose();
  }

  ThemeMode get _themeMode {
    switch (_theme) {
      case AppThemeChoice.light:
        return ThemeMode.light;
      case AppThemeChoice.dark:
        return ThemeMode.dark;
      case AppThemeChoice.system:
        return ThemeMode.system;
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Palimpsest',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(Brightness.light),
      darkTheme: buildTheme(Brightness.dark),
      themeMode: _themeMode,
      home: !_bootstrapped
          ? Scaffold(
              backgroundColor: Theme.of(context).scaffoldBackgroundColor,
              body: const Center(child: CircularProgressIndicator()),
            )
          : !_onboarded
              ? OnboardingScreen(onDone: _completeOnboarding)
              : _Boot(
                  store: _store,
                  lastBookId: _lastBookId,
                  currentTheme: _theme,
                  onThemeChanged: setTheme,
                  animationsEnabled: _animationsEnabled,
                  onAnimationsChanged: setAnimationsEnabled,
                  defaultHighlightColor: _defaultHighlightColor,
                  onDefaultHighlightColorChanged: setDefaultHighlightColor,
                  swipeToFlipEnabled: _swipeToFlipEnabled,
                  onSwipeToFlipChanged: setSwipeToFlipEnabled,
                  transcriptionPerformance: _transcriptionPerformance,
                  onTranscriptionPerformanceChanged:
                      setTranscriptionPerformance,
                  onOpenBook: rememberLastBook,
                ),
    );
  }
}

class _Boot extends StatefulWidget {
  final LibraryStore store;
  final String? lastBookId;
  final AppThemeChoice currentTheme;
  final ValueChanged<AppThemeChoice> onThemeChanged;
  final bool animationsEnabled;
  final ValueChanged<bool> onAnimationsChanged;
  final HighlightColor defaultHighlightColor;
  final ValueChanged<HighlightColor> onDefaultHighlightColorChanged;
  final bool swipeToFlipEnabled;
  final ValueChanged<bool> onSwipeToFlipChanged;
  final TranscriptionPerformance transcriptionPerformance;
  final ValueChanged<TranscriptionPerformance>
      onTranscriptionPerformanceChanged;
  final ValueChanged<String?> onOpenBook;

  const _Boot({
    required this.store,
    required this.lastBookId,
    required this.currentTheme,
    required this.onThemeChanged,
    required this.animationsEnabled,
    required this.onAnimationsChanged,
    required this.defaultHighlightColor,
    required this.onDefaultHighlightColorChanged,
    required this.swipeToFlipEnabled,
    required this.onSwipeToFlipChanged,
    required this.transcriptionPerformance,
    required this.onTranscriptionPerformanceChanged,
    required this.onOpenBook,
  });

  @override
  State<_Boot> createState() => _BootState();
}

class _BootState extends State<_Boot> {
  bool _routed = false;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.store,
      builder: (context, _) {
        if (!_routed && widget.store.isLoaded) {
          _routed = true;
          final last = widget.lastBookId;
          final book = last == null
              ? null
              : widget.store.books
                  .where((b) => b.id == last)
                  .cast<dynamic>()
                  .firstOrNull;
          if (book != null) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (!context.mounted) return;
              Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => ReaderScreen(
                  store: widget.store,
                  book: book,
                  animationsEnabled: widget.animationsEnabled,
                  defaultHighlightColor: widget.defaultHighlightColor,
                  swipeToFlipEnabled: widget.swipeToFlipEnabled,
                  onOpened: widget.onOpenBook,
                ),
              ));
            });
          }
        }
        return LibraryScreen(
          store: widget.store,
          currentTheme: widget.currentTheme,
          onThemeChanged: widget.onThemeChanged,
          animationsEnabled: widget.animationsEnabled,
          onAnimationsChanged: widget.onAnimationsChanged,
          defaultHighlightColor: widget.defaultHighlightColor,
          onDefaultHighlightColorChanged: widget.onDefaultHighlightColorChanged,
          swipeToFlipEnabled: widget.swipeToFlipEnabled,
          onSwipeToFlipChanged: widget.onSwipeToFlipChanged,
          transcriptionPerformance: widget.transcriptionPerformance,
          onTranscriptionPerformanceChanged:
              widget.onTranscriptionPerformanceChanged,
          onOpenBook: widget.onOpenBook,
        );
      },
    );
  }
}
