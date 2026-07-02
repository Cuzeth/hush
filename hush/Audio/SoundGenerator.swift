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

/// Per-buffer linear gain ramp shared by all generators. The atomic volume
/// is the *target*; each render call ramps the applied gain across the
/// buffer from wherever the previous buffer ended. Kills zipper noise on
/// slider drags and lets removal fade to silence (engine sets volume to 0
/// before detaching) instead of truncating the waveform with a click.
///
/// Value type mutated only on the audio thread — no locks, no allocation.
/// All members are nonisolated (same pattern as AudioRNG): used exclusively
/// inside @unchecked Sendable generator classes on the render thread.
struct VolumeRamp: @unchecked Sendable {
    /// Gain at the end of the previous buffer. Negative sentinel = first
    /// buffer, which snaps to the target (a phase-0 start is already
    /// click-free; ramping the first buffer would only skew tests and
    /// short renders).
    nonisolated(unsafe) private var current: Float = -1

    nonisolated init() {}

    /// Returns the starting gain and per-sample increment for this buffer.
    /// Callers multiply each sample by the running gain and add the step.
    nonisolated mutating func step(toward target: Float, frameCount: Int) -> (gain: Float, step: Float) {
        if current < 0 { current = target }
        let start = current
        let step = (target - start) / Float(max(frameCount, 1))
        current = target
        return (start, step)
    }
}
