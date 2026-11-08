import SwiftUI

/// The transport bar's timer control. Idle, it shows the last-used length
/// and a tap starts it; running, it shows the countdown and a tap opens the
/// timer sheet. A long press (VoiceOver: "Choose duration") opens the sheet
/// on the duration picker either way.
struct TimerChip: View {
    let viewModel: PlayerViewModel
    let minHeight: CGFloat
    /// Present the timer sheet; true lands on the duration picker even
    /// while a timer runs.
    let onOpenTimer: (_ choosingDuration: Bool) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Bumped when a tap starts a timer, for the start haptic. The sheet has
    /// its own; keying on `isRunning` here would double it up.
    @State private var startCount = 0

    private var timer: TimerState { viewModel.timerState }

    /// Compact chip text for an idle timer: "25m".
    static func shortLabel(for duration: TimeInterval) -> String {
        "\(max(1, Int((duration / 60).rounded())))m"
    }

    private var lastMinutes: Int {
        max(1, Int((viewModel.lastTimerDuration / 60).rounded()))
    }

    var body: some View {
        Button(action: tap) {
            HStack(spacing: 6) {
                Image(systemName: "timer")
                    .font(.subheadline.weight(.bold))
                Text(timer.isRunning ? timer.displayTime : Self.shortLabel(for: viewModel.lastTimerDuration))
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .contentTransition(reduceMotion ? .identity : .numericText(countsDown: true))
            }
            .foregroundStyle(HushPalette.textPrimary)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .frame(minHeight: minHeight)
            .background(
                // Running reads as "on" by more than color: the countdown
                // replaces the length, and the rim picks up the accent.
                Capsule()
                    .fill(timer.isRunning ? HushPalette.chipActive : HushPalette.raisedFill)
                    .overlay(
                        Capsule().strokeBorder(
                            timer.isRunning ? HushPalette.accentSoft : HushPalette.outline,
                            lineWidth: 1
                        )
                    )
            )
            .contentShape(Capsule())
        }
        .buttonStyle(TapOrLongPressButtonStyle(onLongPress: chooseDuration))
        .accessibilityLabel("Timer")
        .accessibilityValue(timer.isRunning
                            ? TimerSpeech.remaining(timer.remainingSeconds)
                            : TimerSpeech.duration(viewModel.lastTimerDuration))
        .accessibilityHint(timer.isRunning ? "Shows the timer" : "Starts a \(lastMinutes)-minute timer")
        // Fixed action slots with state-dependent names, so the element
        // keeps its identity (and VoiceOver focus) when the timer starts.
        .accessibilityAction(named: Text(timer.isRunning ? "Cancel timer" : "Start \(lastMinutes)-minute timer")) {
            if timer.isRunning {
                viewModel.stopTimer()
            } else {
                startLastDuration()
            }
        }
        .accessibilityAction(named: "Choose duration", chooseDuration)
        .sensoryFeedback(.start, trigger: startCount)
    }

    private func tap() {
        if timer.isRunning {
            onOpenTimer(false)
        } else {
            startLastDuration()
        }
    }

    private func startLastDuration() {
        // Same semantics as the sheet: a paused mix starts playing.
        viewModel.startTimer(duration: viewModel.lastTimerDuration)
        startCount += 1
    }

    private func chooseDuration() {
        onOpenTimer(true)
    }
}

/// Tap triggers the button; a long press runs `onLongPress` instead, never
/// both. A primitive style keeps it a real Button for accessibility (the
/// default action still triggers it) while owning the gestures.
private struct TapOrLongPressButtonStyle: PrimitiveButtonStyle {
    let onLongPress: () -> Void

    func makeBody(configuration: Configuration) -> some View {
        TapOrLongPressBody(configuration: configuration, onLongPress: onLongPress)
    }
}

private struct TapOrLongPressBody: View {
    let configuration: PrimitiveButtonStyleConfiguration
    let onLongPress: () -> Void
    @State private var isPressed = false
    /// Bumped when the long press lands, so the user feels it register.
    @State private var longPressCount = 0

    var body: some View {
        configuration.label
            .opacity(isPressed ? 0.7 : 1)
            .animation(HushMotion.quick, value: isPressed)
            .onTapGesture { configuration.trigger() }
            .onLongPressGesture(minimumDuration: 0.5) {
                longPressCount += 1
                onLongPress()
            } onPressingChanged: { pressing in
                isPressed = pressing
            }
            .sensoryFeedback(.impact(weight: .medium), trigger: longPressCount)
    }
}
