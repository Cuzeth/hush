import AVFoundation
import Synchronization

// Paul Kellet's IIR filter — accurate to +-0.05 dB above 9.2 Hz at 44.1 kHz.
// Seven parallel first-order IIR lowpass filters with tuned coefficients,
// summed to approximate -3 dB/octave slope.
//
// NOTE: These coefficients are designed for 44.1 kHz. At 48 kHz the error is
// negligible (<0.5 dB). For significantly different sample rates, Cooper Baker's
// generalized algorithm should be used instead.
final class PinkNoiseGenerator: SoundGenerator, @unchecked Sendable {
    private let _volume = Atomic<UInt32>(0x3F80_0000)

    nonisolated var volume: Float {
        get { Float(bitPattern: _volume.load(ordering: .relaxed)) }
        set { _volume.store(newValue.bitPattern, ordering: .relaxed) }
    }

    nonisolated(unsafe) private var b0: Float = 0
    nonisolated(unsafe) private var b1: Float = 0
    nonisolated(unsafe) private var b2: Float = 0
    nonisolated(unsafe) private var b3: Float = 0
    nonisolated(unsafe) private var b4: Float = 0
    nonisolated(unsafe) private var b5: Float = 0
    nonisolated(unsafe) private var b6: Float = 0
    nonisolated(unsafe) private var rng: AudioRNG

    nonisolated init(sampleRate: Double = 44100) {
        self.rng = AudioRNG()
    }

    nonisolated func generateMono(into buffer: UnsafeMutablePointer<Float>, frameCount: Int) {
        let vol = Float(bitPattern: _volume.load(ordering: .relaxed))
        for i in 0..<frameCount {
            let white = rng.nextFloat()

            b0 = 0.99886 * b0 + white * 0.0555179
            b1 = 0.99332 * b1 + white * 0.0750759
            b2 = 0.96900 * b2 + white * 0.1538520
            b3 = 0.86650 * b3 + white * 0.3104856
            b4 = 0.55000 * b4 + white * 0.5329522
            b5 = -0.7616 * b5 - white * 0.0168980
            let pink = b0 + b1 + b2 + b3 + b4 + b5 + b6 + white * 0.5362
            b6 = white * 0.115926

            buffer[i] = pink * 0.11 * vol
        }
    }
}
