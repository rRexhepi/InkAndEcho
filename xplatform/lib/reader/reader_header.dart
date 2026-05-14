part of 'reader_screen.dart';

/// Header slot for the reader. Adapts to platform:
///
/// - Mobile: iOS-style 44pt strip with back / chapters on the left, title
///   centered, overflow on the right. Circular icon buttons.
/// - Desktop: slimmer 38pt strip with the chapter label centered and just an
///   overflow button on the right. The persistent rail handles chapters and
///   the back-to-library affordance, so neither lives in the header.
class ReaderHeader extends StatelessWidget {
  final String title;
  final VoidCallback onBack;
  final VoidCallback onChapters;
  final VoidCallback onOverflow;

  const ReaderHeader({
    super.key,
    required this.title,
    required this.onBack,
    required this.onChapters,
    required this.onOverflow,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return isMobile
        ? _ReaderHeaderMobile(
            title: title,
            onBack: onBack,
            onChapters: onChapters,
            onOverflow: onOverflow,
            colors: colors,
          )
        : _ReaderHeaderDesktop(
            title: title,
            onOverflow: onOverflow,
            colors: colors,
          );
  }
}

class _ReaderHeaderMobile extends StatelessWidget {
  final String title;
  final VoidCallback onBack;
  final VoidCallback onChapters;
  final VoidCallback onOverflow;
  final PalimpsestColors colors;
  const _ReaderHeaderMobile({
    required this.title,
    required this.onBack,
    required this.onChapters,
    required this.onOverflow,
    required this.colors,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: _kHeaderHeight,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Row(
          children: [
            _CircleHeaderBtn(
              icon: const Icon(CupertinoIcons.chevron_back, size: 18),
              colors: colors,
              onTap: onBack,
            ),
            const SizedBox(width: 4),
            _CircleHeaderBtn(
              icon: const Icon(Icons.menu, size: 16),
              colors: colors,
              onTap: onChapters,
            ),
            Expanded(
              child: Text(
                title,
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: colors.ink,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            _CircleHeaderBtn(
              icon: const Icon(Icons.more_horiz, size: 18),
              colors: colors,
              onTap: onOverflow,
            ),
            const SizedBox(width: 4),
          ],
        ),
      ),
    );
  }
}

class _ReaderHeaderDesktop extends StatelessWidget {
  final String title;
  final VoidCallback onOverflow;
  final PalimpsestColors colors;
  const _ReaderHeaderDesktop({
    required this.title,
    required this.onOverflow,
    required this.colors,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 38,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Row(
          children: [
            // No back button — the persistent rail exposes a Back-to-Library
            // affordance so the desktop chrome stays slim.
            Expanded(
              child: Text(
                title,
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: colors.inkSoft,
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  letterSpacing: 0.4,
                ),
              ),
            ),
            _CircleHeaderBtn(
              icon: const Icon(Icons.more_horiz, size: 18),
              colors: colors,
              onTap: onOverflow,
            ),
          ],
        ),
      ),
    );
  }
}

class _CircleHeaderBtn extends StatelessWidget {
  final Widget icon;
  final PalimpsestColors colors;
  final VoidCallback onTap;
  const _CircleHeaderBtn({
    required this.icon,
    required this.colors,
    required this.onTap,
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
          width: 36,
          height: 36,
          alignment: Alignment.center,
          child: IconTheme.merge(
              data: IconThemeData(color: colors.inkSoft), child: icon),
        ),
      ),
    );
  }
}
