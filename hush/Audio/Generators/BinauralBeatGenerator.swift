import AVFoundation
import Synchronization

// Binaural beats: two sine oscillators at slightly different frequencies,
// one per stereo channel. Headphones required — no channel crosstalk allowed.
// Carrier: 200-400 Hz. Difference frequency determines brainwave target.
//
// Overrides generateStereo to produce different content per channel.
// generateMono outputs the carrier only (binaural effect requires stereo).
final class BinauralBeatGenerator: SoundGenerator, @unchecked Sendable {
    private let _volume = Atomic<UInt32>(0x3F80_0000)
    private let _carrierFrequency = Atomic<UInt32>(0x4348_0000) // 200.0f
    private let _beatFrequency = Atomic<UInt32>(0x4150_0000)    // 13.0f

    nonisolated var volume: Float {
        get { Float(bitPattern: _volume.load(ordering: .relaxed)) }
        set { _volume.store(newValue.bitPattern, ordering: .relaxed) }
    }

    nonisolated var carrierFrequency: Float {
        get { Float(bitPattern: _carrierFrequency.load(ordering: .relaxed)) }
        set { _carrierFrequency.store(newValue.bitPattern, ordering: .relaxed) }
    }

    nonisolated var beatFrequency: Float {
        get { Float(bitPattern: _beatFrequency.load(ordering: .relaxed)) }
        set { _beatFrequency.store(newValue.bitPattern, ordering: .relaxed) }
    }

    nonisolated(unsafe) private var phaseLeft: Double = 0
    nonisolated(unsafe) private var phaseRight: Double = 0
    private let sampleRate: Double

    nonisolated init(sampleRate: Double = 44100) {
        self.sampleRate = sampleRate
    }

    nonisolated func setRange(_ range: BinauralRange) {
        beatFrequency = range.defaultFrequency
    }

    // Mono fallback: carrier tone only (no binaural effect)
    nonisolated func generateMono(into buffer: UnsafeMutablePointer<Float>, frameCount: Int) {
        let vol = Float(bitPattern: _volume.load(ordering: .relaxed))
        let carrier = Double(Float(bitPattern: _carrierFrequency.load(ordering: .relaxed)))
        let twoPi = 2.0 * Double.pi
        let inc = twoPi * carrier / sampleRate

        for i in 0..<frameCount {
            buffer[i] = Float(sin(phaseLeft)) * vol
            phaseLeft += inc
            if phaseLeft >= twoPi { phaseLeft -= twoPi }
        }
    }

    // True binaural: different frequency per ear
    nonisolated func generateStereo(left: UnsafeMutablePointer<Float>,
                                     right: UnsafeMutablePointer<Float>,
                                     frameCount: Int) {
        let vol = Float(bitPattern: _volume.load(ordering: .relaxed))
        let carrier = Double(Float(bitPattern: _carrierFrequency.load(ordering: .relaxed)))
        let beat = Double(Float(bitPattern: _beatFrequency.load(ordering: .relaxed)))
        let twoPi = 2.0 * Double.pi

        let incL = twoPi * carrier / sampleRate
        let incR = twoPi * (carrier + beat) / sampleRate

        for i in 0..<frameCount {
            left[i] = Float(sin(phaseLeft)) * vol
            right[i] = Float(sin(phaseRight)) * vol

            phaseLeft += incL
            phaseRight += incR
            if phaseLeft >= twoPi { phaseLeft -= twoPi }
            if phaseRight >= twoPi { phaseRight -= twoPi }
        }
    }
}
