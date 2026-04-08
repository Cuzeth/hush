// DC blocking filter: y[n] = x[n] - x[n-1] + 0.995 * y[n-1]
// Single-pole highpass at ~10 Hz for 44.1 kHz sample rate.
//
// All state is nonisolated(unsafe) — only accessed from the audio render thread.
final class DCBlockingFilter: @unchecked Sendable {
    nonisolated(unsafe) private var x1: Float = 0
    nonisolated(unsafe) private var y1: Float = 0
    private let coefficient: Float

    nonisolated init(coefficient: Float = 0.995) {
        self.coefficient = coefficient
    }

    nonisolated func process(_ input: Float) -> Float {
        let output = input - x1 + coefficient * y1
        x1 = input
        y1 = output
        return output
    }

    nonisolated func reset() {
        x1 = 0
        y1 = 0
    }
}
