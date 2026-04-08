import AVFoundation
import Synchronization

final class WhiteNoiseGenerator: SoundGenerator, @unchecked Sendable {
    private let _volume = Atomic<UInt32>(0x3F80_0000) // 1.0f

    nonisolated var volume: Float {
        get { Float(bitPattern: _volume.load(ordering: .relaxed)) }
        set { _volume.store(newValue.bitPattern, ordering: .relaxed) }
    }

    nonisolated(unsafe) private var rng: AudioRNG

    nonisolated init(sampleRate: Double = 44100) {
        self.rng = AudioRNG()
    }

    nonisolated func generateMono(into buffer: UnsafeMutablePointer<Float>, frameCount: Int) {
        let vol = Float(bitPattern: _volume.load(ordering: .relaxed))
        for i in 0..<frameCount {
            buffer[i] = rng.nextFloat() * vol
        }
    }
}
