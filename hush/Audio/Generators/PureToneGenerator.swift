import AVFoundation
import Synchronization

// Pure tone: a clean sine wave at a user-selected frequency with subtle harmonics
// for warmth. No pulsing, no beating — just a steady, continuous hum.
//
// Harmonics are fixed at -18 dB (2nd) and -24 dB (3rd) relative to fundamental
// for a slightly warm timbre without being harsh.
final class PureToneGenerator: SoundGenerator, @unchecked Sendable {
    private let _volume = Atomic<UInt32>(0x3F80_0000)          // 1.0f
    private let _frequency = Atomic<UInt32>(0x43D8_0000)       // 432.0f

    nonisolated var volume: Float {
        get { Float(bitPattern: _volume.load(ordering: .relaxed)) }
        set { _volume.store(newValue.bitPattern, ordering: .relaxed) }
    }

    nonisolated var frequency: Float {
        get { Float(bitPattern: _frequency.load(ordering: .relaxed)) }
        set { _frequency.store(newValue.bitPattern, ordering: .relaxed) }
    }

    nonisolated(unsafe) private var phase1: Double = 0
    nonisolated(unsafe) private var phase2: Double = 0
    nonisolated(unsafe) private var phase3: Double = 0
    private let sampleRate: Double

    // Harmonic amplitudes relative to fundamental
    private let h2Gain: Float = 0.125  // -18 dB
    private let h3Gain: Float = 0.063  // -24 dB
    private let normalization: Float    // keeps peak ≤ 1.0

    nonisolated init(sampleRate: Double = 44100) {
        self.sampleRate = sampleRate
        self.normalization = 1.0 / (1.0 + 0.125 + 0.063)
    }

    nonisolated func generateMono(into buffer: UnsafeMutablePointer<Float>, frameCount: Int) {
        let vol = Float(bitPattern: _volume.load(ordering: .relaxed))
        let freq = Double(Float(bitPattern: _frequency.load(ordering: .relaxed)))
        let twoPi = 2.0 * Double.pi

        let inc1 = twoPi * freq / sampleRate
        let inc2 = twoPi * (freq * 2.0) / sampleRate
        let inc3 = twoPi * (freq * 3.0) / sampleRate

        for i in 0..<frameCount {
            let fundamental = Float(sin(phase1))
            let harmonic2 = Float(sin(phase2)) * h2Gain
            let harmonic3 = Float(sin(phase3)) * h3Gain

            buffer[i] = (fundamental + harmonic2 + harmonic3) * normalization * vol

            phase1 += inc1
            phase2 += inc2
            phase3 += inc3
            if phase1 >= twoPi { phase1 -= twoPi }
            if phase2 >= twoPi { phase2 -= twoPi }
            if phase3 >= twoPi { phase3 -= twoPi }
        }
    }
}
