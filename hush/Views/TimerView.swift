import SwiftUI

struct TimerView: View {
    @Bindable var viewModel: PlayerViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var customMinutes: Int = 25

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                if viewModel.timerState.isRunning {
                    runningTimerView
                } else {
                    durationPicker
                }
            }
            .padding()
            .navigationTitle("Timer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var runningTimerView: some View {
        VStack(spacing: 20) {
            // Circular progress
            ZStack {
                Circle()
                    .stroke(Color(.systemGray4), lineWidth: 6)
                Circle()
                    .trim(from: 0, to: viewModel.timerState.progress)
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(-90))

                Text(viewModel.timerState.displayTime)
                    .font(.system(.largeTitle, design: .monospaced, weight: .medium))
                    .contentTransition(.numericText())
            }
            .frame(width: 180, height: 180)

            if viewModel.timerState.isFadingOut {
                Text("Fading out...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button("Cancel Timer") {
                viewModel.stopTimer()
            }
            .buttonStyle(.bordered)
            .tint(.red)
        }
    }

    private var durationPicker: some View {
        VStack(spacing: 20) {
            Text("Auto-stop after")
                .font(.headline)

            // Quick presets
            LazyVGrid(columns: [
                GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())
            ], spacing: 12) {
                ForEach(TimerDuration.allCases) { duration in
                    Button {
                        viewModel.startTimer(duration: duration.seconds)
                    } label: {
                        Text(duration.label)
                            .font(.subheadline.weight(.medium))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(
                                duration.rawValue == 25
                                    ? Color.accentColor.opacity(0.3)
                                    : Color(.systemGray5)
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                }
            }

            // Custom duration
            Divider()

            HStack {
                Text("Custom")
                    .foregroundStyle(.secondary)
                Spacer()
                Stepper(value: $customMinutes, in: 1...180, step: 5) {
                    Text("\(customMinutes) min")
                        .font(.subheadline.weight(.medium))
                }
            }

            Button("Start Custom Timer") {
                viewModel.startTimer(duration: TimeInterval(customMinutes) * 60)
            }
            .buttonStyle(.borderedProminent)

            Divider()

            Toggle("Play chime when done", isOn: Bindable(viewModel.timerState).playChimeOnEnd)
                .font(.subheadline)

            Text("Sound fades out over the final 10 seconds")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }
}
