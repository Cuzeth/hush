import SwiftUI
import SwiftData

struct PresetSelector: View {
    let onSelect: (Preset) -> Void
    let onRandom: () -> Void
    var selectedPreset: Preset?

    @Query(sort: \SavedPreset.createdAt, order: .reverse)
    private var savedPresets: [SavedPreset]

    private let columns = [
        GridItem(.flexible(), spacing: 14),
        GridItem(.flexible(), spacing: 14)
    ]

    private var allPresets: [Preset] {
        Preset.builtIn + savedPresets.map { $0.toPreset() }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Scenes")
                        .font(.system(size: 30, weight: .semibold, design: .serif))
                        .foregroundStyle(HushPalette.textPrimary)

                    Text("One-tap soundscapes with a quieter, more intentional feel.")
                        .font(.subheadline)
                        .foregroundStyle(HushPalette.textSecondary)
                }

                Spacer()

                HushInfoPill(icon: "square.grid.2x2", text: "\(allPresets.count) ready")
            }

            LazyVGrid(columns: columns, spacing: 14) {
                RandomPresetCard(action: onRandom)

                ForEach(allPresets) { preset in
                    PresetCard(
                        preset: preset,
                        isSelected: selectedPreset?.id == preset.id,
                        action: { onSelect(preset) }
                    )
                }
            }
        }
    }
}

private struct RandomPresetCard: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    ZStack {
                        Circle()
                            .fill(HushPalette.surfaceRaised.opacity(0.94))
                            .frame(width: 42, height: 42)

                        Image(systemName: "dice.fill")
                            .font(.headline)
                            .foregroundStyle(HushPalette.textPrimary)
                    }

                    Spacer()

                    HushInfoPill(icon: "shuffle", text: "Fresh")
                }

                Spacer(minLength: 0)

                Text("Random Drift")
                    .font(.system(size: 23, weight: .semibold, design: .serif))
                    .foregroundStyle(HushPalette.textPrimary)

                Text("Let Hush build a new focus mix with layered ambience and noise.")
                    .font(.caption)
                    .foregroundStyle(HushPalette.textSecondary)
                    .multilineTextAlignment(.leading)
                    .lineSpacing(2)
            }
            .frame(maxWidth: .infinity, minHeight: 176, alignment: .leading)
            .padding(18)
            .background(
                RoundedRectangle(cornerRadius: 30, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 0.207, green: 0.238, blue: 0.274),
                                HushPalette.surface
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 30, style: .continuous)
                            .strokeBorder(HushPalette.outlineStrong, lineWidth: 1)
                    )
            )
            .shadow(color: .black.opacity(0.24), radius: 18, x: 0, y: 12)
        }
        .buttonStyle(.plain)
    }
}

private struct PresetCard: View {
    let preset: Preset
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top) {
                    ZStack {
                        Circle()
                            .fill(HushPalette.surfaceRaised.opacity(isSelected ? 0.98 : 0.88))
                            .frame(width: 42, height: 42)

                        Image(systemName: preset.icon)
                            .font(.headline)
                            .foregroundStyle(HushPalette.textPrimary)
                    }

                    Spacer()

                    Text(preset.isBuiltIn ? "Built In" : "Saved")
                        .font(.caption2.weight(.bold))
                        .tracking(1.2)
                        .foregroundStyle(HushPalette.textSecondary)
                }

                Spacer(minLength: 0)

                VStack(alignment: .leading, spacing: 6) {
                    Text(preset.name)
                        .font(.system(size: 22, weight: .semibold, design: .serif))
                        .foregroundStyle(HushPalette.textPrimary)
                        .multilineTextAlignment(.leading)

                    Text(presetSummary)
                        .font(.caption)
                        .foregroundStyle(HushPalette.textSecondary)
                        .multilineTextAlignment(.leading)
                        .lineSpacing(2)
                }

                HStack {
                    HushInfoPill(icon: "waveform", text: "\(preset.sources.count) layers")

                    Spacer()

                    if isSelected {
                        HushInfoPill(icon: "checkmark", text: "Active", highlighted: true)
                    }
                }
            }
            .frame(maxWidth: .infinity, minHeight: 176, alignment: .leading)
            .padding(18)
            .background(cardBackground)
            .overlay(
                RoundedRectangle(cornerRadius: 30, style: .continuous)
                    .strokeBorder(isSelected ? HushPalette.outlineStrong : HushPalette.outline, lineWidth: 1)
            )
            .shadow(color: .black.opacity(isSelected ? 0.34 : 0.20), radius: isSelected ? 22 : 14, x: 0, y: 12)
        }
        .buttonStyle(.plain)
    }

    private var presetSummary: String {
        let names = preset.sources.map(\.type.rawValue)

        if names.count <= 2 {
            return names.joined(separator: " / ")
        }

        return "\(names[0]) / \(names[1]) / +\(names.count - 2) more"
    }

    private var cardBackground: some View {
        let colors = palette(for: preset)

        return RoundedRectangle(cornerRadius: 30, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [
                        colors[0].opacity(isSelected ? 0.72 : 0.46),
                        colors[1].opacity(isSelected ? 0.28 : 0.14),
                        HushPalette.surface
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
    }

    private func palette(for preset: Preset) -> [Color] {
        guard let type = preset.sources.first?.type else {
            return [HushPalette.accentGlow, HushPalette.surfaceRaised]
        }

        switch type {
        case .rain, .stream, .ocean:
            return [Color(red: 0.258, green: 0.384, blue: 0.455), Color(red: 0.126, green: 0.180, blue: 0.243)]
        case .birdsong, .wind:
            return [Color(red: 0.310, green: 0.420, blue: 0.330), Color(red: 0.140, green: 0.190, blue: 0.158)]
        case .fire, .thunder:
            return [Color(red: 0.474, green: 0.282, blue: 0.180), Color(red: 0.182, green: 0.120, blue: 0.110)]
        case .binauralBeats:
            return [Color(red: 0.328, green: 0.252, blue: 0.444), Color(red: 0.160, green: 0.120, blue: 0.230)]
        case .whiteNoise, .pinkNoise, .brownNoise, .grayNoise:
            return [Color(red: 0.360, green: 0.340, blue: 0.286), Color(red: 0.160, green: 0.150, blue: 0.132)]
        }
    }
}
