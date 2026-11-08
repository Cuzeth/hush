import Accessibility
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

    /// Manage mode: drag handles, inline actions, and the Hidden group.
    @State private var isManaging = false
    @State private var resetTarget: ResetTarget?
    /// The row being dragged, while its handle is held (and while it settles).
    @State private var drag: SceneDrag?
    /// Kept apart from `drag` so the row tracking the finger never picks up
    /// the animation the other rows use to make room.
    @State private var dragTranslation: CGFloat = 0
    /// Measured manage-row heights, for the drag math.
    @State private var rowHeights: [UUID: CGFloat] = [:]
    @Namespace private var manageNamespace

    @AppStorage(PrefsKey.hiddenBuiltInPresets) private var hiddenBuiltInData = Data()
    @AppStorage(PrefsKey.renamedBuiltInPresets) private var renamedBuiltInData = Data()
    @AppStorage(PrefsKey.sceneOrder) private var sceneOrderData = Data()

    private static let rowSpacing: CGFloat = 12
    private static let builtInIDs = Set(Preset.builtIn.map(\.id))

    private var hiddenBuiltInIDs: Set<UUID> {
        BuiltInSceneStore.decodeHidden(hiddenBuiltInData)
    }

    private var renamedBuiltIns: [UUID: String] {
        BuiltInSceneStore.decodeRenamed(renamedBuiltInData)
    }

    private var sceneOrder: [UUID] {
        SceneOrderStore.decode(sceneOrderData)
    }

    /// Merged preset list: built-in slots (replaced by saved version if edited),
    /// followed by user-created presets that don't replace a built-in, with
    /// the user's custom order applied.
    private var orderedPresets: [SceneEntry] {
        orderedPresets(order: sceneOrder)
    }

    private func orderedPresets(order: [UUID]) -> [SceneEntry] {
        SceneOrdering.ordered(
            saved: savedPresets,
            stableID: \.stableID,
            toPreset: { $0.toPreset() },
            hidden: hiddenBuiltInIDs,
            renamed: renamedBuiltIns,
            order: order
        )
    }

    /// Manage mode's Hidden group.
    private var hiddenScenes: [Preset] {
        SceneOrdering.hiddenBuiltIns(
            savedIDs: Set(savedPresets.map(\.stableID)),
            hidden: hiddenBuiltInIDs,
            renamed: renamedBuiltIns
        )
    }

    /// Short and plain under Reduce Motion: rows still reflow, but nothing
    /// flies, scales or springs.
    private var manageMotion: Animation {
        reduceMotion ? HushMotion.quick : HushMotion.standard
    }

    var body: some View {
        let entries = orderedPresets
        let hidden = isManaging ? hiddenScenes : []

        VStack(alignment: .leading, spacing: 12) {
            header

            if !isManaging {
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
                .transition(.opacity)
            }

            VStack(spacing: Self.rowSpacing) {
                ForEach(Array(entries.enumerated()), id: \.element.preset.id) { index, entry in
                    if isManaging {
                        manageRow(entry, index: index, count: entries.count)
                    } else {
                        normalRow(entry)
                    }
                }
            }
            .coordinateSpace(.named(SceneManageRow.coordinateSpace))
            // A tick each time the dragged row claims a new slot, and a light
            // tap on lift and drop.
            .sensoryFeedback(.selection, trigger: drag?.target) { old, new in old != nil && new != nil }
            .sensoryFeedback(.impact(weight: .light), trigger: drag?.id)
            .onChange(of: entries.map(\.preset.id)) { _, visible in
                // The list changed under a drag (an Undo, say): its indices
                // no longer line up, so drop it rather than misplace rows.
                if let drag, !drag.isSettling, drag.order != visible { cancelDrag() }
            }
            .confirmationDialog(
                resetTarget.map { "Reset \u{201C}\($0.preset.name)\u{201D}?" } ?? "",
                isPresented: Binding(
                    get: { resetTarget != nil },
                    set: { if !$0 { resetTarget = nil } }
                ),
                titleVisibility: .visible,
                presenting: resetTarget
            ) { target in
                Button("Reset", role: target.saved != nil ? .destructive : nil) {
                    resetToOriginal(target)
                }
                Button("Cancel", role: .cancel) {}
            } message: { target in
                Text(target.resetMessage)
            }

            if !hidden.isEmpty {
                hiddenGroup(hidden)
                    .transition(.opacity)
            }
        }
        // A deleted user scene leaves the stored order once it's gone from
        // the list, so the prune never reshuffles a row that's still showing.
        .onChange(of: savedPresets.map(\.stableID)) { old, new in
            for id in SceneOrdering.removedUserSceneIDs(from: old, to: new, builtInIDs: Self.builtInIDs) {
                SceneOrderStore.prune(id)
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

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Text("Scenes")
                .font(.headline)
                .foregroundStyle(HushPalette.textPrimary)
                .accessibilityAddTraits(.isHeader)

            Spacer(minLength: 0)

            Button(action: toggleManaging) {
                Text(isManaging ? "Done" : "Manage")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(HushPalette.accentSoft)
                    .padding(.horizontal, 8)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(HushPressButtonStyle())
            .accessibilityHint(isManaging ? "Finishes managing scenes" : "Reorder, rename, and hide scenes")
        }
        .padding(.leading, 4)
    }

    private func toggleManaging() {
        withAnimation(manageMotion) {
            isManaging.toggle()
            drag = nil
            dragTranslation = 0
        }
        announce(isManaging
                 ? "Managing scenes. Drag a handle, or use Move Up and Move Down, to reorder."
                 : "Done managing scenes")
    }

    // MARK: - Normal Row

    @ViewBuilder
    private func normalRow(_ entry: SceneEntry) -> some View {
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

    // MARK: - Manage Mode

    private func manageRow(_ entry: SceneEntry, index: Int, count: Int) -> some View {
        let preset = entry.preset
        let isDragged = drag?.id == preset.id
        let isBuiltIn = Self.builtInIDs.contains(preset.id)

        return SceneManageRow(
            name: preset.name,
            detail: presetSummary(preset),
            actions: SceneManageAction.available(
                isBuiltIn: isBuiltIn,
                isEdited: isBuiltIn && entry.saved != nil,
                isRenamed: renamedBuiltIns[preset.id] != nil
            ),
            isLifted: isDragged && drag?.isSettling == false,
            canMoveUp: index > 0,
            canMoveDown: index < count - 1,
            perform: { action in performManageAction(action, entry: entry) },
            onMove: { step in moveScene(preset, by: step) },
            onDragChanged: { translation in dragChanged(preset.id, translation: translation) },
            onDragEnded: dragEnded
        )
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
            rowHeights[preset.id] = height
        }
        .modifier(SceneManageMatch(id: preset.id, namespace: manageNamespace, enabled: !reduceMotion))
        .offset(y: dragOffset(forRowAt: index, id: preset.id))
        .zIndex(isDragged ? 1 : 0)
        .accessibilityAddTraits(selectedPreset?.id == preset.id ? .isSelected : [])
    }

    private func hiddenGroup(_ hidden: [Preset]) -> some View {
        VStack(alignment: .leading, spacing: Self.rowSpacing) {
            Text("Hidden")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(HushPalette.textSecondary)
                .padding(.horizontal, 4)
                .padding(.top, 8)
                .accessibilityAddTraits(.isHeader)

            ForEach(hidden) { preset in
                HiddenSceneRow(preset: preset) { showScene(preset) }
                    .modifier(SceneManageMatch(id: preset.id, namespace: manageNamespace, enabled: !reduceMotion))
            }
        }
    }

    private func performManageAction(_ action: SceneManageAction, entry: SceneEntry) {
        switch action {
        case .rename:
            beginRename(preset: entry.preset, saved: entry.saved)
        case .reset:
            resetTarget = ResetTarget(preset: entry.preset, saved: entry.saved)
        case .hide, .delete:
            // Same path as the menus: Hide runs at once (Undo toast), Delete
            // confirms first.
            performAction(DeleteTarget(preset: entry.preset, saved: entry.saved))
        }
    }

    private func showScene(_ preset: Preset) {
        withAnimation(manageMotion) {
            BuiltInSceneStore.unhide(preset.id)
        }
        announce("\(preset.name) is back in your scenes")
    }

    /// Reset to Original: drops the rename, and for an edited built-in runs
    /// the Revert path (delete the saved override) too.
    private func resetToOriginal(_ target: ResetTarget) {
        var renamed = renamedBuiltIns
        let hadRename = renamed.removeValue(forKey: target.preset.id) != nil
        if hadRename {
            withAnimation(manageMotion) {
                renamedBuiltInData = BuiltInSceneStore.encode(renamed)
            }
        }
        if target.saved != nil {
            performDelete(DeleteTarget(preset: target.preset, saved: target.saved))
        } else if hadRename, let original = target.original {
            // A reset is a rename: the loaded scene's header and Now Playing
            // take the original name back.
            onRename(target.preset.id, original.name)
        }
        announce("\(target.original?.name ?? target.preset.name) is back to its original")
    }

    // MARK: - Reordering

    /// The dragged row tracks the finger; rows it has passed step aside to
    /// open its target slot.
    private func dragOffset(forRowAt index: Int, id: UUID) -> CGFloat {
        guard let drag else { return 0 }
        if drag.id == id { return dragTranslation }
        return SceneDragLayout.shift(
            forRowAt: index,
            dragging: drag.startIndex,
            to: drag.target,
            draggedHeight: drag.heights[drag.startIndex],
            spacing: Self.rowSpacing
        )
    }

    private func dragChanged(_ id: UUID, translation: CGFloat) {
        if drag == nil {
            let visible = orderedPresets.map(\.preset.id)
            guard let start = visible.firstIndex(of: id) else { return }
            withAnimation(HushMotion.quick) {
                drag = SceneDrag(
                    id: id,
                    order: visible,
                    heights: visible.map { rowHeights[$0] ?? 66 },
                    startIndex: start,
                    target: start
                )
            }
        }
        guard let current = drag, current.id == id, !current.isSettling else { return }

        dragTranslation = translation
        let landing = SceneDragLayout.target(
            dragging: current.startIndex,
            heights: current.heights,
            spacing: Self.rowSpacing,
            translation: translation
        )
        if landing.index != current.target {
            withAnimation(manageMotion) {
                drag?.target = landing.index
                drag?.slotDelta = landing.slotDelta
            }
        }
    }

    /// Settles the row into its slot, then commits. Every row is already
    /// drawn where the new order puts it, so the commit is unanimated and
    /// nothing jumps.
    private func dragEnded() {
        guard var finished = drag, !finished.isSettling else { return }
        finished.isSettling = true
        withAnimation(manageMotion) {
            drag = finished
            dragTranslation = finished.slotDelta
        } completion: {
            commitDrag(finished)
        }
    }

    private func commitDrag(_ finished: SceneDrag) {
        // Leaving manage mode (or a list change) already dropped this drag.
        guard drag?.id == finished.id, drag?.isSettling == true else { return }
        let reordered = finished.target == finished.startIndex ? nil : SceneOrdering.moving(
            finished.id,
            by: finished.target - finished.startIndex,
            in: finished.order
        )
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            if let reordered { persistOrder(reordered) }
            drag = nil
            dragTranslation = 0
        }
        if let reordered, let name = orderedPresets.first(where: { $0.preset.id == finished.id })?.preset.name {
            announcePosition(of: name, at: finished.target, in: reordered)
        }
    }

    private func cancelDrag() {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            drag = nil
            dragTranslation = 0
        }
    }

    /// VoiceOver Move Up / Move Down.
    private func moveScene(_ preset: Preset, by step: Int) {
        let visible = orderedPresets.map(\.preset.id)
        guard let reordered = SceneOrdering.moving(preset.id, by: step, in: visible),
              let position = reordered.firstIndex(of: preset.id) else { return }
        withAnimation(manageMotion) {
            persistOrder(reordered)
        }
        announcePosition(of: preset.name, at: position, in: reordered)
    }

    private func persistOrder(_ visible: [UUID]) {
        let order = SceneOrdering.storedOrder(
            afterReordering: visible,
            previous: sceneOrder,
            defaultOrder: orderedPresets(order: []).map(\.preset.id)
        )
        sceneOrderData = SceneOrderStore.encode(order)
    }

    private func announcePosition(of name: String, at index: Int, in order: [UUID]) {
        announce("\(name) moved to position \(index + 1) of \(order.count)")
    }

    private func announce(_ message: String) {
        AccessibilityNotification.Announcement(message).post()
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
            if isManaging {
                // Animated so the row visibly moves into the Hidden group.
                withAnimation(manageMotion) { hideBuiltIn(target.preset) }
            } else {
                hideBuiltIn(target.preset)
            }
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

private typealias SceneEntry = (preset: Preset, saved: SavedPreset?)

/// A row drag in progress. Indices are into `order`, the visible list when
/// the drag began; nothing is persisted until the drop.
private struct SceneDrag {
    let id: UUID
    let order: [UUID]
    /// Row heights in `order`, measured when the drag began.
    let heights: [CGFloat]
    let startIndex: Int
    var target: Int
    /// From the row's starting slot to its target slot, where it settles.
    var slotDelta: CGFloat = 0
    /// Released and animating into place; the handle is ignored until it lands.
    var isSettling = false
}

/// Manage mode's Reset to Original, while it waits for confirmation.
private struct ResetTarget: Identifiable {
    let preset: Preset
    /// The edited version that owns the slot, if any.
    let saved: SavedPreset?
    var id: UUID { preset.id }

    var original: Preset? { Preset.builtIn.first { $0.id == preset.id } }

    var resetMessage: String {
        if saved != nil { return "Your edits will be removed and the original scene will return." }
        guard let original else { return "" }
        return "It goes back to its original name, \u{201C}\(original.name)\u{201D}."
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
