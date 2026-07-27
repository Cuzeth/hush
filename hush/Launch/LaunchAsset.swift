import Foundation
import UIKit

/// Which colorway of the launch animation to play. Deliberately separate from
/// `ColorScheme`/`UIUserInterfaceStyle` so selection stays a pure value
/// mapping that tests can drive without a window or trait collection.
enum LaunchAppearance: String, CaseIterable, Sendable {
    case light
    case dark

    /// The animation's `Background Field` fill, which is also the app's
    /// `HushPalette.background` and the `LaunchBackground` color asset. All
    /// three must agree or the handoff shows a seam — `LaunchAssetTests`
    /// asserts it.
    var backgroundColor: UIColor {
        switch self {
        case .light: return UIColor(red: 250 / 255, green: 249 / 255, blue: 246 / 255, alpha: 1)
        case .dark: return UIColor(red: 9 / 255, green: 9 / 255, blue: 11 / 255, alpha: 1)
        }
    }
}

/// Whether to play the full animation or the motion-reduced one.
enum LaunchMotion: String, CaseIterable, Sendable {
    case full
    case reduced
}

/// Resolves which bundled Lottie file backs a given appearance + motion pair.
///
/// All four animations share one composition (1179x2556 @ 60fps, 108 frames)
/// and one frame 0 — a flat background plus the resting hairline — which is
/// exactly what `LaunchScreen.storyboard` renders statically. That shared
/// frame 0 is what lets the static launch screen and the overlay be the same
/// picture regardless of which asset gets selected.
enum LaunchAsset {
    /// Folder the animations live in under the app bundle. Xcode's
    /// synchronized-folder groups usually flatten resources into the bundle
    /// root, so lookups try the root as well.
    static let subdirectory = "Animations"

    static func name(appearance: LaunchAppearance, motion: LaunchMotion) -> String {
        switch motion {
        case .full:
            return "launch-\(appearance.rawValue)"
        case .reduced:
            return "launch-reduced-motion-\(appearance.rawValue)"
        }
    }

    /// Every animation that must ship in the app bundle.
    static var allNames: [String] {
        LaunchMotion.allCases.flatMap { motion in
            LaunchAppearance.allCases.map { name(appearance: $0, motion: motion) }
        }
    }

    /// Maps the user's in-app appearance preference onto a colorway.
    ///
    /// The preference wins over the system style because the app forces it via
    /// `overrideUserInterfaceStyle`, and the requirement that the final frame
    /// match the first screen's background is about where the animation *ends*.
    static func appearance(preference: Appearance, systemIsDark: Bool) -> LaunchAppearance {
        switch preference {
        case .light: return .light
        case .dark: return .dark
        case .system: return systemIsDark ? .dark : .light
        }
    }

    /// Bundle URL for an animation, tolerating either bundle layout.
    static func url(named name: String, in bundle: Bundle = .main) -> URL? {
        bundle.url(forResource: name, withExtension: "json", subdirectory: subdirectory)
            ?? bundle.url(forResource: name, withExtension: "json")
    }
}
