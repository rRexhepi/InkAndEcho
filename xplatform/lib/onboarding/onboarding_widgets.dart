import 'package:flutter/material.dart';

import '../theme.dart';

class OnboardingSlide {
  final String kicker;
  final String title;
  final String body;
  final IconData icon;
  const OnboardingSlide({
    required this.kicker,
    required this.title,
    required this.body,
    required this.icon,
  });
}

const List<OnboardingSlide> kOnboardingSlides = [
  OnboardingSlide(
    kicker: 'Welcome',
    title: 'Palimpsest',
    body: 'An ebook + audiobook reader that keeps the page and the voice in sync.',
    icon: Icons.menu_book_outlined,
  ),
  OnboardingSlide(
    kicker: 'How it works',
    title: 'Three steps',
    body: 'Import an EPUB. Attach an audiobook. Run alignment once and the reader marries page to narration.',
    icon: Icons.auto_awesome,
  ),
  OnboardingSlide(
    kicker: 'Local first',
    title: 'Your library stays on this device',
    body: 'Audio, text, and Whisper transcription all run on-device. Nothing leaves the phone unless you share it.',
    icon: Icons.shield_outlined,
  ),
  OnboardingSlide(
    kicker: "You're set",
    title: 'Begin reading',
    body: 'Tap Start to open your library and import your first book.',
    icon: Icons.east,
  ),
];

class OnboardingSlideView extends StatelessWidget {
  final OnboardingSlide slide;
  final PalimpsestColors colors;
  const OnboardingSlideView(
      {super.key, required this.slide, required this.colors});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 36),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 92,
            height: 92,
            decoration: BoxDecoration(
              color: colors.canvasCool,
              shape: BoxShape.circle,
              border: Border.all(color: colors.hairline),
            ),
            child: Icon(slide.icon, size: 44, color: colors.accent),
          ),
          const SizedBox(height: 32),
          Text(
            slide.kicker.toUpperCase(),
            style: TextStyle(
              color: colors.inkMuted,
              fontSize: 11,
              fontWeight: FontWeight.w600,
              letterSpacing: 1.5,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            slide.title,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: colors.ink,
              fontSize: 28,
              fontWeight: FontWeight.w600,
              height: 1.15,
            ),
          ),
          const SizedBox(height: 16),
          Text(
            slide.body,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: colors.inkMuted,
              fontSize: 15,
              height: 1.45,
            ),
          ),
        ],
      ),
    );
  }
}
