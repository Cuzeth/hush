import Lottie
import SwiftUI
import UIKit
import os.log

private let launchLogger = Logger(subsystem: "dev.abdeen.hush", category: "Launch")

/// Single owner of launch-overlay state for the lifetime of the process.
///
/// Everything about the launch sequence funnels through here — which animation
/// plays, whether it has finished, whether the first screen is ready, and when
/// the overlay comes down — so no view holds a timer or a private copy of the
/// state. Created once in `HushApp.init()`, which is what guarantees the
/// animation plays once per fresh process and never replays on background
/// return, tab switches, sheet dismissal, or navigation back to the root.
@Observable
@MainActor
final class LaunchCoordinator {

    enum Phase: Equatable {
        /// Overlay is on screen: animating, or held on its final frame while
        /// we wait for the first screen.
        case presenting
        /// Overlay has been removed. Terminal — nothing moves it back.
        case finished
    }

    private(set) var phase: Phase = .presenting
    private(set) var hasAnimationFinished = false
    private(set) var isFirstScreenReady = false

    /// Reduce Motion is sampled once, at process launch, so a mid-flight
    /// settings change can't swap the asset while it is playing.
    let motion: LaunchMotion

    /// Memoized so the colorway is decided once. `RootView` supplies the
    /// inputs on first render, when the environment is trustworthy.
    ///
    /// Observation-ignored on purpose: these are resolve-once caches filled
    /// during `body` evaluation, and publishing them would trip SwiftUI's
    /// "modifying state during view update" loop.
    @ObservationIgnored private(set) var appearance: LaunchAppearance?
    @ObservationIgnored private var loadedAnimation: LottieAnimation?

    var isOverlayPresented: Bool { phase == .presenting }

    init(motion: LaunchMotion? = nil) {
        self.motion = motion ?? (UIAccessibility.isReduceMotionEnabled ? .reduced : .full)
    }

    // MARK: - Asset resolution

    /// Decides the colorway on first call and sticks to it. The app applies its
    /// appearance override in `ContentView.onAppear`, which flips
    /// `\.colorScheme` underneath us — memoizing keeps that from swapping the
    /// asset mid-playback.
    @discardableResult
    func resolveAppearance(preference: Appearance, systemIsDark: Bool) -> LaunchAppearance {
        if let appearance { return appearance }
        let resolved = LaunchAsset.appearance(preference: preference, systemIsDark: systemIsDark)
        appearance = resolved
        return resolved
    }

    /// Resolves — once — the colorway and the animation to play.
    ///
    /// Returns `nil` if the animation can't be loaded; the caller then finishes
    /// immediately rather than stranding the user behind an opaque overlay.
    func animation(preference: Appearance, systemIsDark: Bool) -> LottieAnimation? {
        if let loadedAnimation { return loadedAnimation }

        let resolved = resolveAppearance(preference: preference, systemIsDark: systemIsDark)
        let name = LaunchAsset.name(appearance: resolved, motion: motion)
        let animation = LottieAnimation.named(name, subdirectory: LaunchAsset.subdirectory)
            ?? LottieAnimation.named(name)

        if animation == nil {
            launchLogger.error("Launch animation '\(name, privacy: .public)' missing from bundle")
        }
        loadedAnimation = animation
        return animation
    }

    /// Background behind the overlay and fallback fill. Safe before the
    /// colorway is resolved: falls back to the system style.
    func backgroundColor(preference: Appearance, systemIsDark: Bool) -> UIColor {
        resolveAppearance(preference: preference, systemIsDark: systemIsDark).backgroundColor
    }

    // MARK: - Handoff

    /// Driven by Lottie's playback completion callback, never by a timer.
    func animationDidFinish() {
        guard phase == .presenting, !hasAnimationFinished else { return }
        hasAnimationFinished = true
        dismissIfReady()
    }

    /// Reported by the app's real first screen once it has mounted. Idempotent:
    /// `ContentView.onAppear` re-fires when the root Group swaps between
    /// onboarding and the player, and on scene resume.
    func markFirstScreenReady() {
        guard phase == .presenting, !isFirstScreenReady else { return }
        isFirstScreenReady = true
        dismissIfReady()
    }

    /// The overlay comes down only when the animation has played out *and* the
    /// first screen is ready — in either order. The removal is wrapped in a
    /// disabled transaction so SwiftUI cuts rather than cross-dissolves; the
    /// final frame and the first screen share a background color, so the cut
    /// is invisible.
    private func dismissIfReady() {
        guard phase == .presenting, hasAnimationFinished, isFirstScreenReady else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            phase = .finished
        }
    }
}
