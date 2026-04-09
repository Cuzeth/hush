// DC blocking filter: y[n] = x[n] - x[n-1] + R * y[n-1]
// Single-pole highpass. R is computed from the sample rate and cutoff frequency
// so the ~10 Hz cutoff is correct at any hardware sample rate.
//
// All state is nonisolated(unsafe) — only accessed from the audio render thread.
final class DCBlockingFilter: @unchecked Sendable {
    nonisolated(unsafe) private var x1: Float = 0
    nonisolated(unsafe) private var y1: Float = 0
    private let coefficient: Float

    nonisolated init(sampleRate: Double = 44100, cutoffHz: Double = 10.0) {
        self.coefficient = Float(1.0 - (2.0 * Double.pi * cutoffHz / sampleRate))
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
