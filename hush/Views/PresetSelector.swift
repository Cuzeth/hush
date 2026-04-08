import SwiftUI
import SwiftData

struct PresetSelector: View {
    let onSelect: (Preset) -> Void
    let onRandom: () -> Void
    var selectedPreset: Preset?

    @Query(sort: \SavedPreset.createdAt, order: .reverse)
    private var savedPresets: [SavedPreset]

    @Environment(\.modelContext) private var modelContext

    @State private var editingPreset: SavedPreset?
    @State private var editName = ""

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

            // Built-in preset rows
            ForEach(Preset.builtIn) { preset in
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

            // Saved preset rows with edit/delete
            ForEach(savedPresets) { saved in
                let preset = saved.toPreset()
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
                .contextMenu {
                    Button {
                        editName = saved.name
                        editingPreset = saved
                    } label: {
                        Label("Rename", systemImage: "pencil")
                    }
                    Button(role: .destructive) {
                        deletePreset(saved)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        }
        .alert("Rename Preset", isPresented: Binding(
            get: { editingPreset != nil },
            set: { if !$0 { editingPreset = nil } }
        )) {
            TextField("Name", text: $editName)
            Button("Save") {
                if let preset = editingPreset, !editName.isEmpty {
                    preset.name = editName
                }
                editingPreset = nil
            }
            Button("Cancel", role: .cancel) {
                editingPreset = nil
            }
        }
    }

    private func deletePreset(_ saved: SavedPreset) {
        withAnimation(.easeInOut(duration: 0.3)) {
            modelContext.delete(saved)
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
