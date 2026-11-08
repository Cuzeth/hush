import SwiftUI

/// How the player screen arranges itself for the space it's given.
///
/// iPhone Duo's inner display is regular width, and its fold runs down the
/// middle of the screen. One centered column there puts the sliders, scene
/// buttons and Play bar right across the fold, and Apple asks that
/// interactive controls stay off it (scrolling content may cross it). So with
/// room for two panes, the player and the scene list sit side by side, split
/// exactly at the fold. iPad gets the same two panes, split down the middle.
/// `nonisolated`: resolved inside `onGeometryChange`'s `@Sendable` transform,
/// off the main actor this target defaults to.
nonisolated enum PlayerPaneLayout: Equatable {
    /// One scrolling column: iPhone, iPhone Duo closed, too little room for
    /// two panes, or a fold running across the screen (the inner display held
    /// upright), where side-by-side panes would each straddle it.
    case singleColumn
    /// Player and scenes side by side. `leading` and `trailing` are pane
    /// widths; `gutter` is the gap between them, at least the fold's width.
    case split(leading: CGFloat, gutter: CGFloat, trailing: CGFloat)

    /// Below this a pane can't fit a level row (icon, name, slider, remove)
    /// at standard text sizes.
    static let minimumPaneWidth: CGFloat = 320
    /// Breathing room between panes when there's no fold, or a flat
    /// (zero-width) one.
    static let minimumGutter: CGFloat = 24

    /// - Parameters:
    ///   - isRegularWidth: the horizontal size class is regular.
    ///   - containerWidth: width available to the panes.
    ///   - folds: frames of the display's fold (`.division` reserved
    ///     regions), in the same coordinate space as `containerWidth`.
    static func resolve(isRegularWidth: Bool, containerWidth: CGFloat, folds: [CGRect]) -> PlayerPaneLayout {
        guard isRegularWidth else { return .singleColumn }

        // A flat fold reports zero thickness, so orientation comes from the
        // longer side. A degenerate 0×0 frame says nothing; skip it.
        let upright = folds.filter { $0.height > $0.width }
        let across = folds.filter { $0.width > $0.height }
        if upright.isEmpty, !across.isEmpty { return .singleColumn }

        let splitX: CGFloat
        let foldWidth: CGFloat
        if let fold = upright.first {
            splitX = fold.midX
            foldWidth = fold.width
        } else {
            splitX = containerWidth / 2
            foldWidth = 0
        }

        let gutter = max(foldWidth, minimumGutter)
        let leading = splitX - gutter / 2
        let trailing = containerWidth - splitX - gutter / 2
        guard leading >= minimumPaneWidth, trailing >= minimumPaneWidth else { return .singleColumn }
        return .split(leading: leading, gutter: gutter, trailing: trailing)
    }

    /// Where the display folds, in `proxy`'s local space. Includes a flat
    /// fold (inactive, zero width) so the split doesn't jump as the device
    /// starts to fold. Empty before iOS 27.1 and on displays without one.
    static func foldFrames(in proxy: GeometryProxy) -> [CGRect] {
        // `reservedRegions` only exists in the iOS 27.1+ SDK (Xcode 27,
        // Swift 6.4). CI's runner tops out at Xcode 26.x, so gate at compile
        // time too — `#available` alone doesn't stop the symbol lookup.
        #if compiler(>=6.4)
        if #available(iOS 27.1, *) {
            return proxy.reservedRegions(kind: .division, options: .includeInactive).map(\.frame)
        }
        #endif
        return []
    }
}

/// What the player measures to choose a `PlayerPaneLayout`.
nonisolated struct PlayerPaneGeometry: Equatable, Sendable {
    var width: CGFloat = 0
    var folds: [CGRect] = []
}
