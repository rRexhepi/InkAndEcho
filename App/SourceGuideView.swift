import SwiftUI

/// Where-to-find-books guide, presented as a sheet from the import-failed
/// alert (the DRM churn moment) and a Settings row. Legal sources only —
/// never name or link shadow libraries here, in the app, or on the landing
/// page (App Store 3.1.1 + contributory-infringement exposure).
struct SourceGuideView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                section(
                    title: "Free · public domain",
                    icon: "books.vertical"
                ) {
                    linkRow(
                        "Standard Ebooks",
                        detail: "Carefully typeset public-domain EPUBs.",
                        url: "https://standardebooks.org"
                    )
                    linkRow(
                        "Project Gutenberg",
                        detail: "75,000+ public-domain EPUBs.",
                        url: "https://www.gutenberg.org"
                    )
                    linkRow(
                        "LibriVox",
                        detail: "Volunteer-read public-domain audiobooks, free MP3 downloads.",
                        url: "https://librivox.org"
                    )
                }
                section(
                    title: "Buy DRM-free",
                    icon: "bag"
                ) {
                    plainRow(
                        "Audiobooks",
                        detail: "Libro.fm and Downpour sell audiobooks as plain MP3 downloads you own."
                    )
                    plainRow(
                        "Ebooks",
                        detail: "Many publishers and stores sell DRM-free EPUBs — look for a “DRM-free” label before buying."
                    )
                }
                section(
                    title: "Won't work",
                    icon: "lock",
                    tone: .warning
                ) {
                    plainRow(
                        "Audible, Kindle, Libby, Storytel",
                        detail: "These are DRM-locked: their apps never hand over a file that Ink and Echo — or any other reader — can open. A purchase there stays inside their app."
                    )
                }
                Text("Ink and Echo reads the files you own: .epub, .mobi, or .pdf for the text, .m4b or .mp3 for the narration.")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Theme.inkMuted)
                    .padding(.top, 4)
            }
            .padding(24)
        }
        .background(Theme.canvas)
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Finding books")
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(1.2)
                    .textCase(.uppercase)
                    .foregroundStyle(Theme.inkMuted)
                Text("Where books and audiobooks come from")
                    .font(.system(size: 22, design: .serif))
                    .fontWeight(.semibold)
                    .foregroundStyle(Theme.ink)
            }
            Spacer(minLength: 12)
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.inkMuted)
                    .frame(width: 32, height: 32)
                    .background(Theme.canvasDeep.opacity(0.5))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
        }
    }

    private enum Tone { case neutral, warning }

    private func section(
        title: String,
        icon: String,
        tone: Tone = .neutral,
        @ViewBuilder rows: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(tone == .warning ? Theme.warning : Theme.accent)
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .tracking(0.8)
                    .textCase(.uppercase)
                    .foregroundStyle(Theme.inkSoft)
            }
            VStack(alignment: .leading, spacing: 14) {
                rows()
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.canvasCool)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Theme.hairline, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }

    private func linkRow(_ title: String, detail: String, url: String) -> some View {
        Link(destination: URL(string: url)!) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(title)
                        .font(.system(size: 15, design: .serif))
                        .fontWeight(.semibold)
                        .foregroundStyle(Theme.accent)
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.accent.opacity(0.7))
                }
                Text(detail)
                    .font(.system(size: 13, design: .serif))
                    .foregroundStyle(Theme.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func plainRow(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 15, design: .serif))
                .fontWeight(.semibold)
                .foregroundStyle(Theme.ink)
            Text(detail)
                .font(.system(size: 13, design: .serif))
                .foregroundStyle(Theme.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
