import AVFoundation

protocol SoundGenerator: AnyObject, Sendable {
    nonisolated func generateSamples(into buffer: UnsafeMutablePointer<Float>, frameCount: Int, stereo: Bool)
    nonisolated var volume: Float { get set }
}
