import AVFoundation

// Gray noise: white noise shaped by an inverted ISO 226 equal-loudness contour
// so it sounds perceptually flat at all frequencies.
//
// Implementation: a bank of biquad filters approximating the inverted ~60 phon
// equal-loudness curve. This boosts frequencies where the ear is less sensitive
// (low bass, very high treble) and attenuates the 2-5 kHz region where hearing
// is most acute.
final class GrayNoiseGenerator: SoundGenerator, @unchecked Sendable {
    nonisolated(unsafe) var volume: Float = 1.0

    // Biquad filter state
    private var filters: [BiquadState]

    nonisolated init() {
        let sr = Float(AudioConstants.sampleRate)
        // Approximate inverted ISO 226 at 60 phon with 4 biquad sections:
        // 1. Low shelf boost at 100 Hz, +12 dB (compensate for low-freq insensitivity)
        // 2. Peaking cut at 3500 Hz, -8 dB, Q=1.0 (ear's most sensitive region)
        // 3. Peaking boost at 8000 Hz, +4 dB, Q=0.8 (sensitivity dip)
        // 4. High shelf boost at 12000 Hz, +6 dB (compensate for high-freq rolloff)
        filters = [
            BiquadState(coefficients: Self.lowShelf(freq: 100, gainDB: 12, sampleRate: sr)),
            BiquadState(coefficients: Self.peakingEQ(freq: 3500, gainDB: -8, q: 1.0, sampleRate: sr)),
            BiquadState(coefficients: Self.peakingEQ(freq: 8000, gainDB: 4, q: 0.8, sampleRate: sr)),
            BiquadState(coefficients: Self.highShelf(freq: 12000, gainDB: 6, sampleRate: sr))
        ]
    }

    nonisolated func generateSamples(into buffer: UnsafeMutablePointer<Float>, frameCount: Int, stereo: Bool) {
        let vol = volume
        for i in 0..<frameCount {
            var sample = Float.random(in: -1.0...1.0)

            // Pass through each biquad filter in series
            for j in 0..<filters.count {
                sample = filters[j].process(sample)
            }

            // Normalize (the filter chain can amplify significantly)
            sample = sample * 0.15 * vol

            if stereo {
                buffer[i * 2] = sample
                buffer[i * 2 + 1] = sample
            } else {
                buffer[i] = sample
            }
        }
    }

    // MARK: - Biquad coefficient calculations (Audio EQ Cookbook by Robert Bristow-Johnson)

    private struct BiquadCoefficients {
        var b0: Float, b1: Float, b2: Float, a1: Float, a2: Float
    }

    private struct BiquadState {
        var coefficients: BiquadCoefficients
        var x1: Float = 0, x2: Float = 0
        var y1: Float = 0, y2: Float = 0

        mutating func process(_ input: Float) -> Float {
            let c = coefficients
            let output = c.b0 * input + c.b1 * x1 + c.b2 * x2 - c.a1 * y1 - c.a2 * y2
            x2 = x1; x1 = input
            y2 = y1; y1 = output
            return output
        }
    }

    private static func lowShelf(freq: Float, gainDB: Float, sampleRate: Float) -> BiquadCoefficients {
        let A = powf(10.0, gainDB / 40.0)
        let w0 = 2.0 * Float.pi * freq / sampleRate
        let cosW0 = cosf(w0)
        let sinW0 = sinf(w0)
        let alpha = sinW0 / 2.0 * sqrtf(2.0) // S = 1.0 (shelf slope)
        let sqrtA2alpha = 2.0 * sqrtf(A) * alpha

        let a0 = (A + 1) + (A - 1) * cosW0 + sqrtA2alpha
        return BiquadCoefficients(
            b0: (A * ((A + 1) - (A - 1) * cosW0 + sqrtA2alpha)) / a0,
            b1: (2.0 * A * ((A - 1) - (A + 1) * cosW0)) / a0,
            b2: (A * ((A + 1) - (A - 1) * cosW0 - sqrtA2alpha)) / a0,
            a1: (-2.0 * ((A - 1) + (A + 1) * cosW0)) / a0,
            a2: ((A + 1) + (A - 1) * cosW0 - sqrtA2alpha) / a0
        )
    }

    private static func highShelf(freq: Float, gainDB: Float, sampleRate: Float) -> BiquadCoefficients {
        let A = powf(10.0, gainDB / 40.0)
        let w0 = 2.0 * Float.pi * freq / sampleRate
        let cosW0 = cosf(w0)
        let sinW0 = sinf(w0)
        let alpha = sinW0 / 2.0 * sqrtf(2.0)
        let sqrtA2alpha = 2.0 * sqrtf(A) * alpha

        let a0 = (A + 1) - (A - 1) * cosW0 + sqrtA2alpha
        return BiquadCoefficients(
            b0: (A * ((A + 1) + (A - 1) * cosW0 + sqrtA2alpha)) / a0,
            b1: (-2.0 * A * ((A - 1) + (A + 1) * cosW0)) / a0,
            b2: (A * ((A + 1) + (A - 1) * cosW0 - sqrtA2alpha)) / a0,
            a1: (2.0 * ((A - 1) - (A + 1) * cosW0)) / a0,
            a2: ((A + 1) - (A - 1) * cosW0 - sqrtA2alpha) / a0
        )
    }

    private static func peakingEQ(freq: Float, gainDB: Float, q: Float, sampleRate: Float) -> BiquadCoefficients {
        let A = powf(10.0, gainDB / 40.0)
        let w0 = 2.0 * Float.pi * freq / sampleRate
        let cosW0 = cosf(w0)
        let sinW0 = sinf(w0)
        let alpha = sinW0 / (2.0 * q)

        let a0 = 1.0 + alpha / A
        return BiquadCoefficients(
            b0: (1.0 + alpha * A) / a0,
            b1: (-2.0 * cosW0) / a0,
            b2: (1.0 - alpha * A) / a0,
            a1: (-2.0 * cosW0) / a0,
            a2: (1.0 - alpha / A) / a0
        )
    }
}
