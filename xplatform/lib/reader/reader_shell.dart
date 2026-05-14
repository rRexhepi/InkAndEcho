part of 'reader_screen.dart';

/// Generic slot-composing shell used by the reader. Presence of a slot
/// determines whether it is rendered, so platform decisions live in the
/// caller (the state's build) rather than here.
///
/// Layout:
/// - If [rail] is non-null, an outer Row places it on the left with a
///   1px divider, body on the right.
/// - The body is a Column of [header], [alignBanner], [Expanded(pageView)],
///   [audioBar] in that order. Any of those may be null and is then
///   skipped, so callers can hide chrome (mobile tap-to-hide) or omit
///   the alignment banner without conditionally building two trees.
class ReaderShell extends StatelessWidget {
  final Widget? rail;
  final Widget? header;
  final Widget? alignBanner;
  final Widget pageView;
  final Widget? audioBar;

  const ReaderShell({
    super.key,
    required this.pageView,
    this.rail,
    this.header,
    this.alignBanner,
    this.audioBar,
  });

  @override
  Widget build(BuildContext context) {
    final body = Column(
      children: [
        ?header,
        ?alignBanner,
        Expanded(child: pageView),
        ?audioBar,
      ],
    );
    if (rail == null) return body;
    return Row(
      children: [
        rail!,
        Container(width: 1, color: context.colors.hairline),
        Expanded(child: body),
      ],
    );
  }
}
