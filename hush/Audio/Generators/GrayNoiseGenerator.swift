@preconcurrency import AVFoundation
import Synchronization

// Gray noise: white noise shaped by an inverted ISO 226 equal-loudness contour
// so it sounds perceptually flat at all frequencies.
//
// Implementation: a bank of biquad filters approximating the inverted ~60 phon
// equal-loudness curve. Coefficients are computed from the actual hardware sample rate.
final class GrayNoiseGenerator: SoundGenerator, @unchecked Sendable {
    private let _volume = Atomic<UInt32>(0x3F80_0000)

    nonisolated var volume: Float {
        get { Float(bitPattern: _volume.load(ordering: .relaxed)) }
        set { _volume.store(newValue.bitPattern, ordering: .relaxed) }
    }

    nonisolated(unsafe) private var filters: (BiquadState, BiquadState, BiquadState, BiquadState)
    nonisolated(unsafe) private var rng: AudioRNG

    // NOTE: Biquad coefficients are sample-rate-dependent. A new instance must
    // be created whenever the hardware sample rate changes. This is guaranteed
    // by rebuildAudioGraph() which always creates fresh generators.
    nonisolated init(sampleRate: Double = 44100) {
        let sr = Float(sampleRate)
        filters = (
            BiquadState(coefficients: Self.lowShelf(freq: 100, gainDB: 12, sampleRate: sr)),
            BiquadState(coefficients: Self.peakingEQ(freq: 3500, gainDB: -8, q: 1.0, sampleRate: sr)),
            BiquadState(coefficients: Self.peakingEQ(freq: 8000, gainDB: 4, q: 0.8, sampleRate: sr)),
            BiquadState(coefficients: Self.highShelf(freq: 12000, gainDB: 6, sampleRate: sr))
        )
        self.rng = AudioRNG()
    }

    nonisolated func generateMono(into buffer: UnsafeMutablePointer<Float>, frameCount: Int) {
        let vol = Float(bitPattern: _volume.load(ordering: .relaxed))
        for i in 0..<frameCount {
            var sample = rng.nextFloat()
            sample = filters.0.process(sample)
            sample = filters.1.process(sample)
            sample = filters.2.process(sample)
            sample = filters.3.process(sample)
            buffer[i] = sample * 0.15 * vol
        }
    }

    // MARK: - Biquad types (nonisolated — pure value-type DSP, audio thread only)

    private struct BiquadCoefficients: Sendable {
        var b0: Float, b1: Float, b2: Float, a1: Float, a2: Float
    }

    private struct BiquadState: @unchecked Sendable {
        var coefficients: BiquadCoefficients
        nonisolated(unsafe) var x1: Float = 0
        nonisolated(unsafe) var x2: Float = 0
        nonisolated(unsafe) var y1: Float = 0
        nonisolated(unsafe) var y2: Float = 0

        nonisolated mutating func process(_ input: Float) -> Float {
            let c = coefficients
            let output = c.b0 * input + c.b1 * x1 + c.b2 * x2 - c.a1 * y1 - c.a2 * y2
            x2 = x1; x1 = input
            y2 = y1; y1 = output
            return output
        }
    }

    // MARK: - Biquad coefficient calculations (Audio EQ Cookbook by Robert Bristow-Johnson)

    nonisolated private static func lowShelf(freq: Float, gainDB: Float, sampleRate: Float) -> BiquadCoefficients {
        let A = powf(10.0, gainDB / 40.0)
        let w0 = 2.0 * Float.pi * freq / sampleRate
        let cosW0 = cosf(w0); let sinW0 = sinf(w0)
        let alpha = sinW0 / 2.0 * sqrtf(2.0)
        let sqrtA2alpha = 2.0 * sqrtf(A) * alpha
        let a0 = (A + 1) + (A - 1) * cosW0 + sqrtA2alpha
        return BiquadCoefficients(
            b0: (A * ((A + 1) - (A - 1) * cosW0 + sqrtA2alpha)) / a0,
            b1: (2.0 * A * ((A - 1) - (A + 1) * cosW0)) / a0,
            b2: (A * ((A + 1) - (A - 1) * cosW0 - sqrtA2alpha)) / a0,
            a1: (-2.0 * ((A - 1) + (A + 1) * cosW0)) / a0,
            a2: ((A + 1) + (A - 1) * cosW0 - sqrtA2alpha) / a0)
    }

    nonisolated private static func highShelf(freq: Float, gainDB: Float, sampleRate: Float) -> BiquadCoefficients {
        let A = powf(10.0, gainDB / 40.0)
        let w0 = 2.0 * Float.pi * freq / sampleRate
        let cosW0 = cosf(w0); let sinW0 = sinf(w0)
        let alpha = sinW0 / 2.0 * sqrtf(2.0)
        let sqrtA2alpha = 2.0 * sqrtf(A) * alpha
        let a0 = (A + 1) - (A - 1) * cosW0 + sqrtA2alpha
        return BiquadCoefficients(
            b0: (A * ((A + 1) + (A - 1) * cosW0 + sqrtA2alpha)) / a0,
            b1: (-2.0 * A * ((A - 1) + (A + 1) * cosW0)) / a0,
            b2: (A * ((A + 1) + (A - 1) * cosW0 - sqrtA2alpha)) / a0,
            a1: (2.0 * ((A - 1) - (A + 1) * cosW0)) / a0,
            a2: ((A + 1) - (A - 1) * cosW0 - sqrtA2alpha) / a0)
    }

    nonisolated private static func peakingEQ(freq: Float, gainDB: Float, q: Float, sampleRate: Float) -> BiquadCoefficients {
        let A = powf(10.0, gainDB / 40.0)
        let w0 = 2.0 * Float.pi * freq / sampleRate
        let cosW0 = cosf(w0); let sinW0 = sinf(w0)
        let alpha = sinW0 / (2.0 * q)
        let a0 = 1.0 + alpha / A
        return BiquadCoefficients(
            b0: (1.0 + alpha * A) / a0,
            b1: (-2.0 * cosW0) / a0,
            b2: (1.0 - alpha * A) / a0,
            a1: (-2.0 * cosW0) / a0,
            a2: (1.0 - alpha / A) / a0)
    }
}
