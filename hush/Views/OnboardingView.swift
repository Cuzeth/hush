import SwiftUI

struct OnboardingView: View {
    let onComplete: (Preset?) -> Void
    @State private var page = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let quickPresets: [Preset] = Array(Preset.builtIn.prefix(3))

    var body: some View {
        ZStack {
            HushBackdrop()

            VStack(spacing: 0) {
                // Skip button — always available
                HStack {
                    Spacer()
                    Button("Skip") { onComplete(nil) }
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(HushPalette.textSecondary)
                        .padding(.trailing, 24)
                        .padding(.top, 16)
                }

                TabView(selection: $page) {
                    welcomePage.tag(0)
                    pickSoundPage.tag(1)
                    readyPage.tag(2)
                }
                .tabViewStyle(.page(indexDisplayMode: .always))
            }
        }
    }

    // MARK: - Page 1: Welcome

    private var welcomePage: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 72))
                .foregroundStyle(HushPalette.accent)

            VStack(spacing: 10) {
                Text("Hush")
                    .font(.system(size: 36, weight: .bold, design: .serif))
                    .foregroundStyle(HushPalette.textPrimary)

                Text("Focus sounds for your brain.")
                    .font(.title3)
                    .foregroundStyle(HushPalette.textSecondary)
            }

            Spacer()

            Button {
                withAnimation(reduceMotion ? .none : .easeInOut(duration: 0.3)) { page = 1 }
            } label: {
                Text("Get Started")
                    .font(.headline)
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity)
                    .frame(height: 56)
                    .background(Capsule().fill(HushPalette.accent))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 32)
            .padding(.bottom, 48)
        }
    }

    // MARK: - Page 2: Pick a sound

    private var pickSoundPage: some View {
        VStack(spacing: 24) {
            Spacer()

            VStack(spacing: 10) {
                Text("Pick a sound")
                    .font(.system(size: 28, weight: .semibold, design: .serif))
                    .foregroundStyle(HushPalette.textPrimary)

                Text("Tap one to start listening.")
                    .font(.subheadline)
                    .foregroundStyle(HushPalette.textSecondary)
            }

            VStack(spacing: 12) {
                ForEach(quickPresets) { preset in
                    Button { onComplete(preset) } label: {
                        HStack(spacing: 14) {
                            Image(systemName: preset.icon)
                                .font(.title3)
                                .frame(width: 44, height: 44)
                                .background(HushPalette.surfaceRaised)
                                .clipShape(Circle())

                            VStack(alignment: .leading, spacing: 2) {
                                Text(preset.name)
                                    .font(.headline)
                                    .foregroundStyle(HushPalette.textPrimary)
                                Text(preset.sources.map(\.type.rawValue).joined(separator: " + "))
                                    .font(.caption)
                                    .foregroundStyle(HushPalette.textSecondary)
                            }

                            Spacer()

                            Image(systemName: "play.circle.fill")
                                .font(.title2)
                                .foregroundStyle(HushPalette.accent)
                        }
                        .padding(16)
                        .hushPanel(radius: 18, fill: HushPalette.surface.opacity(0.92))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 32)

            Spacer()

            Button {
                withAnimation(reduceMotion ? .none : .easeInOut(duration: 0.3)) { page = 2 }
            } label: {
                Text("I'll browse first")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(HushPalette.textSecondary)
            }
            .padding(.bottom, 48)
        }
    }

    // MARK: - Page 3: Ready

    private var readyPage: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 60))
                .foregroundStyle(HushPalette.accentSoft)

            VStack(spacing: 10) {
                Text("You're all set")
                    .font(.system(size: 28, weight: .semibold, design: .serif))
                    .foregroundStyle(HushPalette.textPrimary)

                Text("No account needed. No tracking.\nJust sound.")
                    .font(.subheadline)
                    .foregroundStyle(HushPalette.textSecondary)
                    .multilineTextAlignment(.center)
            }

            Spacer()

            Button { onComplete(nil) } label: {
                Text("Start Using Hush")
                    .font(.headline)
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity)
                    .frame(height: 56)
                    .background(Capsule().fill(HushPalette.accent))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 32)
            .padding(.bottom, 48)
        }
    }
}
