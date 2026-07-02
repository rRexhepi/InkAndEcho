import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/material.dart';

import '../audio/audio_player.dart';
import '../persistence/library_storage.dart';
import '../theme.dart';

/// Full-controls audio sheet that the compact bar expands into.
class AudioSheet extends StatelessWidget {
  final InkAndEchoAudioPlayer player;
  final StoredBook book;
  final bool hasAlignment;
  final bool isAligning;
  final VoidCallback onAlign;

  const AudioSheet({
    super.key,
    required this.player,
    required this.book,
    required this.hasAlignment,
    required this.isAligning,
    required this.onAlign,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return DraggableScrollableSheet(
      initialChildSize: 0.55,
      minChildSize: 0.40,
      maxChildSize: 0.85,
      expand: false,
      builder: (_, scroll) => Container(
        decoration: BoxDecoration(
          color: colors.canvas,
          borderRadius:
              const BorderRadius.vertical(top: Radius.circular(16)),
        ),
        child: ListenableBuilder(
          listenable: player,
          builder: (_, _) {
            final pos = player.position;
            final dur = player.duration ?? Duration.zero;
            final maxMs = dur.inMilliseconds <= 0 ? 1 : dur.inMilliseconds;
            return SingleChildScrollView(
              controller: scroll,
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Column(
                children: [
                  const SizedBox(height: 8),
                  Container(
                    width: 36,
                    height: 4,
                    decoration: BoxDecoration(
                      color: colors.hairlineStrong,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  const SizedBox(height: 18),
                  Text(book.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          color: colors.ink,
                          fontSize: 16,
                          fontWeight: FontWeight.w600)),
                  const SizedBox(height: 2),
                  Text(book.author,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          color: colors.inkMuted, fontSize: 12)),
                  const SizedBox(height: 22),
                  // Scrubber
                  SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      activeTrackColor: colors.accent,
                      inactiveTrackColor: colors.hairlineStrong,
                      thumbColor: colors.accent,
                      overlayColor:
                          colors.accent.withValues(alpha: 0.18),
                      trackHeight: 3,
                    ),
                    child: Slider(
                      min: 0,
                      max: maxMs.toDouble(),
                      value: pos.inMilliseconds
                          .clamp(0, maxMs)
                          .toDouble(),
                      onChanged: (v) =>
                          player.seekSeconds(v / 1000.0),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    child: Row(
                      mainAxisAlignment:
                          MainAxisAlignment.spaceBetween,
                      children: [
                        Text(formatDuration(pos), style: _mono(colors.inkMuted)),
                        Text('-${formatDuration(dur - pos > Duration.zero ? dur - pos : Duration.zero)}',
                            style: _mono(colors.inkMuted)),
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      _CircleControl(
                        icon: CupertinoIcons.gobackward_15,
                        size: 26,
                        onTap: player.isReady
                            ? () => player.skip(
                                const Duration(seconds: -15))
                            : null,
                        colors: colors,
                      ),
                      _BigPlayBtn(player: player, colors: colors),
                      _CircleControl(
                        icon: CupertinoIcons.goforward_15,
                        size: 26,
                        onTap: player.isReady
                            ? () => player.skip(
                                const Duration(seconds: 15))
                            : null,
                        colors: colors,
                      ),
                    ],
                  ),
                  const SizedBox(height: 22),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      _RatePill(player: player, colors: colors),
                      _SleepPill(player: player, colors: colors),
                      _AlignPill(
                        hasAlignment: hasAlignment,
                        isAligning: isAligning,
                        onTap: onAlign,
                        colors: colors,
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  static TextStyle _mono(Color c) => TextStyle(
        color: c,
        fontSize: 11,
        fontFeatures: const [FontFeature.tabularFigures()],
        fontFamilyFallback: const [
          'JetBrains Mono',
          'Cascadia Code',
          'Roboto Mono',
          'monospace',
        ],
      );
}

class _CircleControl extends StatelessWidget {
  final IconData icon;
  final double size;
  final VoidCallback? onTap;
  final InkAndEchoColors colors;
  const _CircleControl({
    required this.icon,
    required this.size,
    required this.onTap,
    required this.colors,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: Container(
          width: 52,
          height: 52,
          alignment: Alignment.center,
          child: Icon(icon, size: size, color: colors.inkSoft),
        ),
      ),
    );
  }
}

class _BigPlayBtn extends StatelessWidget {
  final InkAndEchoAudioPlayer player;
  final InkAndEchoColors colors;
  const _BigPlayBtn({required this.player, required this.colors});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: colors.accent,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: player.isReady ? player.togglePlay : null,
        child: SizedBox(
          width: 64,
          height: 64,
          child: Icon(
            player.isPlaying ? Icons.pause : Icons.play_arrow,
            color: colors.onAccent,
            size: 32,
          ),
        ),
      ),
    );
  }
}

class _RatePill extends StatelessWidget {
  final InkAndEchoAudioPlayer player;
  final InkAndEchoColors colors;
  const _RatePill({required this.player, required this.colors});

  @override
  Widget build(BuildContext context) {
    const rates = [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0];
    return PopupMenuButton<double>(
      tooltip: 'Playback rate',
      onSelected: player.setRate,
      itemBuilder: (_) => [
        for (final r in rates)
          PopupMenuItem(
            value: r,
            child: Text(
              '${r.toStringAsFixed(r == r.toInt() ? 1 : 2)}x',
              style: TextStyle(
                color: r == player.rate ? colors.accent : colors.ink,
                fontWeight:
                    r == player.rate ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
          ),
      ],
      child: _Pill(
        text: '${player.rate.toStringAsFixed(player.rate == player.rate.toInt() ? 1 : 2)}x',
        icon: Icons.speed,
        colors: colors,
      ),
    );
  }
}

class _SleepPill extends StatelessWidget {
  final InkAndEchoAudioPlayer player;
  final InkAndEchoColors colors;
  const _SleepPill({required this.player, required this.colors});

  @override
  Widget build(BuildContext context) {
    // Presets match the iOS audio bar. Reverse parity gap vs iOS: no
    // "End of chapter" target (needs alignment anchors) and the pause cuts
    // instead of fading out (just_audio exposes setVolume; ramp not built).
    const options = <(String, Duration?)>[
      ('Off', null),
      ('15 min', Duration(minutes: 15)),
      ('30 min', Duration(minutes: 30)),
      ('45 min', Duration(minutes: 45)),
      ('60 min', Duration(minutes: 60)),
    ];
    final left = player.sleepRemaining;
    final label = left == null
        ? 'Sleep'
        : (left.inSeconds >= 60
            ? '${(left.inSeconds / 60).ceil()}m'
            : '${left.inSeconds}s');
    return PopupMenuButton<Duration?>(
      tooltip: 'Sleep timer',
      onSelected: player.setSleepTimer,
      itemBuilder: (_) => [
        for (final (l, d) in options)
          PopupMenuItem(value: d, child: Text(l)),
      ],
      child: _Pill(
        text: label,
        icon: Icons.bedtime_outlined,
        colors: colors,
        active: player.hasSleepTimer,
      ),
    );
  }
}

class _AlignPill extends StatelessWidget {
  final bool hasAlignment;
  final bool isAligning;
  final VoidCallback onTap;
  final InkAndEchoColors colors;
  const _AlignPill({
    required this.hasAlignment,
    required this.isAligning,
    required this.onTap,
    required this.colors,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: hasAlignment ? colors.canvasCool : colors.accent,
      borderRadius: BorderRadius.circular(999),
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: isAligning ? null : onTap,
        child: Container(
          padding:
              const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (isAligning)
                SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor: AlwaysStoppedAnimation(
                        hasAlignment ? colors.accent : colors.onAccent),
                  ),
                )
              else
                Icon(
                  hasAlignment ? Icons.refresh : Icons.auto_awesome,
                  size: 14,
                  color: hasAlignment ? colors.accent : colors.onAccent,
                ),
              const SizedBox(width: 6),
              Text(
                hasAlignment ? 'Re-align' : 'Align',
                style: TextStyle(
                  color: hasAlignment ? colors.accent : colors.onAccent,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  final String text;
  final IconData icon;
  final InkAndEchoColors colors;
  final bool active;
  const _Pill({
    required this.text,
    required this.icon,
    required this.colors,
    this.active = false,
  });

  @override
  Widget build(BuildContext context) {
    final fg = active ? colors.accent : colors.inkSoft;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: active ? colors.accent.withValues(alpha: 0.18) : colors.canvasCool,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: active ? colors.accent : colors.hairline),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: fg),
          const SizedBox(width: 6),
          Text(text,
              style: TextStyle(
                  color: fg,
                  fontSize: 13,
                  fontFeatures: const [FontFeature.tabularFigures()])),
        ],
      ),
    );
  }
}
