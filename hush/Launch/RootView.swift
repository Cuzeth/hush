import SwiftUI

/// Window root: the app's real first screen with the launch overlay stacked on
/// top of it.
///
/// `ContentView` is mounted unconditionally and never transitions in, so by the
/// time the overlay is removed the first screen is already laid out behind it
/// at its final position.
struct RootView: View {
    let storageFailureMessage: String?

    @Environment(LaunchCoordinator.self) private var launch
    @Environment(\.colorScheme) private var systemColorScheme
    @AppStorage("appearance") private var appearanceRaw: String = Appearance.system.rawValue

    private var appearancePreference: Appearance {
        Appearance(rawValue: appearanceRaw) ?? .system
    }

    var body: some View {
        // `.overlay` rather than a ZStack sibling: an overlay is sized to the
        // base view and can never feed back into its geometry, so removing it
        // cannot nudge the first screen. ContentView is mounted unconditionally
        // either way, so it never transitions in.
        ContentView(storageFailureMessage: storageFailureMessage)
            .overlay {
                if launch.isOverlayPresented {
                    LaunchOverlay(
                        preference: appearancePreference,
                        systemIsDark: systemColorScheme == .dark
                    )
                }
            }
    }
}

/// Full-bleed cover that carries the launch animation.
///
/// Holds its own opaque background so no system background, white flash, or
/// transparent frame can appear between the static launch screen and the first
/// animation frame.
private struct LaunchOverlay: View {
    @Environment(LaunchCoordinator.self) private var launch
    @Environment(\.scenePhase) private var scenePhase

    let preference: Appearance
    let systemIsDark: Bool

    var body: some View {
        let background = launch.backgroundColor(preference: preference, systemIsDark: systemIsDark)

        Group {
            if let animation = launch.animation(preference: preference, systemIsDark: systemIsDark) {
                LaunchAnimationView(
                    animation: animation,
                    backgroundColor: background,
                    isActive: scenePhase == .active,
                    onFinished: { launch.animationDidFinish() }
                )
            } else {
                // Animation missing from the bundle: show the flat background
                // the animation would have ended on and hand off as soon as
                // the first screen is ready, rather than stranding the user
                // behind an opaque overlay forever.
                Color(uiColor: background)
                    .onAppear { launch.animationDidFinish() }
            }
        }
        .ignoresSafeArea()
        .transaction { $0.animation = nil }
    }
}
