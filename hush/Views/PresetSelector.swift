import SwiftUI
import SwiftData

struct PresetSelector: View {
    let onSelect: (Preset) -> Void
    let onRandom: () -> Void
    let onDelete: (Preset) -> Void
    var selectedPreset: Preset?

    @Query(sort: \SavedPreset.createdAt, order: .reverse)
    private var savedPresets: [SavedPreset]

    @Environment(\.modelContext) private var modelContext

    @State private var editingPreset: EditTarget?
    @State private var editName = ""

    // Track which built-in presets the user has hidden or renamed
    @AppStorage("hiddenBuiltInPresets") private var hiddenBuiltInData = Data()
    @AppStorage("renamedBuiltInPresets") private var renamedBuiltInData = Data()

    private var hiddenBuiltInIDs: Set<UUID> {
        get { (try? JSONDecoder().decode(Set<UUID>.self, from: hiddenBuiltInData)) ?? [] }
    }

    private var renamedBuiltIns: [UUID: String] {
        get { (try? JSONDecoder().decode([UUID: String].self, from: renamedBuiltInData)) ?? [:] }
    }

    private var visibleBuiltIns: [Preset] {
        Preset.builtIn
            .filter { !hiddenBuiltInIDs.contains($0.id) }
            .map { preset in
                if let newName = renamedBuiltIns[preset.id] {
                    var p = preset
                    p.name = newName
                    return p
                }
                return preset
            }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Scenes")
                .font(.headline)
                .foregroundStyle(HushPalette.textPrimary)
                .padding(.horizontal, 4)

            Button(action: onRandom) {
                presetRow(
                    icon: "dice.fill",
                    name: "Random Mix",
                    detail: "Shuffle 2–3 sounds",
                    isSelected: false
                )
            }
            .buttonStyle(.plain)

            // Built-in presets (with rename/delete via context menu)
            ForEach(visibleBuiltIns) { preset in
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
                        editName = preset.name
                        editingPreset = .builtIn(preset)
                    } label: {
                        Label("Rename", systemImage: "pencil")
                    }
                    Button(role: .destructive) {
                        hideBuiltIn(preset)
                        onDelete(preset)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }

            // Saved presets
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
                        editingPreset = .saved(saved)
                    } label: {
                        Label("Rename", systemImage: "pencil")
                    }
                    Button(role: .destructive) {
                        let p = saved.toPreset()
                        deleteSaved(saved)
                        onDelete(p)
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
                guard !editName.isEmpty else { editingPreset = nil; return }
                switch editingPreset {
                case .builtIn(let preset):
                    renameBuiltIn(preset, to: editName)
                case .saved(let saved):
                    saved.name = editName
                case .none:
                    break
                }
                editingPreset = nil
            }
            Button("Cancel", role: .cancel) {
                editingPreset = nil
            }
        }
    }

    // MARK: - Built-in Preset Mutations (stored in UserDefaults)

    private func hideBuiltIn(_ preset: Preset) {
        var hidden = hiddenBuiltInIDs
        hidden.insert(preset.id)
        hiddenBuiltInData = (try? JSONEncoder().encode(hidden)) ?? Data()
    }

    private func renameBuiltIn(_ preset: Preset, to name: String) {
        var renamed = renamedBuiltIns
        renamed[preset.id] = name
        renamedBuiltInData = (try? JSONEncoder().encode(renamed)) ?? Data()
    }

    private func deleteSaved(_ saved: SavedPreset) {
        withAnimation(.easeInOut(duration: 0.3)) {
            modelContext.delete(saved)
        }
    }

    // MARK: - Row

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

private enum EditTarget {
    case builtIn(Preset)
    case saved(SavedPreset)
}
