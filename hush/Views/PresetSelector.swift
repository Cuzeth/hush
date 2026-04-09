import SwiftUI
import SwiftData

func soundSourceSummary(_ sources: [SoundSource]) -> String {
    let names = sources.map(\.displayName)
    if names.count <= 2 { return names.joined(separator: " + ") }
    return "\(names[0]) + \(names[1]) + \(names.count - 2) more"
}

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
    @State private var presetToEdit: Preset?

    @AppStorage("hiddenBuiltInPresets") private var hiddenBuiltInData = Data()
    @AppStorage("renamedBuiltInPresets") private var renamedBuiltInData = Data()

    private var hiddenBuiltInIDs: Set<UUID> {
        (try? JSONDecoder().decode(Set<UUID>.self, from: hiddenBuiltInData)) ?? []
    }

    private var renamedBuiltIns: [UUID: String] {
        (try? JSONDecoder().decode([UUID: String].self, from: renamedBuiltInData)) ?? [:]
    }

    // Saved presets keyed by stableID for quick lookup
    private var savedByID: [UUID: SavedPreset] {
        Dictionary(uniqueKeysWithValues: savedPresets.map { ($0.stableID, $0) })
    }

    /// Merged preset list: built-in slots (replaced by saved version if edited),
    /// followed by user-created presets that don't replace a built-in.
    private var orderedPresets: [(preset: Preset, saved: SavedPreset?)] {
        let builtInIDs = Set(Preset.builtIn.map(\.id))
        var result: [(Preset, SavedPreset?)] = []

        // Built-in slots in original order
        for builtIn in Preset.builtIn {
            if let saved = savedByID[builtIn.id] {
                // Edited built-in — show saved version in the built-in's slot
                result.append((saved.toPreset(), saved))
            } else if !hiddenBuiltInIDs.contains(builtIn.id) {
                // Unedited, not hidden
                var p = builtIn
                if let newName = renamedBuiltIns[builtIn.id] { p.name = newName }
                result.append((p, nil))
            }
        }

        // User-created presets (not replacing a built-in)
        for saved in savedPresets where !builtInIDs.contains(saved.stableID) {
            result.append((saved.toPreset(), saved))
        }

        return result
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
            .accessibilityLabel("Random Mix — shuffle two to three sounds")

            ForEach(orderedPresets, id: \.preset.id) { entry in
                let preset = entry.preset
                let saved = entry.saved
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
                .accessibilityLabel(preset.name)
                .accessibilityHint("Double tap to play")
                .contextMenu {
                    Button {
                        presetToEdit = preset
                    } label: {
                        Label("Edit Sounds", systemImage: "slider.horizontal.3")
                    }
                    Button {
                        editName = preset.name
                        if let saved {
                            editingPreset = .saved(saved)
                        } else {
                            editingPreset = .builtIn(preset)
                        }
                    } label: {
                        Label("Rename", systemImage: "pencil")
                    }
                    Button(role: .destructive) {
                        if let saved {
                            deleteSaved(saved)
                        } else {
                            hideBuiltIn(preset)
                        }
                        onDelete(preset)
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
        .sheet(item: $presetToEdit) { preset in
            EditPresetSheet(preset: preset) { preset, newSources in
                saveEditedPreset(preset, sources: newSources)
                // Reload with correct ID so highlighting works
                var updated = preset
                updated.sources = newSources
                onSelect(updated)
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
    }

    // MARK: - Persistence

    private func saveEditedPreset(_ preset: Preset, sources: [SoundSource]) {
        let targetID = preset.id
        let descriptor = FetchDescriptor<SavedPreset>(
            predicate: #Predicate { $0.stableID == targetID }
        )
        if let saved = try? modelContext.fetch(descriptor).first {
            saved.sources = sources
            return
        }

        // Built-in preset: convert to saved, keeping the same ID
        if preset.isBuiltIn {
            let name = renamedBuiltIns[preset.id] ?? preset.name
            let saved = SavedPreset(name: name, icon: preset.icon, sources: sources)
            saved.stableID = preset.id
            modelContext.insert(saved)
            // Don't call hideBuiltIn — orderedPresets already prefers the saved version
        }
    }

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
        soundSourceSummary(preset.sources)
    }
}

private enum EditTarget {
    case builtIn(Preset)
    case saved(SavedPreset)
}
