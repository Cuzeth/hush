import AVFoundation

// Brown (Brownian) noise via leaky integrator with DC blocking filter.
// Leaky integrator: output = (lastOutput + 0.02 * white) / 1.02
// Prevents DC drift while maintaining -6 dB/octave slope.
final class BrownNoiseGenerator: SoundGenerator, @unchecked Sendable {
    nonisolated(unsafe) var volume: Float = 1.0

    private var lastOutput: Float = 0
    private let dcBlocker = DCBlockingFilter()

    nonisolated func generateSamples(into buffer: UnsafeMutablePointer<Float>, frameCount: Int, stereo: Bool) {
        let vol = volume
        for i in 0..<frameCount {
            let white = Float.random(in: -1.0...1.0)

            // Leaky integrator (exact coefficients from research doc)
            lastOutput = (lastOutput + 0.02 * white) / 1.02

            // DC blocking filter to remove any residual DC offset
            let filtered = dcBlocker.process(lastOutput)

            // Gain compensation: 3.5 brings level up to usable range
            let sample = filtered * 3.5 * vol

            if stereo {
                buffer[i * 2] = sample
                buffer[i * 2 + 1] = sample
            } else {
                buffer[i] = sample
            }
        }
    }

    nonisolated func reset() {
        lastOutput = 0
        dcBlocker.reset()
    }
}
