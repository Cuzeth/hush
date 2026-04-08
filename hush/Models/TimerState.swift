import Foundation

@MainActor
@Observable
final class TimerState {
    var isRunning = false
    var selectedDuration: TimeInterval = TimerDuration.twentyFive.seconds
    var remainingSeconds: TimeInterval = 0
    var playChimeOnEnd = true
    var endDate: Date?

    func start(duration: TimeInterval, now: Date = .now) {
        selectedDuration = duration
        endDate = now.addingTimeInterval(duration)
        isRunning = true
        remainingSeconds = duration
    }

    @discardableResult
    func syncRemaining(now: Date = .now) -> Bool {
        guard let endDate else {
            isRunning = false
            remainingSeconds = 0
            return false
        }

        let remaining = max(0, endDate.timeIntervalSince(now))
        remainingSeconds = remaining

        if remaining <= 0 {
            clear()
            return true
        }

        isRunning = true
        return false
    }

    func clear() {
        isRunning = false
        remainingSeconds = 0
        endDate = nil
    }

    var progress: Double {
        guard selectedDuration > 0 else { return 0 }
        return 1.0 - (remainingSeconds / selectedDuration)
    }

    var displayTime: String {
        let minutes = Int(remainingSeconds) / 60
        let seconds = Int(remainingSeconds) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    var isFadingOut: Bool {
        isRunning && remainingSeconds <= AudioConstants.timerFadeOutDuration && remainingSeconds > 0
    }

    var fadeMultiplier: Float {
        guard isFadingOut else { return 1.0 }
        return Float(remainingSeconds / AudioConstants.timerFadeOutDuration)
    }
}
