import SwiftUI

struct TimerView: View {
    @Bindable var viewModel: PlayerViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var sizeClass
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
                        headerCard

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
    }

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Let the room dim itself.")
                .font(.system(.title, design: .serif, weight: .semibold))
                .foregroundStyle(HushPalette.textPrimary)

            Text("Set a sleep timer, fade the mix gently over the last ten seconds, and let it keep counting even when Hush leaves the foreground.")
                .font(.subheadline)
                .foregroundStyle(HushPalette.textSecondary)
                .lineSpacing(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(22)
        .hushPanel(fill: HushPalette.surface.opacity(0.92))
    }

    private var runningTimerView: some View {
        VStack(spacing: 22) {
            ZStack {
                Circle()
                    .stroke(HushPalette.outlineStrong, lineWidth: 10)

                Circle()
                    .trim(from: 0, to: viewModel.timerState.progress)
                    .stroke(
                        AngularGradient(
                            colors: [HushPalette.accent, HushPalette.accentSoft, HushPalette.accent],
                            center: .center
                        ),
                        style: StrokeStyle(lineWidth: 10, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))

                VStack(spacing: 6) {
                    Text(viewModel.timerState.displayTime)
                        .font(.system(size: countdownFontSize, weight: .semibold, design: .monospaced))
                        .foregroundStyle(HushPalette.textPrimary)
                        .contentTransition(.numericText())

                    Text(viewModel.timerState.isFadingOut ? "Fading out now" : "Timer running")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(HushPalette.textSecondary)
                }
            }
            .frame(width: sizeClass == .regular ? 280 : 220,
                   height: sizeClass == .regular ? 280 : 220)
            .padding(.top, 4)

            HStack(spacing: 10) {
                HushInfoPill(icon: "timer", text: viewModel.timerState.displayTime, highlighted: true)
                HushInfoPill(icon: viewModel.timerState.playChimeOnEnd ? "bell.fill" : "bell.slash", text: viewModel.timerState.playChimeOnEnd ? "Chime" : "Silent")
            }

            Button {
                viewModel.stopTimer()
            } label: {
                Text("Cancel Timer")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(HushPalette.textPrimary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .fill(HushPalette.danger.opacity(0.16))
                            .overlay(
                                RoundedRectangle(cornerRadius: 22, style: .continuous)
                                    .strokeBorder(HushPalette.danger.opacity(0.42), lineWidth: 1)
                            )
                    )
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
        .padding(24)
        .hushPanel(fill: HushPalette.surface.opacity(0.92))
    }

    private var durationPicker: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Quick starts")
                    .font(.system(.title, design: .serif, weight: .semibold))
                    .foregroundStyle(HushPalette.textPrimary)

                Text("Choose a preset length or dial in your own.")
                    .font(.subheadline)
                    .foregroundStyle(HushPalette.textSecondary)
            }

            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(TimerDuration.allCases) { duration in
                    Button {
                        viewModel.startTimer(duration: duration.seconds)
                    } label: {
                        Text(duration.label)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(duration.rawValue == 25 ? Color.black : HushPalette.textPrimary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(
                                RoundedRectangle(cornerRadius: 20, style: .continuous)
                                    .fill(duration.rawValue == 25 ? HushPalette.accent : HushPalette.surfaceRaised.opacity(0.86))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                                            .strokeBorder(HushPalette.outline, lineWidth: 1)
                                    )
                            )
                    }
                    .buttonStyle(.plain)
                }
            }

            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Custom length")
                        .font(.headline)
                        .foregroundStyle(HushPalette.textPrimary)

                    Spacer()

                    Text("\(customMinutes) min")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(HushPalette.textSecondary)
                        .monospacedDigit()
                }

                Slider(value: Binding(
                    get: { Double(customMinutes) },
                    set: { customMinutes = Int($0) }
                ), in: 1...180, step: 1)
                .tint(HushPalette.accentSoft)

                Button {
                    viewModel.startTimer(duration: TimeInterval(customMinutes) * 60)
                } label: {
                    Text("Start Custom Timer")
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(Color.black)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(HushPalette.accent, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                }
                .buttonStyle(.plain)
            }
            .padding(20)
            .hushPanel(radius: 24, fill: HushPalette.surface.opacity(0.92))

            VStack(alignment: .leading, spacing: 12) {
                Toggle("Play chime when done", isOn: Bindable(viewModel.timerState).playChimeOnEnd)
                    .font(.subheadline)
                    .foregroundStyle(HushPalette.textPrimary)
                    .tint(HushPalette.accentSoft)
                    .onChange(of: viewModel.timerState.playChimeOnEnd) { _, _ in
                        viewModel.persistTimerPreferences()
                    }

                Text("Hush fades the master volume over the final 10 seconds and restores the timer state when you come back.")
                    .font(.caption)
                    .foregroundStyle(HushPalette.textSecondary)
                    .lineSpacing(2)
            }
            .padding(20)
            .hushPanel(radius: 24, fill: HushPalette.surface.opacity(0.92))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(22)
        .hushPanel(fill: HushPalette.surface.opacity(0.92))
    }
}
