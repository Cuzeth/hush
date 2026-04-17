import SwiftUI
import UIKit

/// Dynamic palette tokens. Each color resolves at render time against the
/// active UITraitCollection, so flipping `preferredColorScheme` (or the
/// system appearance) swaps both modes without any view-level branching.
///
/// Dark is the authored baseline — values track the pre-light-mode palette
/// so existing surfaces keep their character. Light is tuned for similar
/// contrast ratios (body text ~10:1, secondary ~6:1) on a warm near-white.
enum HushPalette {
    static let background = dynamic(
        dark: Color(red: 0.035, green: 0.036, blue: 0.044),
        light: Color(red: 0.980, green: 0.976, blue: 0.966)
    )
    static let backgroundLift = dynamic(
        dark: Color(red: 0.066, green: 0.070, blue: 0.086),
        light: Color(red: 0.958, green: 0.951, blue: 0.938)
    )
    static let surface = dynamic(
        dark: Color(red: 0.082, green: 0.086, blue: 0.104),
        light: Color(red: 0.948, green: 0.942, blue: 0.928)
    )
    static let surfaceRaised = dynamic(
        dark: Color(red: 0.118, green: 0.124, blue: 0.148),
        light: Color(red: 0.916, green: 0.908, blue: 0.892)
    )
    static let outline = dynamic(
        dark: Color.white.opacity(0.08),
        light: Color.black.opacity(0.08)
    )
    static let outlineStrong = dynamic(
        dark: Color.white.opacity(0.16),
        light: Color.black.opacity(0.16)
    )
    static let textPrimary = dynamic(
        dark: Color(red: 0.952, green: 0.948, blue: 0.928),
        light: Color(red: 0.110, green: 0.100, blue: 0.088)
    )
    static let textSecondary = dynamic(
        dark: Color(red: 0.694, green: 0.701, blue: 0.748),
        light: Color(red: 0.384, green: 0.376, blue: 0.348)
    )
    static let textMuted = dynamic(
        dark: Color.white.opacity(0.55),
        light: Color.black.opacity(0.45)
    )
    /// Warm cream in dark, warm tan in light. Stays luminous enough that
    /// black text sits on it at ≥5:1 in both modes.
    static let accent = dynamic(
        dark: Color(red: 0.936, green: 0.904, blue: 0.832),
        light: Color(red: 0.796, green: 0.710, blue: 0.560)
    )
    /// Muted sage. Used for secondary actions and active chips. The light
    /// variant deepens for visible weight on a near-white background.
    static let accentSoft = dynamic(
        dark: Color(red: 0.690, green: 0.760, blue: 0.734),
        light: Color(red: 0.310, green: 0.442, blue: 0.378)
    )
    static let danger = dynamic(
        dark: Color(red: 0.924, green: 0.446, blue: 0.415),
        light: Color(red: 0.792, green: 0.288, blue: 0.248)
    )

    /// Subtle rim applied on top of an accent-filled surface (the highlighted
    /// HushInfoPill border). White-on-cream in dark, near-black-on-tan in
    /// light — in both cases a quiet darken/lighten of the accent itself.
    static let accentEdge = dynamic(
        dark: Color.white.opacity(0.25),
        light: Color.black.opacity(0.18)
    )

    // Semantic fills — keep per-site opacity tweaks rare.
    static let panelFill = surface.opacity(0.94)       // Item cards, rows
    static let panelFillSoft = surface.opacity(0.92)   // Outer panels
    static let raisedFill = surfaceRaised.opacity(0.92) // Icon circles, strong chips
    static let chipMuted = surfaceRaised.opacity(0.6)  // Unselected chip
    static let chipActive = accentSoft.opacity(0.3)    // Selected chip

    /// Text color that sits *on top of* `accent` (Play button, active chip
    /// icon, selected preset circle). Black in both modes because `accent`
    /// stays luminous enough in both — but named so call sites stop writing
    /// raw `Color.black` and we can retune once without a sweep.
    static let onAccent = Color.black

    private static func dynamic(dark: Color, light: Color) -> Color {
        Color(UIColor { trait in
            trait.userInterfaceStyle == .dark ? UIColor(dark) : UIColor(light)
        })
    }
}

/// User-selectable appearance. Persisted via `@AppStorage("appearance")`.
/// `.system` returns nil so SwiftUI falls through to the OS setting.
enum Appearance: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

/// Corner-radius scale. Three steps; don't introduce a fourth without a reason.
enum HushRadius {
    static let sm: CGFloat = 14   // compact chips, tight rows
    static let md: CGFloat = 20   // panels, buttons
    static let lg: CGFloat = 24   // hero surfaces, large containers
}

/// Motion scale. `quick` for press feedback, `standard` for most transitions,
/// `slow` for preset/scene changes. Use `Animation.linear(duration:)` only for
/// continuous progress (e.g. timer ring), never for discrete transitions.
enum HushMotion {
    static let quick = Animation.easeOut(duration: 0.15)
    static let standard = Animation.easeInOut(duration: 0.25)
    static let slow = Animation.easeInOut(duration: 0.4)
}

/// Single, flat backdrop. No dot grid, no radial glow, no mask gradient —
/// panels earn their separation from the surface via a 1px outline, not
/// stacked effects on the background.
struct HushBackdrop: View {
    var body: some View {
        HushPalette.background
            .ignoresSafeArea()
    }
}

private struct HushPanelModifier: ViewModifier {
    let radius: CGFloat
    let fill: Color

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(fill)
                    .overlay(
                        RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .strokeBorder(HushPalette.outline, lineWidth: 1)
                    )
            )
    }
}

extension View {
    func hushPanel(radius: CGFloat = HushRadius.lg, fill: Color = HushPalette.panelFill) -> some View {
        modifier(HushPanelModifier(radius: radius, fill: fill))
    }
}

/// Inline warning banner — lighter-weight alternative to `.alert` for
/// advisory messages (headphone tips, safety notes, route changes).
struct HushBanner: View {
    let icon: String
    let title: String
    let message: String
    var accent: Color = HushPalette.accentSoft
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(accent)
                .frame(width: 32, height: 32)
                .background(Circle().fill(accent.opacity(0.18)))

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(HushPalette.textPrimary)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(HushPalette.textSecondary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(HushPalette.textSecondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(HushPressButtonStyle())
            .accessibilityLabel("Dismiss")
        }
        .padding(.leading, 14)
        .padding(.vertical, 10)
        .padding(.trailing, 6)
        .hushPanel(radius: HushRadius.md)
        .accessibilityElement(children: .combine)
    }
}

struct HushInfoPill: View {
    let icon: String
    let text: String
    var highlighted = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.caption.weight(.semibold))
            Text(text)
                .font(.caption.weight(.medium))
                .monospacedDigit()
        }
        .foregroundStyle(highlighted ? HushPalette.onAccent : HushPalette.textSecondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            Capsule()
                .fill(highlighted ? HushPalette.accent : HushPalette.raisedFill)
                .overlay(
                    Capsule()
                        .strokeBorder(
                            highlighted ? HushPalette.accentEdge : HushPalette.outline,
                            lineWidth: 1
                        )
                )
        )
    }
}

struct HushCircleButtonStyle: ButtonStyle {
    var selected = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(HushPalette.textPrimary)
            .frame(width: 48, height: 48)
            .background(
                Circle()
                    .fill(selected ? HushPalette.surfaceRaised : HushPalette.panelFillSoft)
                    .overlay(
                        Circle()
                            .strokeBorder(selected ? HushPalette.outlineStrong : HushPalette.outline, lineWidth: 1)
                    )
            )
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(HushMotion.quick, value: configuration.isPressed)
    }
}

/// Subtle press feedback for interactive elements (icons, chips, cards).
struct HushPressButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.7 : 1)
            .animation(HushMotion.quick, value: configuration.isPressed)
    }
}

/// Press highlight for full-width rows — slight brightness shift.
struct HushRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .brightness(configuration.isPressed ? -0.06 : 0)
            .animation(HushMotion.quick, value: configuration.isPressed)
    }
}

/// Press feedback for primary action buttons (Play, Get Started).
struct HushPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.975 : 1)
            .brightness(configuration.isPressed ? -0.08 : 0)
            .animation(HushMotion.quick, value: configuration.isPressed)
    }
}
