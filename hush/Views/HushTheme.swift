import SwiftUI

enum HushPalette {
    static let background = Color(red: 0.035, green: 0.036, blue: 0.044)
    static let backgroundLift = Color(red: 0.066, green: 0.070, blue: 0.086)
    static let surface = Color(red: 0.082, green: 0.086, blue: 0.104)
    static let surfaceRaised = Color(red: 0.118, green: 0.124, blue: 0.148)
    static let outline = Color.white.opacity(0.10)
    static let outlineStrong = Color.white.opacity(0.18)
    static let textPrimary = Color(red: 0.952, green: 0.948, blue: 0.928)
    static let textSecondary = Color(red: 0.694, green: 0.701, blue: 0.748)
    static let textMuted = Color.white.opacity(0.55)
    static let accent = Color(red: 0.936, green: 0.904, blue: 0.832)
    static let accentSoft = Color(red: 0.690, green: 0.760, blue: 0.734)
    static let accentGlow = Color(red: 0.412, green: 0.498, blue: 0.474)
    static let danger = Color(red: 0.924, green: 0.446, blue: 0.415)
}

struct HushBackdrop: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [HushPalette.backgroundLift, HushPalette.background, Color.black],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            RadialGradient(
                colors: [HushPalette.accentGlow.opacity(0.28), .clear],
                center: .top,
                startRadius: 12,
                endRadius: 360
            )
            .offset(y: -120)

            HushDotGrid()
                .opacity(0.55)
                .mask(
                    LinearGradient(
                        colors: [.clear, .white, .white.opacity(0.35), .clear],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
        }
        .ignoresSafeArea()
    }
}

private struct HushDotGrid: View {
    var spacing: CGFloat = 24

    var body: some View {
        GeometryReader { _ in
            Canvas { context, size in
                var dots = Path()

                for x in stride(from: spacing / 2, through: size.width, by: spacing) {
                    for y in stride(from: spacing / 2, through: size.height, by: spacing) {
                        dots.addEllipse(in: CGRect(x: x, y: y, width: 1.5, height: 1.5))
                    }
                }

                context.fill(dots, with: .color(HushPalette.outlineStrong))
            }
        }
        .allowsHitTesting(false)
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
                    .overlay(
                        RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [.white.opacity(0.05), .clear],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                    )
                    .shadow(color: .black.opacity(0.34), radius: 28, x: 0, y: 16)
            )
    }
}

extension View {
    func hushPanel(radius: CGFloat = 28, fill: Color = HushPalette.surface.opacity(0.94)) -> some View {
        modifier(HushPanelModifier(radius: radius, fill: fill))
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
        .foregroundStyle(highlighted ? Color.black : HushPalette.textSecondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            Capsule()
                .fill(highlighted ? HushPalette.accent : HushPalette.surfaceRaised.opacity(0.92))
                .overlay(
                    Capsule()
                        .strokeBorder(
                            highlighted ? Color.white.opacity(0.25) : HushPalette.outline,
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
                    .fill(selected ? HushPalette.surfaceRaised : HushPalette.surface.opacity(0.92))
                    .overlay(
                        Circle()
                            .strokeBorder(selected ? HushPalette.outlineStrong : HushPalette.outline, lineWidth: 1)
                    )
            )
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.18), value: configuration.isPressed)
    }
}

/// Subtle press feedback for interactive elements (icons, chips, cards).
struct HushPressButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.7 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

/// Press highlight for full-width rows — slight brightness shift.
struct HushRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .brightness(configuration.isPressed ? -0.06 : 0)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Press feedback for primary action buttons (Play, Get Started).
struct HushPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.975 : 1)
            .brightness(configuration.isPressed ? -0.08 : 0)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
    }
}
