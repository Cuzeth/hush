import AVFoundation

protocol SoundGenerator: AnyObject, Sendable {
    /// Fill a mono buffer. For noise generators this is the primary path.
    nonisolated func generateMono(into buffer: UnsafeMutablePointer<Float>, frameCount: Int)

    /// Fill separate left/right channel buffers (non-interleaved stereo).
    /// Default implementation calls generateMono and copies to both channels.
    nonisolated func generateStereo(left: UnsafeMutablePointer<Float>,
                                     right: UnsafeMutablePointer<Float>,
                                     frameCount: Int)

    nonisolated var volume: Float { get set }
}

extension SoundGenerator {
    // Default: mono duplicated to both channels
    nonisolated func generateStereo(left: UnsafeMutablePointer<Float>,
                                     right: UnsafeMutablePointer<Float>,
                                     frameCount: Int) {
        generateMono(into: left, frameCount: frameCount)
        right.update(from: left, count: frameCount)
    }
}
