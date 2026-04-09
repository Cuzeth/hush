import SwiftUI

struct OnboardingView: View {
    let onComplete: (Preset?) -> Void
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        ZStack {
            HushBackdrop()

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
                    onComplete(nil)
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
            .frame(maxWidth: sizeClass == .regular ? 500 : .infinity)
        }
    }
}
