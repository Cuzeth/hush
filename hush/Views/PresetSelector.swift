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

    @State private var renameTarget: RenameTarget?
    @State private var presetToEdit: Preset?
    @Namespace private var presetSelection

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
            .buttonStyle(HushRowButtonStyle())
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
                .buttonStyle(HushRowButtonStyle())
                .accessibilityLabel(preset.name)
                .accessibilityHint("Double tap to play")
                .contextMenu {
                    Button {
                        presetToEdit = preset
                    } label: {
                        Label("Edit Sounds", systemImage: "slider.horizontal.3")
                    }
                    Button {
                        if let saved {
                            renameTarget = .saved(savedID: saved.stableID, currentName: saved.name)
                        } else {
                            renameTarget = .builtIn(preset: preset, currentName: preset.name)
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
        .sheet(item: $renameTarget) { target in
            RenamePresetSheet(initialName: target.currentName) { newName in
                applyRename(target: target, name: newName)
                renameTarget = nil
            }
            .presentationDetents([.height(220)])
            .presentationDragIndicator(.hidden)
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

    private func applyRename(target: RenameTarget, name: String) {
        switch target {
        case .builtIn(let preset, _):
            renameBuiltIn(preset, to: name)
        case .saved(let savedID, _):
            if let saved = savedByID[savedID] {
                saved.name = name
            }
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

            Image(systemName: isSelected ? "checkmark.circle.fill" : "play.circle")
                .font(.body)
                .foregroundStyle(isSelected ? HushPalette.accent : HushPalette.textMuted)
                .contentTransition(.symbolEffect(.replace))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .background {
            ZStack {
                // Base fill — present on every row.
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(HushPalette.surface.opacity(0.6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(HushPalette.outline, lineWidth: 1)
                    )

                // Selection highlight — slides between rows via
                // matchedGeometryEffect when the user picks a new scene.
                if isSelected {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(HushPalette.surfaceRaised.opacity(0.7))
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .strokeBorder(HushPalette.outlineStrong, lineWidth: 1)
                        )
                        .matchedGeometryEffect(id: "presetHighlight", in: presetSelection)
                }
            }
        }
    }

    private func presetSummary(_ preset: Preset) -> String {
        soundSourceSummary(preset.sources)
    }
}

private enum RenameTarget: Identifiable {
    case builtIn(preset: Preset, currentName: String)
    case saved(savedID: UUID, currentName: String)

    var id: UUID {
        switch self {
        case .builtIn(let preset, _): return preset.id
        case .saved(let savedID, _): return savedID
        }
    }

    var currentName: String {
        switch self {
        case .builtIn(_, let name): return name
        case .saved(_, let name): return name
        }
    }
}

private struct RenamePresetSheet: View {
    let initialName: String
    let onSave: (String) -> Void

    @State private var name: String
    @FocusState private var fieldFocused: Bool
    @Environment(\.dismiss) private var dismiss

    init(initialName: String, onSave: @escaping (String) -> Void) {
        self.initialName = initialName
        self.onSave = onSave
        _name = State(initialValue: initialName)
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespaces)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                HushBackdrop()

                VStack(alignment: .leading, spacing: 14) {
                    Text("Name")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(HushPalette.textSecondary)
                        .textCase(.uppercase)

                    TextField("Preset name", text: $name)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(HushPalette.textPrimary)
                        .textFieldStyle(.plain)
                        .submitLabel(.done)
                        .focused($fieldFocused)
                        .onSubmit(save)
                        .padding(.vertical, 14)
                        .padding(.horizontal, 16)
                        .background(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(HushPalette.raisedFill)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                                        .strokeBorder(
                                            fieldFocused ? HushPalette.accentSoft : HushPalette.outline,
                                            lineWidth: 1
                                        )
                                        .animation(.easeInOut(duration: 0.15), value: fieldFocused)
                                )
                        )

                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 20)
                .padding(.top, 20)
            }
            .navigationTitle("Rename")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(HushPalette.textSecondary)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .fontWeight(.semibold)
                        .foregroundStyle(trimmedName.isEmpty ? HushPalette.textMuted : HushPalette.accentSoft)
                        .disabled(trimmedName.isEmpty)
                }
            }
            .defaultFocus($fieldFocused, true)
        }
        .tint(HushPalette.accentSoft)
    }

    private func save() {
        guard !trimmedName.isEmpty else { return }
        onSave(trimmedName)
    }
}
