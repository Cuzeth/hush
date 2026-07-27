import Foundation
import SwiftUI
import Testing
import UIKit
@testable import hush

// MARK: - Helpers

/// Loads a shipped launch animation straight out of the app bundle. Doubles as
/// the automated check that the JSON actually made it into Copy Bundle
/// Resources — if it didn't, every test using this fails.
private func launchAnimationJSON(_ name: String) throws -> [String: Any] {
    let url = try #require(
        LaunchAsset.url(named: name),
        "\(name).json must ship in the app bundle"
    )
    let data = try Data(contentsOf: url)
    let object = try JSONSerialization.jsonObject(with: data)
    return try #require(object as? [String: Any])
}

private func allLayers(_ animation: [String: Any]) throws -> [[String: Any]] {
    try #require(animation["layers"] as? [[String: Any]])
}

private func findLayer(named name: String, in animation: [String: Any]) throws -> [String: Any] {
    let match = try allLayers(animation).first { $0["nm"] as? String == name }
    return try #require(match, "layer '\(name)' must exist")
}

private enum FrameEdge { case first, last }

/// Layer opacity at the very start or very end of the composition.
///
/// Every layer's first opacity keyframe is at or after frame 0 and its last is
/// at or before frame 108, and Lottie holds the boundary values outside the
/// keyframe range — so reading the edge keyframes is exact here, no
/// interpolation required.
private func opacity(of layer: [String: Any], at edge: FrameEdge) -> Double? {
    guard let ks = layer["ks"] as? [String: Any],
          let o = ks["o"] as? [String: Any] else { return nil }

    if (o["a"] as? Int) == 0 {
        if let value = o["k"] as? Double { return value }
        return (o["k"] as? [Double])?.first
    }
    guard let keyframes = o["k"] as? [[String: Any]] else { return nil }
    let keyframe = edge == .first ? keyframes.first : keyframes.last
    return (keyframe?["s"] as? [Double])?.first
}

/// Names of properties on a layer that animate position, scale, rotation or
/// shape size — i.e. anything that reads as movement rather than a fade.
private func motionAnimatedProperties(of layer: [String: Any]) -> [String] {
    var found: [String] = []
    if let ks = layer["ks"] as? [String: Any] {
        for key in ["p", "s", "a", "r"] where (ks[key] as? [String: Any])?["a"] as? Int == 1 {
            found.append(key)
        }
    }
    for group in (layer["shapes"] as? [[String: Any]]) ?? [] {
        for item in (group["it"] as? [[String: Any]]) ?? [] where item["ty"] as? String == "rc" {
            if (item["s"] as? [String: Any])?["a"] as? Int == 1 { found.append("rect.size") }
        }
    }
    return found
}

private func fillColor(of layer: [String: Any]) -> [Double]? {
    for group in (layer["shapes"] as? [[String: Any]]) ?? [] {
        for item in (group["it"] as? [[String: Any]]) ?? [] where item["ty"] as? String == "fl" {
            if let color = item["c"] as? [String: Any], let k = color["k"] as? [Double] { return k }
        }
    }
    return nil
}

private func rgba(_ color: UIColor) -> (r: Double, g: Double, b: Double, a: Double) {
    var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
    color.getRed(&r, green: &g, blue: &b, alpha: &a)
    return (Double(r), Double(g), Double(b), Double(a))
}

/// Summed absolute channel difference, in 0...255 units.
private func channelDistance(_ lhs: UIColor, _ rhs: UIColor) -> Double {
    let a = rgba(lhs), b = rgba(rhs)
    return (abs(a.r - b.r) + abs(a.g - b.g) + abs(a.b - b.b)) * 255
}

private func expectSameColor(
    _ lhs: UIColor,
    _ rhs: UIColor,
    tolerance: Double = 1.0,
    _ what: Comment,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    #expect(channelDistance(lhs, rhs) <= tolerance, what, sourceLocation: sourceLocation)
}

private func traits(dark: Bool) -> UITraitCollection {
    UITraitCollection(userInterfaceStyle: dark ? .dark : .light)
}

private let fullMotionAssets = [
    LaunchAsset.name(appearance: .light, motion: .full),
    LaunchAsset.name(appearance: .dark, motion: .full),
]

private let reducedMotionAssets = [
    LaunchAsset.name(appearance: .light, motion: .reduced),
    LaunchAsset.name(appearance: .dark, motion: .reduced),
]

// MARK: - Asset Selection

struct LaunchAssetSelectionTests {

    @Test func fullMotionNamesMatchTheShippedFiles() {
        #expect(LaunchAsset.name(appearance: .light, motion: .full) == "launch-light")
        #expect(LaunchAsset.name(appearance: .dark, motion: .full) == "launch-dark")
    }

    @Test func reducedMotionNamesMatchTheShippedFiles() {
        #expect(LaunchAsset.name(appearance: .light, motion: .reduced)
                == "launch-reduced-motion-light")
        #expect(LaunchAsset.name(appearance: .dark, motion: .reduced)
                == "launch-reduced-motion-dark")
    }

    @Test func everyAppearanceMotionPairMapsToADistinctAsset() {
        let names = LaunchAsset.allNames
        #expect(names.count == 4)
        #expect(Set(names).count == 4)
    }

    /// An explicit in-app appearance beats the system style, because the app
    /// forces it with `overrideUserInterfaceStyle` — the animation has to end
    /// on the background the first screen will actually use.
    @Test(arguments: [true, false])
    func explicitPreferenceOverridesSystemStyle(systemIsDark: Bool) {
        #expect(LaunchAsset.appearance(preference: .light, systemIsDark: systemIsDark) == .light)
        #expect(LaunchAsset.appearance(preference: .dark, systemIsDark: systemIsDark) == .dark)
    }

    @Test func systemPreferenceFollowsTheSystemStyle() {
        #expect(LaunchAsset.appearance(preference: .system, systemIsDark: true) == .dark)
        #expect(LaunchAsset.appearance(preference: .system, systemIsDark: false) == .light)
    }
}

// MARK: - Bundled Animations

struct LaunchAnimationAssetTests {

    /// Copy Bundle Resources check: all four animations resolve at runtime.
    @Test func everyLaunchAnimationShipsInTheAppBundle() {
        for name in LaunchAsset.allNames {
            #expect(LaunchAsset.url(named: name) != nil, "\(name).json is missing from the bundle")
        }
    }

    @Test(arguments: LaunchAsset.allNames)
    func compositionsShareOneCanvasAndDuration(name: String) throws {
        let animation = try launchAnimationJSON(name)
        #expect(animation["w"] as? Int == 1179)
        #expect(animation["h"] as? Int == 2556)
        #expect(animation["fr"] as? Int == 60)
        #expect(animation["ip"] as? Int == 0)
        #expect(animation["op"] as? Int == 108, "1.8s at 60fps — native duration is preserved")
    }

    /// The wordmark was removed deliberately — the waveform mark carries the
    /// identity on its own. Dropping the only text layer also lets Lottie pick
    /// the Core Animation engine instead of falling back to main-thread
    /// rendering, which matters during launch.
    @Test(arguments: LaunchAsset.allNames)
    func animationsContainNoTextLayers(name: String) throws {
        let animation = try launchAnimationJSON(name)
        for entry in try allLayers(animation) {
            let layerName = try #require(entry["nm"] as? String)
            #expect(entry["ty"] as? Int != 5, "\(layerName) is a text layer")
        }
        #expect(animation.keys.contains("fonts") == false, "no text layers, so no font list")
    }

    /// Frame 0 has to equal `LaunchScreen.storyboard`: the flat background plus
    /// the resting hairline, and nothing else. If a bar or the wordmark ever
    /// became visible at frame 0, the static-to-animated cut would flash.
    @Test(arguments: LaunchAsset.allNames)
    func frameZeroIsBackgroundPlusHairlineOnly(name: String) throws {
        let animation = try launchAnimationJSON(name)
        for entry in try allLayers(animation) {
            let layerName = try #require(entry["nm"] as? String)
            let value = try #require(opacity(of: entry, at: .first))
            switch layerName {
            case "Background Field":
                #expect(value == 100)
            case "Resting Hairline":
                #expect(value > 0, "the hairline is the only mark on the static launch screen")
            default:
                #expect(value == 0, "\(layerName) must be invisible at frame 0")
            }
        }
    }

    /// The last frame is a bare field of the app's background color, so the
    /// overlay can be cut away with nothing to give the seam away.
    @Test(arguments: LaunchAsset.allNames)
    func finalFrameIsBareBackground(name: String) throws {
        let animation = try launchAnimationJSON(name)
        for entry in try allLayers(animation) {
            let layerName = try #require(entry["nm"] as? String)
            let value = try #require(opacity(of: entry, at: .last))
            if layerName == "Background Field" {
                #expect(value == 100)
            } else {
                #expect(value == 0, "\(layerName) must be gone by the final frame")
            }
        }
    }

    /// Reduce Motion gets fades only — no growth, no rise, no retract.
    @Test(arguments: reducedMotionAssets)
    func reducedMotionAnimationsOnlyAnimateOpacity(name: String) throws {
        let animation = try launchAnimationJSON(name)
        for entry in try allLayers(animation) {
            let layerName = try #require(entry["nm"] as? String)
            let moving = motionAnimatedProperties(of: entry)
            #expect(moving.isEmpty, "\(layerName) still animates \(moving.joined(separator: ", "))")
        }
    }

    /// The counterpart: the full-motion animations really do move, so the
    /// check above is testing something real.
    @Test(arguments: fullMotionAssets)
    func fullMotionAnimationsDoMove(name: String) throws {
        let animation = try launchAnimationJSON(name)
        let moving = try allLayers(animation).flatMap { motionAnimatedProperties(of: $0) }
        #expect(!moving.isEmpty)
    }

    /// Reduced motion is the same piece with its motion frozen out — same
    /// layers, same timing, same duration, same fades.
    @Test(arguments: [LaunchAppearance.light, .dark])
    func reducedMotionMirrorsTheFullAnimationsStructure(appearance: LaunchAppearance) throws {
        let full = try launchAnimationJSON(LaunchAsset.name(appearance: appearance, motion: .full))
        let reduced = try launchAnimationJSON(
            LaunchAsset.name(appearance: appearance, motion: .reduced)
        )

        let fullNames = try allLayers(full).compactMap { $0["nm"] as? String }
        let reducedNames = try allLayers(reduced).compactMap { $0["nm"] as? String }
        #expect(fullNames == reducedNames)

        for key in ["w", "h", "fr", "ip", "op"] {
            #expect(full[key] as? Int == reduced[key] as? Int, "\(key) must match")
        }

        for name in fullNames {
            let a = opacity(of: try findLayer(named: name, in: full), at: .first)
            let b = opacity(of: try findLayer(named: name, in: reduced), at: .first)
            #expect(a == b, "\(name) frame-0 opacity must match")
        }
    }
}

// MARK: - Background Parity (the seam guarantee)

@MainActor
struct LaunchBackgroundParityTests {

    /// Four things have to be the same color or the handoff shows a seam: the
    /// animation's background layer, the overlay fill, the app's own
    /// background, and the static launch screen's color asset.
    @Test(arguments: [LaunchAppearance.light, .dark])
    func animationOverlayAppAndLaunchScreenShareOneBackground(
        appearance: LaunchAppearance
    ) throws {
        let isDark = appearance == .dark
        let overlay = appearance.backgroundColor

        let animation = try launchAnimationJSON(
            LaunchAsset.name(appearance: appearance, motion: .full)
        )
        let field = try #require(
            fillColor(of: try findLayer(named: "Background Field", in: animation))
        )
        expectSameColor(
            overlay,
            UIColor(red: field[0], green: field[1], blue: field[2], alpha: field[3]),
            "overlay fill vs. the animation's Background Field"
        )

        // Resolve the app palette under the target style both ways, since the
        // Color -> UIColor bridge doesn't always carry the dynamic provider.
        var palette = UIColor.clear
        traits(dark: isDark).performAsCurrent {
            palette = UIColor(HushPalette.background)
        }
        expectSameColor(
            overlay,
            palette.resolvedColor(with: traits(dark: isDark)),
            "overlay fill vs. HushPalette.background"
        )

        let launchAsset = try #require(
            UIColor(named: "LaunchBackground"),
            "LaunchBackground color asset must ship for LaunchScreen.storyboard"
        )
        expectSameColor(
            overlay,
            launchAsset.resolvedColor(with: traits(dark: isDark)),
            "overlay fill vs. the LaunchBackground color asset"
        )
    }
}

// MARK: - Static Launch Screen Artwork

@MainActor
struct LaunchArtworkTests {

    /// Samples the shipped artwork at the animation's own hairline coordinates.
    /// The storyboard and the Lottie view both aspect-fill the same 1179x2556
    /// canvas, so matching pixels here means matching pixels on device.
    @Test(arguments: [LaunchAppearance.light, .dark])
    func artworkDrawsTheHairlineWhereFrameZeroPutsIt(appearance: LaunchAppearance) throws {
        let isDark = appearance == .dark
        let image = try #require(
            UIImage(named: "LaunchArtwork", in: .main, compatibleWith: traits(dark: isDark)),
            "LaunchArtwork must ship for LaunchScreen.storyboard"
        )
        let cg = try #require(image.cgImage)

        // Same canvas as every launch animation, so aspect-fill lands the
        // hairline in the same place in both stages.
        #expect(cg.width == 1179)
        #expect(cg.height == 2556)

        let field = try #require(pixel(cg, x: 40, y: 300))
        let aboveLine = try #require(pixel(cg, x: 589, y: 1120))
        let onLine = try #require(pixel(cg, x: 589, y: 1140))

        // The hairline layer sits at y = 1140 and is 6px tall, so y = 1120 is
        // still bare field. Loose tolerance: actool may re-encode the PNG.
        expectSameColor(aboveLine, field, tolerance: 6, "20px above the hairline is bare field")
        expectSameColor(
            field, appearance.backgroundColor, tolerance: 6,
            "artwork field vs. the launch background — light/dark must not be swapped"
        )

        // A low-opacity sage line over the field: subtle, but unmistakably there.
        #expect(
            channelDistance(onLine, appearance.backgroundColor) > 20,
            "the hairline must be visible against the background"
        )
    }

    private func pixel(_ image: CGImage, x: Int, y: Int) -> UIColor? {
        var data = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(
            data: &data, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        // CGContext is bottom-left origin: place image pixel (x, y) at (0, 0).
        context.translateBy(x: CGFloat(-x), y: CGFloat(y - image.height + 1))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return UIColor(
            red: CGFloat(data[0]) / 255, green: CGFloat(data[1]) / 255,
            blue: CGFloat(data[2]) / 255, alpha: 1
        )
    }
}

// MARK: - Handoff

@MainActor
struct LaunchCoordinatorTests {

    @Test func overlayIsPresentedBeforeAnythingHappens() {
        let coordinator = LaunchCoordinator(motion: .full)
        #expect(coordinator.isOverlayPresented)
        #expect(coordinator.phase == .presenting)
        #expect(coordinator.hasAnimationFinished == false)
        #expect(coordinator.isFirstScreenReady == false)
    }

    @Test func animationFinishingAloneKeepsTheOverlayUp() {
        let coordinator = LaunchCoordinator(motion: .full)
        coordinator.animationDidFinish()

        #expect(coordinator.hasAnimationFinished)
        #expect(coordinator.isOverlayPresented, "the overlay holds its last frame")
    }

    @Test func firstScreenReadyAloneKeepsTheOverlayUp() {
        let coordinator = LaunchCoordinator(motion: .full)
        coordinator.markFirstScreenReady()

        #expect(coordinator.isFirstScreenReady)
        #expect(coordinator.isOverlayPresented, "the animation still has to play out")
    }

    /// Delayed first-screen readiness: the animation finishes first and the
    /// overlay waits on its final frame.
    @Test func overlayIsRemovedWhenReadinessArrivesAfterPlayback() {
        let coordinator = LaunchCoordinator(motion: .full)
        coordinator.animationDidFinish()
        #expect(coordinator.isOverlayPresented)

        coordinator.markFirstScreenReady()
        #expect(coordinator.phase == .finished)
        #expect(coordinator.isOverlayPresented == false)
    }

    /// Immediate first-screen readiness: the screen is up long before the
    /// animation ends, and the overlay still runs to completion first.
    @Test func overlayIsRemovedWhenPlaybackFinishesAfterReadiness() {
        let coordinator = LaunchCoordinator(motion: .full)
        coordinator.markFirstScreenReady()
        #expect(coordinator.isOverlayPresented)

        coordinator.animationDidFinish()
        #expect(coordinator.phase == .finished)
        #expect(coordinator.isOverlayPresented == false)
    }

    /// `ContentView.onAppear` re-fires on scene resume and when the root Group
    /// swaps between onboarding and the player.
    @Test func repeatedSignalsAreIdempotent() {
        let coordinator = LaunchCoordinator(motion: .full)
        coordinator.markFirstScreenReady()
        coordinator.markFirstScreenReady()
        coordinator.animationDidFinish()
        coordinator.animationDidFinish()
        coordinator.markFirstScreenReady()

        #expect(coordinator.phase == .finished)
    }

    /// Nothing brings the overlay back — no background return, no tab switch,
    /// no navigation to the root.
    @Test func finishedIsTerminal() {
        let coordinator = LaunchCoordinator(motion: .full)
        coordinator.animationDidFinish()
        coordinator.markFirstScreenReady()
        #expect(coordinator.phase == .finished)

        coordinator.animationDidFinish()
        coordinator.markFirstScreenReady()

        #expect(coordinator.phase == .finished)
        #expect(coordinator.isOverlayPresented == false)
    }

    @Test func reduceMotionIsSampledOnceAtInit() {
        #expect(LaunchCoordinator(motion: .reduced).motion == .reduced)
        #expect(LaunchCoordinator(motion: .full).motion == .full)
    }

    /// The app flips `\.colorScheme` from `ContentView.onAppear` via
    /// `overrideUserInterfaceStyle`. The colorway must not follow it mid-launch.
    @Test func colorwayIsResolvedOnceAndThenStable() {
        let coordinator = LaunchCoordinator(motion: .full)
        #expect(coordinator.appearance == nil)

        #expect(coordinator.resolveAppearance(preference: .system, systemIsDark: true) == .dark)
        #expect(coordinator.appearance == .dark)

        // Same coordinator, opposite inputs — the first answer stands.
        #expect(coordinator.resolveAppearance(preference: .light, systemIsDark: false) == .dark)
        expectSameColor(
            coordinator.backgroundColor(preference: .light, systemIsDark: false),
            LaunchAppearance.dark.backgroundColor,
            "background follows the memoized colorway"
        )
    }
}
