part of 'reader_screen.dart';

/// Audio bar slot. Mobile shows either a compact tap-to-expand strip when
/// audio is attached or an attach prompt when none is. Desktop shows the
/// full footer with cover art, transport, and rate / sleep / align pills.
class ReaderAudioBar extends StatelessWidget {
  final PalimpsestAudioPlayer player;
  final StoredBook book;
  final bool hasAlignment;
  final bool isAligning;
  final VoidCallback onAttach;
  final VoidCallback onAlign;
  final VoidCallback onReplaceAudio;
  final VoidCallback onShowSheet;

  const ReaderAudioBar({
    super.key,
    required this.player,
    required this.book,
    required this.hasAlignment,
    required this.isAligning,
    required this.onAttach,
    required this.onAlign,
    required this.onReplaceAudio,
    required this.onShowSheet,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    if (isMobile) {
      if (book.audioPath == null) {
        return _AttachAudiobookBar(onTap: onAttach, colors: colors);
      }
      return _CompactAudioBar(
        player: player,
        hasAlignment: hasAlignment,
        onTap: onShowSheet,
        colors: colors,
      );
    }
    return _TabletAudioFooter(
      player: player,
      book: book,
      hasAlignment: hasAlignment,
      isAligning: isAligning,
      onAttach: onAttach,
      onAlign: onAlign,
      onReplaceAudio: onReplaceAudio,
      colors: colors,
    );
  }
}
enum _FooterAction { replace }

class _AttachAudiobookBar extends StatelessWidget {
  final VoidCallback onTap;
  final PalimpsestColors colors;
  const _AttachAudiobookBar({required this.onTap, required this.colors});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 64,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        color: colors.canvasDeep,
        border: Border(top: BorderSide(color: colors.hairline)),
      ),
      child: Row(
        children: [
          Icon(Icons.volume_up_outlined, size: 18, color: colors.inkMuted),
          const SizedBox(width: 12),
          Text(
            'No audiobook attached',
            style: TextStyle(color: colors.inkMuted, fontSize: 14),
          ),
          const Spacer(),
          Material(
            color: colors.accent,
            borderRadius: BorderRadius.circular(6),
            child: InkWell(
              borderRadius: BorderRadius.circular(6),
              onTap: onTap,
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.add, size: 16, color: colors.onAccent),
                    const SizedBox(width: 4),
                    Text(
                      'Attach…',
                      style: TextStyle(
                        color: colors.onAccent,
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CompactAudioBar extends StatelessWidget {
  final PalimpsestAudioPlayer player;
  final bool hasAlignment;
  final VoidCallback onTap;
  final PalimpsestColors colors;
  const _CompactAudioBar({
    required this.player,
    required this.hasAlignment,
    required this.onTap,
    required this.colors,
  });

  static String _fmt(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    final h = d.inHours;
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      onVerticalDragEnd: (d) {
        if ((d.primaryVelocity ?? 0) < -200) onTap();
      },
      child: ListenableBuilder(
        listenable: player,
        builder: (_, _) => Container(
          padding: const EdgeInsets.fromLTRB(14, 8, 14, 12),
          decoration: BoxDecoration(
            color: colors.canvasCool,
            border:
                Border(top: BorderSide(color: colors.hairline)),
          ),
          child: Column(
            children: [
              Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: colors.hairlineStrong,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  _MiniPlayBtn(player: player, colors: colors),
                  const SizedBox(width: 10),
                  Text(_fmt(player.position),
                      style: _mono(colors.inkMuted)),
                  const SizedBox(width: 8),
                  Expanded(
                    child: SliderTheme(
                      data: SliderTheme.of(context).copyWith(
                        activeTrackColor: colors.accent,
                        inactiveTrackColor: colors.hairlineStrong,
                        thumbColor: colors.accent,
                        overlayColor:
                            colors.accent.withValues(alpha: 0.18),
                        trackHeight: 2,
                        thumbShape:
                            const RoundSliderThumbShape(enabledThumbRadius: 5),
                      ),
                      child: Slider(
                        min: 0,
                        max: (player.duration?.inMilliseconds ?? 1).toDouble(),
                        value: player.position.inMilliseconds
                            .clamp(0,
                                (player.duration?.inMilliseconds ?? 1))
                            .toDouble(),
                        onChanged: (v) => player.seekSeconds(v / 1000.0),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(_fmt(player.duration ?? Duration.zero),
                      style: _mono(colors.inkMuted)),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  static TextStyle _mono(Color c) => TextStyle(
        color: c,
        fontSize: 10,
        fontFeatures: const [FontFeature.tabularFigures()],
        fontFamilyFallback: const [
          'JetBrains Mono',
          'Cascadia Code',
          'Roboto Mono',
          'monospace',
        ],
      );
}

class _MiniPlayBtn extends StatelessWidget {
  final PalimpsestAudioPlayer player;
  final PalimpsestColors colors;
  const _MiniPlayBtn({required this.player, required this.colors});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: colors.accent,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: player.isReady ? player.togglePlay : null,
        child: SizedBox(
          width: 32,
          height: 32,
          child: Icon(
            player.isPlaying ? Icons.pause : Icons.play_arrow,
            color: colors.onAccent,
            size: 18,
          ),
        ),
      ),
    );
  }
}
class _TabletAudioFooter extends StatelessWidget {
  final PalimpsestAudioPlayer player;
  final StoredBook book;
  final bool hasAlignment;
  final bool isAligning;
  final VoidCallback onAttach;
  final VoidCallback onAlign;
  final VoidCallback onReplaceAudio;
  final PalimpsestColors colors;
  const _TabletAudioFooter({
    required this.player,
    required this.book,
    required this.hasAlignment,
    required this.isAligning,
    required this.onAttach,
    required this.onAlign,
    required this.onReplaceAudio,
    required this.colors,
  });

  static String _fmt(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    final h = d.inHours;
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: player,
      builder: (_, _) {
        final hasAudio = book.audioPath != null;
        if (!hasAudio) {
          return Container(
            height: 64,
            decoration: BoxDecoration(
              color: colors.canvasCool,
              border: Border(top: BorderSide(color: colors.hairline)),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Row(
              children: [
                Icon(Icons.headphones,
                    size: 18, color: colors.accent),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Attach an audiobook to begin sync.',
                    style: TextStyle(color: colors.inkSoft, fontSize: 13),
                  ),
                ),
                Material(
                  color: colors.accent,
                  borderRadius: BorderRadius.circular(999),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(999),
                    onTap: onAttach,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 8),
                      child: Text(
                        'Attach',
                        style: TextStyle(
                          color: colors.onAccent,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          );
        }
        return Container(
          decoration: BoxDecoration(
            color: colors.canvasCool,
            border: Border(top: BorderSide(color: colors.hairline)),
          ),
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
          child: Row(
            children: [
              IconButton(
                icon: const Icon(CupertinoIcons.gobackward_15),
                color: colors.inkSoft,
                iconSize: 22,
                onPressed: player.isReady
                    ? () => player.skip(const Duration(seconds: -15))
                    : null,
              ),
              Material(
                color: colors.accent,
                shape: const CircleBorder(),
                child: InkWell(
                  customBorder: const CircleBorder(),
                  onTap: player.isReady ? player.togglePlay : null,
                  child: SizedBox(
                    width: 44,
                    height: 44,
                    child: Icon(
                      player.isPlaying ? Icons.pause : Icons.play_arrow,
                      color: colors.onAccent,
                      size: 24,
                    ),
                  ),
                ),
              ),
              IconButton(
                icon: const Icon(CupertinoIcons.goforward_15),
                color: colors.inkSoft,
                iconSize: 22,
                onPressed: player.isReady
                    ? () => player.skip(const Duration(seconds: 15))
                    : null,
              ),
              const SizedBox(width: 12),
              Text(_fmt(player.position),
                  style: _mono(colors.inkMuted)),
              const SizedBox(width: 8),
              Expanded(
                child: SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    activeTrackColor: colors.accent,
                    inactiveTrackColor: colors.hairlineStrong,
                    thumbColor: colors.accent,
                    overlayColor:
                        colors.accent.withValues(alpha: 0.18),
                    trackHeight: 2,
                    thumbShape: const RoundSliderThumbShape(
                        enabledThumbRadius: 6),
                  ),
                  child: Slider(
                    min: 0,
                    max: (player.duration?.inMilliseconds ?? 1).toDouble(),
                    value: player.position.inMilliseconds
                        .clamp(
                            0, (player.duration?.inMilliseconds ?? 1))
                        .toDouble(),
                    onChanged: (v) => player.seekSeconds(v / 1000.0),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(_fmt(player.duration ?? Duration.zero),
                  style: _mono(colors.inkMuted)),
              const SizedBox(width: 12),
              _FooterRatePill(player: player, colors: colors),
              const SizedBox(width: 8),
              _FooterSleepPill(player: player, colors: colors),
              const SizedBox(width: 8),
              _FooterAlignPill(
                hasAlignment: hasAlignment,
                isAligning: isAligning,
                onTap: onAlign,
                colors: colors,
              ),
              const SizedBox(width: 4),
              PopupMenuButton<_FooterAction>(
                tooltip: 'More',
                icon: Icon(Icons.more_horiz,
                    size: 18, color: colors.inkSoft),
                color: colors.canvas,
                onSelected: (a) {
                  switch (a) {
                    case _FooterAction.replace:
                      onReplaceAudio();
                  }
                },
                itemBuilder: (_) => [
                  PopupMenuItem<_FooterAction>(
                    value: _FooterAction.replace,
                    child: Row(
                      children: [
                        Icon(Icons.swap_horiz,
                            size: 18, color: colors.inkSoft),
                        const SizedBox(width: 10),
                        Text('Replace audiobook…',
                            style: TextStyle(color: colors.ink)),
                      ],
                    ),
                  ),
                ],
              ),
            ],
          ),
        );
      },
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

class _FooterRatePill extends StatelessWidget {
  final PalimpsestAudioPlayer player;
  final PalimpsestColors colors;
  const _FooterRatePill({required this.player, required this.colors});

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
      child: _FooterPill(
        text:
            '${player.rate.toStringAsFixed(player.rate == player.rate.toInt() ? 1 : 2)}x',
        icon: Icons.speed,
        colors: colors,
      ),
    );
  }
}

class _FooterSleepPill extends StatelessWidget {
  final PalimpsestAudioPlayer player;
  final PalimpsestColors colors;
  const _FooterSleepPill({required this.player, required this.colors});

  @override
  Widget build(BuildContext context) {
    const options = <(String, Duration?)>[
      ('Off', null),
      ('5 min', Duration(minutes: 5)),
      ('15 min', Duration(minutes: 15)),
      ('30 min', Duration(minutes: 30)),
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
        for (final (l, d) in options) PopupMenuItem(value: d, child: Text(l)),
      ],
      child: _FooterPill(
        text: label,
        icon: Icons.bedtime_outlined,
        colors: colors,
        active: player.hasSleepTimer,
      ),
    );
  }
}

class _FooterAlignPill extends StatelessWidget {
  final bool hasAlignment;
  final bool isAligning;
  final VoidCallback onTap;
  final PalimpsestColors colors;
  const _FooterAlignPill({
    required this.hasAlignment,
    required this.isAligning,
    required this.onTap,
    required this.colors,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: hasAlignment ? colors.canvas : colors.accent,
      borderRadius: BorderRadius.circular(999),
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: isAligning ? null : onTap,
        child: Container(
          padding:
              const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(999),
            border: hasAlignment
                ? Border.all(color: colors.hairline)
                : null,
          ),
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
                  fontSize: 12,
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

// ---------------------------------------------------------------------------
// Alignment fullscreen — first-run overlay matching iOS `alignmentFullscreen`.
// ---------------------------------------------------------------------------
class _CoverThumb extends StatelessWidget {
  final StoredBook book;
  final PalimpsestColors colors;
  const _CoverThumb({required this.book, required this.colors});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 120,
      height: 180,
      decoration: BoxDecoration(
        color: colors.canvasDeep,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: colors.hairline),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.18),
            blurRadius: 18,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: book.coverPath != null
          ? ClipRRect(
              borderRadius: BorderRadius.circular(5),
              child: Image.file(
                File(book.coverPath!),
                fit: BoxFit.cover,
              ),
            )
          : Center(
              child: Padding(
                padding: const EdgeInsets.all(10),
                child: Text(
                  book.title,
                  textAlign: TextAlign.center,
                  maxLines: 4,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: colors.inkSoft,
                    fontSize: 12,
                    height: 1.2,
                  ),
                ),
              ),
            ),
    );
  }
}

class _PhaseTick extends StatelessWidget {
  final String label;
  final bool isActive;
  final bool isDone;
  final PalimpsestColors colors;
  const _PhaseTick({
    required this.label,
    required this.isActive,
    required this.isDone,
    required this.colors,
  });

  @override
  Widget build(BuildContext context) {
    final dotColor = isActive
        ? colors.accent
        : isDone
            ? colors.accent.withValues(alpha: 0.55)
            : colors.hairlineStrong;
    final textColor = isActive ? colors.ink : colors.inkMuted;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(
            color: dotColor,
            shape: BoxShape.circle,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          label,
          style: TextStyle(
            color: textColor,
            fontSize: 10,
            fontWeight: isActive ? FontWeight.w600 : FontWeight.w400,
            letterSpacing: 0.6,
          ),
        ),
      ],
    );
  }
}

class _FooterPill extends StatelessWidget {
  final String text;
  final IconData icon;
  final PalimpsestColors colors;
  final bool active;
  const _FooterPill({
    required this.text,
    required this.icon,
    required this.colors,
    this.active = false,
  });

  @override
  Widget build(BuildContext context) {
    final fg = active ? colors.accent : colors.inkSoft;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
      decoration: BoxDecoration(
        color:
            active ? colors.accent.withValues(alpha: 0.18) : colors.canvas,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: active ? colors.accent : colors.hairline),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: fg),
          const SizedBox(width: 6),
          Text(text,
              style: TextStyle(
                  color: fg,
                  fontSize: 12,
                  fontFeatures: const [FontFeature.tabularFigures()])),
        ],
      ),
    );
  }
}
