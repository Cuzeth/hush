import AVFoundation
import Synchronization

// Isochronic tones: a carrier sine wave amplitude-modulated by a sine envelope
// at the target brainwave frequency. The modulation is physically present in the
// sound (~50 dB depth), so no headphones are required — works through speakers.
//
// Output is mono (identical both channels). Uses the same BinauralRange targets.
final class IsochronicToneGenerator: SoundGenerator, @unchecked Sendable {
    private let _volume = Atomic<UInt32>(0x3F80_0000)          // 1.0f
    private let _carrierFrequency = Atomic<UInt32>(0x4348_0000) // 200.0f
    private let _pulseRate = Atomic<UInt32>(0x4150_0000)        // 13.0f

    nonisolated var volume: Float {
        get { Float(bitPattern: _volume.load(ordering: .relaxed)) }
        set { _volume.store(newValue.bitPattern, ordering: .relaxed) }
    }

    nonisolated var carrierFrequency: Float {
        get { Float(bitPattern: _carrierFrequency.load(ordering: .relaxed)) }
        set { _carrierFrequency.store(newValue.bitPattern, ordering: .relaxed) }
    }

    nonisolated var pulseRate: Float {
        get { Float(bitPattern: _pulseRate.load(ordering: .relaxed)) }
        set { _pulseRate.store(newValue.bitPattern, ordering: .relaxed) }
    }

    nonisolated(unsafe) private var carrierPhase: Double = 0
    nonisolated(unsafe) private var pulsePhase: Double = 0
    private let sampleRate: Double

    nonisolated init(sampleRate: Double = 44100) {
        self.sampleRate = sampleRate
    }

    nonisolated func setRange(_ range: BinauralRange) {
        pulseRate = range.defaultFrequency
    }

    nonisolated func generateMono(into buffer: UnsafeMutablePointer<Float>, frameCount: Int) {
        let vol = Float(bitPattern: _volume.load(ordering: .relaxed))
        let carrier = Double(Float(bitPattern: _carrierFrequency.load(ordering: .relaxed)))
        let pulse = Double(Float(bitPattern: _pulseRate.load(ordering: .relaxed)))
        let twoPi = 2.0 * Double.pi

        let carrierInc = twoPi * carrier / sampleRate
        let pulseInc = twoPi * pulse / sampleRate

        for i in 0..<frameCount {
            // Sine envelope: 0.5 * (1 + cos(pulsePhase)) ranges from 0 to 1
            let envelope = Float(0.5 * (1.0 + cos(pulsePhase)))
            buffer[i] = Float(sin(carrierPhase)) * envelope * vol

            carrierPhase += carrierInc
            pulsePhase += pulseInc
            if carrierPhase >= twoPi { carrierPhase -= twoPi }
            if pulsePhase >= twoPi { pulsePhase -= twoPi }
        }
    }
}
