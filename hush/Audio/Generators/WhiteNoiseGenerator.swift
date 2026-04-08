import AVFoundation

final class WhiteNoiseGenerator: SoundGenerator, @unchecked Sendable {
    nonisolated(unsafe) var volume: Float = 1.0

    nonisolated func generateSamples(into buffer: UnsafeMutablePointer<Float>, frameCount: Int, stereo: Bool) {
        let vol = volume
        if stereo {
            // Stereo: interleaved L R L R ...
            for i in 0..<frameCount {
                let sample = Float.random(in: -1.0...1.0) * vol
                buffer[i * 2] = sample
                buffer[i * 2 + 1] = sample
            }
        } else {
            for i in 0..<frameCount {
                buffer[i] = Float.random(in: -1.0...1.0) * vol
            }
        }
    }
}
