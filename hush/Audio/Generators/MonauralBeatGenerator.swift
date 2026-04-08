import AVFoundation
import Synchronization

// Monaural beats: two sine waves at slightly different frequencies mixed together
// before reaching the ear. Physical superposition creates amplitude modulation at
// the difference frequency via constructive/destructive interference.
//
// No headphones required — works through speakers. Produces stronger cortical
// auditory steady-state responses (ASSR) than binaural beats.
//
// Output is mono (identical both channels).
final class MonauralBeatGenerator: SoundGenerator, @unchecked Sendable {
    private let _volume = Atomic<UInt32>(0x3F80_0000)          // 1.0f
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

    nonisolated(unsafe) private var phase1: Double = 0
    nonisolated(unsafe) private var phase2: Double = 0
    private let sampleRate: Double

    nonisolated init(sampleRate: Double = 44100) {
        self.sampleRate = sampleRate
    }

    nonisolated func setRange(_ range: BinauralRange) {
        beatFrequency = range.defaultFrequency
    }

    nonisolated func generateMono(into buffer: UnsafeMutablePointer<Float>, frameCount: Int) {
        let vol = Float(bitPattern: _volume.load(ordering: .relaxed))
        let carrier = Double(Float(bitPattern: _carrierFrequency.load(ordering: .relaxed)))
        let beat = Double(Float(bitPattern: _beatFrequency.load(ordering: .relaxed)))
        let twoPi = 2.0 * Double.pi

        // Two tones centered on carrier, separated by beat frequency
        let freq1 = carrier - beat / 2.0
        let freq2 = carrier + beat / 2.0
        let inc1 = twoPi * freq1 / sampleRate
        let inc2 = twoPi * freq2 / sampleRate

        for i in 0..<frameCount {
            // Sum two sines, scale by 0.5 to keep peak amplitude at 1.0
            buffer[i] = Float(sin(phase1) + sin(phase2)) * 0.5 * vol

            phase1 += inc1
            phase2 += inc2
            if phase1 >= twoPi { phase1 -= twoPi }
            if phase2 >= twoPi { phase2 -= twoPi }
        }
    }
}
