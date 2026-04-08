import AVFoundation

// Paul Kellet's IIR filter — accurate to +-0.05 dB above 9.2 Hz at 44.1 kHz.
// Seven parallel first-order IIR lowpass filters with tuned coefficients,
// summed to approximate -3 dB/octave slope.
final class PinkNoiseGenerator: SoundGenerator, @unchecked Sendable {
    nonisolated(unsafe) var volume: Float = 1.0

    // Filter state variables (one per pole)
    private var b0: Float = 0
    private var b1: Float = 0
    private var b2: Float = 0
    private var b3: Float = 0
    private var b4: Float = 0
    private var b5: Float = 0
    private var b6: Float = 0

    nonisolated func generateSamples(into buffer: UnsafeMutablePointer<Float>, frameCount: Int, stereo: Bool) {
        let vol = volume
        for i in 0..<frameCount {
            let white = Float.random(in: -1.0...1.0)

            // Paul Kellet's exact coefficients for 44.1 kHz
            b0 = 0.99886 * b0 + white * 0.0555179
            b1 = 0.99332 * b1 + white * 0.0750759
            b2 = 0.96900 * b2 + white * 0.1538520
            b3 = 0.86650 * b3 + white * 0.3104856
            b4 = 0.55000 * b4 + white * 0.5329522
            b5 = -0.7616 * b5 - white * 0.0168980
            let pink = b0 + b1 + b2 + b3 + b4 + b5 + b6 + white * 0.5362
            b6 = white * 0.115926

            // Gain compensation: 0.11 normalizes to roughly [-1, 1]
            let sample = pink * 0.11 * vol

            if stereo {
                buffer[i * 2] = sample
                buffer[i * 2 + 1] = sample
            } else {
                buffer[i] = sample
            }
        }
    }

    nonisolated func reset() {
        b0 = 0; b1 = 0; b2 = 0; b3 = 0; b4 = 0; b5 = 0; b6 = 0
    }
}
