import Lottie
import SwiftUI
import UIKit

/// Plays the launch animation exactly once, edge to edge, and reports back
/// through Lottie's own completion callback.
///
/// `isActive` is the scene phase folded in as a value: when the app returns to
/// the foreground SwiftUI re-runs `updateUIView`, which nudges playback to
/// resume from wherever it paused. Nothing here restarts the animation.
struct LaunchAnimationView: UIViewRepresentable {
    let animation: LottieAnimation
    let backgroundColor: UIColor
    let isActive: Bool
    let onFinished: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// Remembers the previous scene phase so we can tell a real
    /// background-to-foreground return from an ordinary SwiftUI re-render.
    final class Coordinator {
        var wasActive = true
    }

    func makeUIView(context: Context) -> LaunchAnimationHostView {
        let host = LaunchAnimationHostView(
            animation: animation,
            backgroundColor: backgroundColor
        )
        host.onFinished = onFinished
        return host
    }

    func updateUIView(_ host: LaunchAnimationHostView, context: Context) {
        host.onFinished = onFinished

        let returnedToForeground = isActive && !context.coordinator.wasActive
        context.coordinator.wasActive = isActive

        // Only on an actual foreground return. Nudging on every update raced
        // playback startup: the view isn't in a window yet, isAnimationPlaying
        // is still false, and the frame counter already reads the target frame
        // — which looked like "finished" and tore the overlay down instantly.
        guard returnedToForeground else { return }
        host.resumeIfInterrupted()
    }
}

/// Hosts the `LottieAnimationView` and owns its playback lifecycle.
///
/// A plain container rather than returning the Lottie view directly, so the
/// opaque background sits behind the animation from the very first layout pass
/// and playback can't be double-started by a SwiftUI re-render.
final class LaunchAnimationHostView: UIView {

    private let animationView: LottieAnimationView
    private var hasStarted = false
    private var hasFinished = false

    var onFinished: (() -> Void)?

    init(animation: LottieAnimation, backgroundColor: UIColor) {
        // No text layers, so `.automatic` resolves to the Core Animation
        // engine and playback stays off the main thread during launch.
        animationView = LottieAnimationView(
            animation: animation,
            configuration: LottieConfiguration(renderingEngine: .automatic)
        )
        super.init(frame: .zero)

        // Opaque from the first frame: no transparent or loading frame can
        // show through between the static launch screen and the animation.
        self.backgroundColor = backgroundColor
        isUserInteractionEnabled = false
        clipsToBounds = true

        animationView.contentMode = .scaleAspectFill
        animationView.loopMode = .playOnce
        // Pauses on resign-active and restores progress on return, so an
        // interrupted launch picks up instead of replaying.
        animationView.backgroundBehavior = .pauseAndRestore
        animationView.backgroundColor = backgroundColor
        // Sit on frame 0 before play() so the first rendered frame is
        // identical to the static launch screen.
        animationView.currentProgress = 0
        animationView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(animationView)

        NSLayoutConstraint.activate([
            animationView.topAnchor.constraint(equalTo: topAnchor),
            animationView.bottomAnchor.constraint(equalTo: bottomAnchor),
            animationView.leadingAnchor.constraint(equalTo: leadingAnchor),
            animationView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Start once the view is actually on screen, so the first frame anyone
    /// sees is frame 0 rather than a few milliseconds in.
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { startIfNeeded() }
    }

    func startIfNeeded() {
        guard !hasStarted else { return }
        hasStarted = true
        play(from: animationView.animation?.startFrame ?? 0)
    }

    /// Safety net for a launch interrupted by backgrounding. Only reached on a
    /// genuine foreground return, and only acts when playback has actually
    /// stalled part-way — it never restarts a finished or running animation.
    ///
    /// Deliberately never calls `finish()` on its own: Lottie's completion
    /// callback stays the single source of truth for "playback ended". A
    /// zero-length replay at the tail still routes through that callback.
    func resumeIfInterrupted() {
        guard hasStarted, !hasFinished, window != nil, !animationView.isAnimationPlaying else {
            return
        }
        guard let animation = animationView.animation else {
            finish()
            return
        }
        // realtimeAnimationFrame, not currentFrame: correct under both the
        // Core Animation and main-thread rendering engines.
        play(from: min(animationView.realtimeAnimationFrame, animation.endFrame))
    }

    private func play(from frame: AnimationFrameTime) {
        guard let animation = animationView.animation else {
            finish()
            return
        }
        animationView.play(
            fromFrame: frame,
            toFrame: animation.endFrame,
            loopMode: .playOnce
        ) { [weak self] completed in
            // `completed == false` means playback was interrupted (typically
            // backgrounding). Leave it paused — resumeIfInterrupted() picks it
            // up on the next active scene phase rather than starting over.
            guard completed else { return }
            self?.finish()
        }
    }

    private func finish() {
        guard !hasFinished else { return }
        hasFinished = true
        // Hold the last frame. The overlay stays up until the first screen is
        // ready, and nothing underneath may show through in the meantime.
        animationView.currentProgress = 1
        onFinished?()
    }
}
