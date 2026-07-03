#if os(iOS)
import SwiftUI

/// First-launch onboarding for iOS. Four screens: welcome (logomark +
/// tagline), how-it-works (3 numbered steps), local-first privacy, and
/// you're-set CTA. Persisted via `inkandecho.hasCompletedOnboarding` in
/// `LibraryView`. `onFinish` triggers the import picker; `onTryDemo`
/// installs the bundled demo pair (read-along live immediately).
struct OnboardingView: View {
    let onFinish: () -> Void
    let onTryDemo: () -> Void
    @State private var page: Int = 0

    private let totalPages = 4

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $page) {
                welcome.tag(0)
                howItWorks.tag(1)
                privacy.tag(2)
                ready.tag(3)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            footer
        }
        .background(Theme.canvas)
        .ignoresSafeArea(.keyboard)
    }

    // MARK: - Screens

    private var welcome: some View {
        VStack(spacing: 32) {
            Spacer()
            logomark
            VStack(spacing: 12) {
                (Text("Ink ")
                    + Text("and").italic().foregroundColor(Theme.accent)
                    + Text(" Echo"))
                    .font(.system(size: 32, design: .serif))
                    .fontWeight(.semibold)
                    .foregroundStyle(Theme.ink)
                Text("An audiobook reader that knows where you are in the text. Listen, read, or do both. Mark paragraphs and the audio comes with you.")
                    .font(.system(size: 16, design: .serif))
                    .foregroundStyle(Theme.inkSoft)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
            Spacer()
        }
    }

    private var howItWorks: some View {
        VStack(spacing: 24) {
            Spacer()
            VStack(spacing: 6) {
                Text("How it works")
                    .font(.system(size: 24, design: .serif))
                    .fontWeight(.semibold)
                    .foregroundStyle(Theme.ink)
                Text("Three steps, once per book.")
                    .font(.system(size: 14, design: .serif))
                    .foregroundStyle(Theme.inkMuted)
            }
            VStack(spacing: 14) {
                onboardingCell(n: 1, title: "Attach", body: "Drop in an .epub and the matching .m4b. Both stay on this device.")
                onboardingCell(n: 2, title: "Align", body: "WhisperKit transcribes the audio locally and anchors each paragraph.")
                onboardingCell(n: 3, title: "Read along", body: "The page follows the narrator. Tap a paragraph to jump audio to it.")
            }
            .padding(.horizontal, 24)
            Spacer()
        }
    }

    private var privacy: some View {
        VStack(spacing: 16) {
            Spacer()
            Text("Local first")
                .font(.system(size: 11, weight: .semibold))
                .tracking(1.5)
                .textCase(.uppercase)
                .foregroundStyle(Theme.accent)
            Text("Your books never leave this device.")
                .font(.system(size: 24, design: .serif))
                .fontWeight(.semibold)
                .foregroundStyle(Theme.ink)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)
            Text("Transcription, alignment, and notes all happen on this device. There is no account, no upload, no telemetry.")
                .font(.system(size: 15, design: .serif))
                .foregroundStyle(Theme.inkSoft)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
                .padding(.top, 4)
            VStack(alignment: .leading, spacing: 4) {
                privacyLine("no upload")
                privacyLine("no account")
                privacyLine("no analytics")
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.canvasCool)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Theme.hairline, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 32)
            .padding(.top, 12)
            Spacer()
        }
    }

    private var ready: some View {
        VStack(spacing: 16) {
            Spacer()
            Text("You're set.")
                .font(.system(size: 32, design: .serif))
                .fontWeight(.semibold)
                .foregroundStyle(Theme.ink)
            Text("Bring an ebook and an audiobook. Ink and Echo will pair them on this device.")
                .font(.system(size: 15, design: .serif))
                .foregroundStyle(Theme.inkSoft)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            // Primary CTA: the bundled demo pair is already aligned, so
            // this is the zero-wait path to seeing read-along work.
            Button(action: onTryDemo) {
                Text("Try it with a demo book")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.onAccent)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 12)
                    .background(Theme.accent)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .padding(.top, 12)
            Text("a ten-minute story, narration already synced")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Theme.inkMuted)
            Spacer()
        }
    }

    // MARK: - Pieces

    private var logomark: some View {
        Image("InkAndEchoMark")
            .resizable()
            .scaledToFill()
            .frame(width: 96, height: 96)
            .clipShape(RoundedRectangle(cornerRadius: 22))
            .overlay(
                RoundedRectangle(cornerRadius: 22)
                    .stroke(Theme.hairlineStrong, lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.18), radius: 12, x: 0, y: 6)
    }

    private func onboardingCell(n: Int, title: String, body: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text("\(n)")
                .font(.system(size: 14, design: .serif))
                .fontWeight(.semibold)
                .foregroundStyle(Theme.onAccent)
                .frame(width: 28, height: 28)
                .background(Theme.accent)
                .clipShape(Circle())
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 16, design: .serif))
                    .fontWeight(.semibold)
                    .foregroundStyle(Theme.ink)
                Text(body)
                    .font(.system(size: 13, design: .serif))
                    .foregroundStyle(Theme.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
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

    private func privacyLine(_ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.accent)
            Text(text)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Theme.inkSoft)
        }
    }

    private var footer: some View {
        HStack {
            HStack(spacing: 6) {
                ForEach(0..<totalPages, id: \.self) { idx in
                    Circle()
                        .fill(idx == page ? Theme.accent : Theme.hairlineStrong)
                        .frame(width: 6, height: 6)
                }
            }
            Spacer()
            HStack(spacing: 8) {
                if page > 0 {
                    Button {
                        withAnimation { page -= 1 }
                    } label: {
                        Text("Back")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Theme.inkSoft)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(Theme.canvasCool)
                            .overlay(
                                Capsule().stroke(Theme.hairline, lineWidth: 1)
                            )
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
                Button {
                    if page < totalPages - 1 {
                        withAnimation { page += 1 }
                    } else {
                        onFinish()
                    }
                } label: {
                    Text(page < totalPages - 1 ? "Continue" : "Import a book")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.onAccent)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Theme.accent)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .background(Theme.canvasCool)
        .overlay(Rectangle().fill(Theme.hairline).frame(height: 1), alignment: .top)
    }
}
#endif
