import SwiftUI
import SwiftData

struct PresetSelector: View {
    let onSelect: (Preset) -> Void
    let onRandom: () -> Void
    var selectedPreset: Preset?

    @Query(sort: \SavedPreset.createdAt, order: .reverse)
    private var savedPresets: [SavedPreset]

    private var allPresets: [Preset] {
        Preset.builtIn + savedPresets.map { $0.toPreset() }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Scenes")
                .font(.headline)
                .foregroundStyle(HushPalette.textPrimary)
                .padding(.horizontal, 4)

            // Random mix row
            Button(action: onRandom) {
                presetRow(
                    icon: "dice.fill",
                    name: "Random Mix",
                    detail: "Shuffle 2–3 sounds",
                    isSelected: false
                )
            }
            .buttonStyle(.plain)

            // Preset rows
            ForEach(allPresets) { preset in
                let selected = selectedPreset?.id == preset.id
                Button { onSelect(preset) } label: {
                    presetRow(
                        icon: preset.icon,
                        name: preset.name,
                        detail: presetSummary(preset),
                        isSelected: selected
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func presetRow(icon: String, name: String, detail: String, isSelected: Bool) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.body.weight(.semibold))
                .foregroundStyle(isSelected ? Color.black : HushPalette.textPrimary)
                .frame(width: 40, height: 40)
                .background(
                    Circle()
                        .fill(isSelected ? HushPalette.accent : HushPalette.surfaceRaised)
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(HushPalette.textPrimary)

                Text(detail)
                    .font(.caption)
                    .foregroundStyle(HushPalette.textSecondary)
            }

            Spacer()

            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.body)
                    .foregroundStyle(HushPalette.accent)
            } else {
                Image(systemName: "play.circle")
                    .font(.body)
                    .foregroundStyle(HushPalette.textMuted)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(isSelected ? HushPalette.surfaceRaised.opacity(0.7) : HushPalette.surface.opacity(0.6))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(isSelected ? HushPalette.outlineStrong : HushPalette.outline, lineWidth: 1)
                )
        )
    }

    private func presetSummary(_ preset: Preset) -> String {
        let names = preset.sources.map(\.type.rawValue)
        if names.count <= 2 { return names.joined(separator: " + ") }
        return "\(names[0]) + \(names[1]) + \(names.count - 2) more"
    }
}
