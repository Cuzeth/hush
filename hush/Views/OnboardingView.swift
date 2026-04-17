import SwiftUI

struct OnboardingView: View {
    let onComplete: (Preset?) -> Void
    @Environment(\.horizontalSizeClass) private var sizeClass
    @ScaledMetric(relativeTo: .largeTitle) private var heroTitleSize: CGFloat = 40

    var body: some View {
        ZStack {
            HushBackdrop()

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

                Spacer()

                VStack(alignment: .leading, spacing: 10) {
                    principleRow(icon: "lock.shield", text: "No account, no tracking.")
                    principleRow(icon: "iphone", text: "Your presets and sounds stay on this device.")
                    principleRow(icon: "slider.horizontal.3", text: "Mix up to six layers — rain, noise, tones.")
                }

                Spacer().frame(height: 40)

                Button {
                    onComplete(nil)
                } label: {
                    Text("Get Started")
                        .font(.headline)
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity)
                        .frame(height: 56)
                        .background(Capsule().fill(HushPalette.accent))
                }
                .buttonStyle(HushPrimaryButtonStyle())

                Spacer().frame(height: 24)
            }
            .padding(.horizontal, 32)
            .frame(maxWidth: sizeClass == .regular ? 500 : .infinity,
                   alignment: .leading)
        }
    }

    private func principleRow(icon: String, text: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(HushPalette.accentSoft)
                .frame(width: 20)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(HushPalette.textSecondary)
            Spacer(minLength: 0)
        }
    }
}
