import 'package:flutter/material.dart';

import '../theme.dart';
import 'onboarding_widgets.dart';

class OnboardingScreen extends StatefulWidget {
  final VoidCallback onDone;
  const OnboardingScreen({super.key, required this.onDone});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final _controller = PageController();
  int _index = 0;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _advance() {
    if (_index < kOnboardingSlides.length - 1) {
      _controller.nextPage(
        duration: const Duration(milliseconds: 240),
        curve: Curves.easeOut,
      );
    } else {
      widget.onDone();
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final isLast = _index == kOnboardingSlides.length - 1;
    return Scaffold(
      backgroundColor: colors.canvas,
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: PageView.builder(
                controller: _controller,
                itemCount: kOnboardingSlides.length,
                onPageChanged: (i) => setState(() => _index = i),
                itemBuilder: (_, i) => OnboardingSlideView(
                  slide: kOnboardingSlides[i],
                  colors: colors,
                ),
              ),
            ),
            _PageDots(count: kOnboardingSlides.length, index: _index),
            const SizedBox(height: 28),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 28),
              child: SizedBox(
                width: double.infinity,
                child: _PrimaryPill(
                  label: isLast ? 'Start' : 'Continue',
                  onTap: _advance,
                ),
              ),
            ),
            TextButton(
              onPressed: widget.onDone,
              child: Text('Skip',
                  style: TextStyle(color: colors.inkMuted)),
            ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }
}

class _PageDots extends StatelessWidget {
  final int count;
  final int index;
  const _PageDots({required this.count, required this.index});

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        for (var i = 0; i < count; i++)
          Container(
            margin: const EdgeInsets.symmetric(horizontal: 4),
            width: i == index ? 18 : 6,
            height: 6,
            decoration: BoxDecoration(
              color: i == index ? colors.accent : colors.hairlineStrong,
              borderRadius: BorderRadius.circular(3),
            ),
          ),
      ],
    );
  }
}

class _PrimaryPill extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  const _PrimaryPill({required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Material(
      color: colors.accent,
      borderRadius: BorderRadius.circular(999),
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 14),
          child: Center(
            child: Text(
              label,
              style: TextStyle(
                color: colors.onAccent,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
