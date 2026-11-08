import SwiftUI

/// One-shot handoff from onboarding to the player. ContentView only flips
/// `hasCompletedOnboarding`, and the view model lives there, so "Get
/// Started" raises this flag and PlayerView's first appearance consumes it
/// to load and play the first visible scene.
enum OnboardingHandoff {
    private static var startFirstScene = false

    static func requestStartFirstScene() {
        startFirstScene = true
    }

    /// True once per request; clears the flag.
    static func consumeStartFirstScene() -> Bool {
        defer { startFirstScene = false }
        return startFirstScene
    }
}

struct OnboardingView: View {
    let onComplete: () -> Void
    @Environment(\.horizontalSizeClass) private var sizeClass
    @ScaledMetric(relativeTo: .largeTitle) private var heroTitleSize: CGFloat = 40

    var body: some View {
        ZStack {
            HushBackdrop()

            // Scrolls only when it has to: at accessibility text sizes on
            // small phones the content outgrows the screen and "Get Started"
            // must stay reachable. At default sizes the min-height frame
            // keeps the spacer layout filling exactly one screen.
            GeometryReader { proxy in
                ScrollView {
                    content
                        .frame(minHeight: proxy.size.height)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer()

            VStack(alignment: .leading, spacing: 12) {
                Text("Hush")
                    .font(.system(size: heroTitleSize, weight: .semibold, design: .serif))
                    .foregroundStyle(HushPalette.textPrimary)

                Text("Focus sounds you shape yourself.")
                    .font(.title3)
                    .foregroundStyle(HushPalette.textSecondary)
            }

            Spacer(minLength: 32)

            VStack(alignment: .leading, spacing: 10) {
                principleRow(icon: "lock.shield", text: "No account, no tracking.")
                principleRow(icon: "iphone", text: "Your presets and sounds stay on this device.")
                principleRow(icon: "slider.horizontal.3", text: "Mix up to six layers — rain, noise, tones.")
            }

            Spacer().frame(height: 40)

            Button {
                OnboardingHandoff.requestStartFirstScene()
                onComplete()
            } label: {
                Text("Get Started")
                    .font(.headline)
                    .foregroundStyle(HushPalette.onAccent)
                    .frame(maxWidth: .infinity)
                    // minHeight, not height: a fixed 56pt clips the label
                    // at accessibility Dynamic Type sizes.
                    .frame(minHeight: 56)
                    .background(Capsule().fill(HushPalette.accent))
            }
            .buttonStyle(HushPrimaryButtonStyle())
            .accessibilityHint("Starts playing the first scene")

            Spacer().frame(height: 24)
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: sizeClass == .regular ? 500 : .infinity,
               alignment: .leading)
        .frame(maxWidth: .infinity)
    }

    private func principleRow(icon: String, text: String) -> some View {
        HStack(spacing: 12) {
            // Decorative: VoiceOver would otherwise read "lock shield".
            Image(systemName: icon)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(HushPalette.accentSoft)
                .frame(width: 20)
                .accessibilityHidden(true)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(HushPalette.textSecondary)
            Spacer(minLength: 0)
        }
    }
}
