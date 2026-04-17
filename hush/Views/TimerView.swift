import SwiftUI

struct TimerView: View {
    @Bindable var viewModel: PlayerViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var customMinutes = 25
    @ScaledMetric(relativeTo: .largeTitle) private var countdownFontSize: CGFloat = 38

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12)
    ]

    var body: some View {
        NavigationStack {
            ZStack {
                HushBackdrop()

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 22) {
                        if viewModel.timerState.isRunning {
                            runningTimerView
                        } else {
                            durationPicker
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 14)
                    .padding(.bottom, 28)
                }
            }
            .navigationTitle("Timer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(HushPalette.textPrimary)
                }
            }
        }
        .tint(HushPalette.accentSoft)
        .sensoryFeedback(trigger: viewModel.timerState.isRunning) { _, isRunning in
            isRunning ? .start : .stop
        }
    }

    private var runningTimerView: some View {
        VStack(spacing: 22) {
            ZStack {
                Circle()
                    .stroke(HushPalette.outlineStrong, lineWidth: 8)

                Circle()
                    .trim(from: 0, to: viewModel.timerState.progress)
                    .stroke(
                        HushPalette.accentSoft,
                        style: StrokeStyle(lineWidth: 8, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .animation(reduceMotion ? nil : .linear(duration: 1),
                               value: viewModel.timerState.progress)

                VStack(spacing: 6) {
                    Text(viewModel.timerState.displayTime)
                        .font(.system(size: countdownFontSize, weight: .semibold, design: .monospaced))
                        .foregroundStyle(HushPalette.textPrimary)
                        .contentTransition(reduceMotion ? .identity : .numericText())

                    Text(viewModel.timerState.isFadingOut ? "Fading out now" : "Timer running")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(HushPalette.textSecondary)
                }
            }
            .frame(width: sizeClass == .regular ? 280 : 220,
                   height: sizeClass == .regular ? 280 : 220)
            .padding(.top, 4)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Timer")
            .accessibilityValue("\(viewModel.timerState.displayTime) remaining")

            if viewModel.timerState.playChimeOnEnd {
                HushInfoPill(icon: "bell.fill", text: "Chime at end")
            }

            Button {
                viewModel.stopTimer()
            } label: {
                Text("Cancel Timer")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(HushPalette.danger)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(
                        Capsule()
                            .strokeBorder(HushPalette.danger.opacity(0.42), lineWidth: 1)
                    )
            }
            .buttonStyle(HushPressButtonStyle())
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
    }

    private var durationPicker: some View {
        VStack(alignment: .leading, spacing: 28) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Sleep timer")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(HushPalette.textPrimary)

                Text("Fades the last 10 seconds.")
                    .font(.subheadline)
                    .foregroundStyle(HushPalette.textSecondary)
            }

            VStack(alignment: .leading, spacing: 12) {
                Text("Preset length")
                    .font(.caption.weight(.semibold))
                    .textCase(.uppercase)
                    .foregroundStyle(HushPalette.textSecondary)

                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(TimerDuration.allCases) { duration in
                        Button {
                            viewModel.startTimer(duration: duration.seconds)
                        } label: {
                            Text(duration.label)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(HushPalette.textPrimary)
                                .frame(maxWidth: .infinity, minHeight: 44)
                                .padding(.vertical, 12)
                                .background(
                                    RoundedRectangle(cornerRadius: HushRadius.md, style: .continuous)
                                        .fill(HushPalette.surfaceRaised)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: HushRadius.md, style: .continuous)
                                                .strokeBorder(HushPalette.outline, lineWidth: 1)
                                        )
                                )
                        }
                        .buttonStyle(HushPressButtonStyle())
                    }
                }
            }

            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Custom")
                        .font(.caption.weight(.semibold))
                        .textCase(.uppercase)
                        .foregroundStyle(HushPalette.textSecondary)

                    Spacer()

                    Text("\(customMinutes) min")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(HushPalette.textPrimary)
                        .monospacedDigit()
                }

                Slider(value: Binding(
                    get: { Double(customMinutes) },
                    set: { customMinutes = Int($0) }
                ), in: 1...180, step: 1)
                .tint(HushPalette.accentSoft)
                // Subtle click at every 5-minute detent — enough to feel
                // tactile without being noisy.
                .sensoryFeedback(.selection, trigger: customMinutes / 5)

                Button {
                    viewModel.startTimer(duration: TimeInterval(customMinutes) * 60)
                } label: {
                    Text("Start \(customMinutes)-minute timer")
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(HushPalette.onAccent)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(HushPalette.accent, in: Capsule())
                }
                .buttonStyle(HushPrimaryButtonStyle())
            }

            Toggle("Chime when done", isOn: Bindable(viewModel.timerState).playChimeOnEnd)
                .font(.subheadline)
                .foregroundStyle(HushPalette.textPrimary)
                .tint(HushPalette.accentSoft)
                .onChange(of: viewModel.timerState.playChimeOnEnd) { _, _ in
                    viewModel.persistTimerPreferences()
                }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
