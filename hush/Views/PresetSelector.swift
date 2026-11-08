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
    /// Drives the row hint: a selected scene is only "playing" when it is.
    var isPlaying = false
    /// Called after any rename is persisted, with the scene's id and new name.
    var onRename: (UUID, String) -> Void = { _, _ in }
    /// Called right after a built-in scene is hidden (before `onDelete`), so
    /// the host can offer Undo.
    var onHide: (Preset) -> Void = { _ in }

    @Query(sort: \SavedPreset.createdAt, order: .reverse)
    private var savedPresets: [SavedPreset]

    @Environment(\.modelContext) private var modelContext

    @State private var renameTarget: RenameTarget?
    @State private var presetToEdit: Preset?
    @State private var deleteTarget: DeleteTarget?
    @Namespace private var presetSelection
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @AppStorage(PrefsKey.hiddenBuiltInPresets) private var hiddenBuiltInData = Data()
    @AppStorage(PrefsKey.renamedBuiltInPresets) private var renamedBuiltInData = Data()

    private var hiddenBuiltInIDs: Set<UUID> {
        BuiltInSceneStore.decodeHidden(hiddenBuiltInData)
    }

    private var renamedBuiltIns: [UUID: String] {
        BuiltInSceneStore.decodeRenamed(renamedBuiltInData)
    }

    /// Merged preset list: built-in slots (replaced by saved version if edited),
    /// followed by user-created presets that don't replace a built-in.
    private var orderedPresets: [(preset: Preset, saved: SavedPreset?)] {
        SceneOrdering.ordered(
            saved: savedPresets,
            stableID: \.stableID,
            toPreset: { $0.toPreset() },
            hidden: hiddenBuiltInIDs,
            renamed: renamedBuiltIns
        )
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
                    detail: "Shuffle a few sounds",
                    isSelected: false
                )
            }
            .buttonStyle(HushRowButtonStyle())
            .accessibilityLabel("Random Mix — shuffles a few sounds")

            ForEach(orderedPresets, id: \.preset.id) { entry in
                let preset = entry.preset
                let saved = entry.saved
                let selected = selectedPreset?.id == preset.id
                let target = DeleteTarget(preset: preset, saved: saved)
                let summary = presetSummary(preset)

                Button { onSelect(preset) } label: {
                    presetRow(
                        icon: preset.icon,
                        name: preset.name,
                        detail: summary,
                        isSelected: selected,
                        reservesMenuSpace: true
                    )
                }
                .buttonStyle(HushRowButtonStyle())
                .accessibilityLabel("\(preset.name). \(summary)")
                .accessibilityHint(selected && isPlaying ? "Currently playing" : "Plays this scene")
                .accessibilityAddTraits(selected ? .isSelected : [])
                // Same actions as the visible menu and the long-press menu,
                // reachable from the VoiceOver rotor.
                .accessibilityAction(named: "Edit Sounds") { presetToEdit = preset }
                .accessibilityAction(named: "Rename") { beginRename(preset: preset, saved: saved) }
                .accessibilityAction(named: target.kind.actionTitle) { performAction(target) }
                .contextMenu {
                    sceneActions(preset: preset, saved: saved, target: target)
                }
                // Visible entry point for the same actions — the long-press
                // menu alone gave no on-screen hint they existed.
                .overlay(alignment: .trailing) {
                    Menu {
                        sceneActions(preset: preset, saved: saved, target: target)
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(HushPalette.textSecondary)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .padding(.trailing, 4)
                    .accessibilityLabel("More actions for \(preset.name)")
                }
            }
        }
        .confirmationDialog(
            deleteTarget.map(deleteDialogTitle) ?? "",
            isPresented: Binding(
                get: { deleteTarget != nil },
                set: { if !$0 { deleteTarget = nil } }
            ),
            titleVisibility: .visible,
            presenting: deleteTarget
        ) { target in
            Button(target.kind == .revertEditedBuiltIn ? "Revert" : "Delete", role: .destructive) {
                performDelete(target)
            }
            Button("Cancel", role: .cancel) {}
        } message: { target in
            Text(target.kind == .revertEditedBuiltIn
                 ? "Your edits will be removed and the original scene will return."
                 : "This can't be undone.")
        }
        .sheet(item: $renameTarget) { target in
            RenamePresetSheet(initialName: target.currentName) { newName in
                applyRename(target: target, name: newName)
                renameTarget = nil
            }
            // .medium instead of a fixed height: a 220pt detent clips the
            // title + field at accessibility Dynamic Type sizes.
            .presentationDetents([.medium])
            .presentationDragIndicator(.hidden)
        }
        .sheet(item: $presetToEdit) { preset in
            EditPresetSheet(preset: preset) { preset, newSources in
                ScenePersistence.saveEdited(
                    preset,
                    sources: newSources,
                    renamedBuiltIns: renamedBuiltIns,
                    context: modelContext
                )
                // Reload only the scene that's loaded (correct ID keeps the
                // highlight). Editing any other scene must not stop the mix
                // the user is listening to.
                if selectedPreset?.id == preset.id {
                    var updated = preset
                    updated.sources = newSources
                    onSelect(updated)
                }
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
    }

    // MARK: - Scene Actions

    /// Edit / Rename / Hide-Revert-Delete. One builder feeds the visible "…"
    /// menu and the long-press menu so they can't drift apart.
    @ViewBuilder
    private func sceneActions(preset: Preset, saved: SavedPreset?, target: DeleteTarget) -> some View {
        Button {
            presetToEdit = preset
        } label: {
            Label("Edit Sounds", systemImage: "slider.horizontal.3")
        }
        Button {
            beginRename(preset: preset, saved: saved)
        } label: {
            Label("Rename", systemImage: "pencil")
        }
        switch target.kind {
        case .hideBuiltIn:
            // Non-destructive (Undo toast, and Settings can show it again) —
            // no confirmation, but the label must say what it does.
            Button {
                performAction(target)
            } label: {
                Label(target.kind.actionTitle, systemImage: "eye.slash")
            }
        case .revertEditedBuiltIn:
            Button(role: .destructive) {
                performAction(target)
            } label: {
                Label(target.kind.actionTitle, systemImage: "arrow.uturn.backward")
            }
        case .deleteSaved:
            Button(role: .destructive) {
                performAction(target)
            } label: {
                Label(target.kind.actionTitle, systemImage: "trash")
            }
        }
    }

    private func beginRename(preset: Preset, saved: SavedPreset?) {
        if let saved {
            renameTarget = .saved(savedID: saved.stableID, currentName: saved.name)
        } else {
            renameTarget = .builtIn(preset: preset, currentName: preset.name)
        }
    }

    /// Hide runs immediately (it's undoable); revert and delete confirm first.
    private func performAction(_ target: DeleteTarget) {
        switch target.kind {
        case .hideBuiltIn:
            hideBuiltIn(target.preset)
            onHide(target.preset)
            onDelete(target.preset)
        case .revertEditedBuiltIn, .deleteSaved:
            deleteTarget = target
        }
    }

    private func applyRename(target: RenameTarget, name: String) {
        switch target {
        case .builtIn(let preset, _):
            renameBuiltIn(preset, to: name)
        case .saved(let savedID, _):
            guard let saved = savedPresets.first(where: { $0.stableID == savedID }) else { return }
            saved.name = name
        }
        onRename(target.id, name)
    }

    // MARK: - Persistence

    private func hideBuiltIn(_ preset: Preset) {
        var hidden = hiddenBuiltInIDs
        hidden.insert(preset.id)
        hiddenBuiltInData = BuiltInSceneStore.encode(hidden)
    }

    private func renameBuiltIn(_ preset: Preset, to name: String) {
        var renamed = renamedBuiltIns
        renamed[preset.id] = name
        renamedBuiltInData = BuiltInSceneStore.encode(renamed)
    }

    private func deleteSaved(_ saved: SavedPreset) {
        withAnimation(HushMotion.standard) {
            modelContext.delete(saved)
        }
    }

    // MARK: - Delete Confirmation

    private func deleteDialogTitle(_ target: DeleteTarget) -> String {
        switch target.kind {
        case .revertEditedBuiltIn: return "Revert \u{201C}\(target.preset.name)\u{201D}?"
        default: return "Delete \u{201C}\(target.preset.name)\u{201D}?"
        }
    }

    private func performDelete(_ target: DeleteTarget) {
        if let saved = target.saved {
            deleteSaved(saved)
        } else {
            hideBuiltIn(target.preset)
        }
        onDelete(target.preset)
    }

    // MARK: - Row

    /// `reservesMenuSpace` leaves room at the trailing edge for the "…" menu
    /// the scene rows overlay on top of the row button.
    private func presetRow(icon: String, name: String, detail: String, isSelected: Bool,
                           reservesMenuSpace: Bool = false) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.body.weight(.semibold))
                .foregroundStyle(isSelected ? HushPalette.onAccent : HushPalette.textPrimary)
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
                .foregroundStyle(isSelected ? HushPalette.accent : HushPalette.textSecondary)
                .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
        }
        .padding(.horizontal, 16)
        .padding(.trailing, reservesMenuSpace ? 40 : 0)
        .padding(.vertical, 13)
        .background {
            ZStack {
                // Base fill — present on every row.
                RoundedRectangle(cornerRadius: HushRadius.sm, style: .continuous)
                    .fill(HushPalette.surface.opacity(0.6))
                    .overlay(
                        RoundedRectangle(cornerRadius: HushRadius.sm, style: .continuous)
                            .strokeBorder(HushPalette.outline, lineWidth: 1)
                    )

                // Selection highlight — slides between rows via
                // matchedGeometryEffect when the user picks a new scene.
                // Reduce-motion users get a plain fade: we skip the matched
                // effect entirely so SwiftUI falls back to independent
                // insertion/removal per row.
                if isSelected {
                    selectionHighlight(inMatchedContext: !reduceMotion)
                }
            }
        }
    }

    private func presetSummary(_ preset: Preset) -> String {
        soundSourceSummary(preset.sources)
    }

    @ViewBuilder
    private func selectionHighlight(inMatchedContext: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: HushRadius.sm, style: .continuous)
            .fill(HushPalette.surfaceRaised.opacity(0.7))
            .overlay(
                RoundedRectangle(cornerRadius: HushRadius.sm, style: .continuous)
                    .strokeBorder(HushPalette.outlineStrong, lineWidth: 1)
            )
        if inMatchedContext {
            shape.matchedGeometryEffect(id: "presetHighlight", in: presetSelection)
        } else {
            shape.transition(.opacity)
        }
    }
}

private struct DeleteTarget: Identifiable {
    enum Kind {
        /// Unedited built-in: "deleting" just hides it (restorable in Settings).
        case hideBuiltIn
        /// A SavedPreset shadowing a built-in slot: deleting reverts to stock.
        case revertEditedBuiltIn
        /// A user-created preset: permanently destroyed.
        case deleteSaved
    }

    let preset: Preset
    let saved: SavedPreset?
    var id: UUID { preset.id }

    var kind: Kind {
        guard let saved else { return .hideBuiltIn }
        if Preset.builtIn.contains(where: { $0.id == saved.stableID }) {
            return .revertEditedBuiltIn
        }
        return .deleteSaved
    }
}

private extension DeleteTarget.Kind {
    /// Shared by the menus and the VoiceOver custom action.
    var actionTitle: String {
        switch self {
        case .hideBuiltIn: return "Hide"
        case .revertEditedBuiltIn: return "Revert to Original"
        case .deleteSaved: return "Delete"
        }
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
                            RoundedRectangle(cornerRadius: HushRadius.sm, style: .continuous)
                                .fill(HushPalette.raisedFill)
                                .overlay(
                                    RoundedRectangle(cornerRadius: HushRadius.sm, style: .continuous)
                                        .strokeBorder(
                                            fieldFocused ? HushPalette.accentSoft : HushPalette.outline,
                                            lineWidth: 1
                                        )
                                        .animation(HushMotion.quick, value: fieldFocused)
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
