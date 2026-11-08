import SwiftUI

// Manage mode for the scene list: reorder by drag handle, inline actions,
// and the Hidden group. `PresetSelector` owns the state and persistence;
// these views draw a row and report what the user did.

// MARK: - Actions

/// An inline action on a scene's manage row.
enum SceneManageAction: Identifiable, Equatable {
    case rename, reset, hide, delete

    var id: Self { self }

    var title: String {
        switch self {
        case .rename: return "Rename"
        case .reset: return "Reset to Original"
        case .hide: return "Hide"
        case .delete: return "Delete"
        }
    }

    var systemImage: String {
        switch self {
        case .rename: return "pencil"
        case .reset: return "arrow.counterclockwise"
        case .hide: return "eye.slash"
        case .delete: return "trash"
        }
    }

    var isDestructive: Bool { self == .delete }

    /// Every scene renames. A built-in resets once it's edited or renamed,
    /// and hides unless an edited version owns its slot (that version stays
    /// listed even when the stock scene is hidden, so Hide would do
    /// nothing). A user scene deletes.
    static func available(isBuiltIn: Bool, isEdited: Bool, isRenamed: Bool) -> [SceneManageAction] {
        guard isBuiltIn else { return [.rename, .delete] }
        var actions: [SceneManageAction] = [.rename]
        if isEdited || isRenamed { actions.append(.reset) }
        if !isEdited { actions.append(.hide) }
        return actions
    }
}

// MARK: - Drag geometry

/// Pure layout math for dragging a row through a vertical stack. Rows are
/// measured, not assumed equal, so Dynamic Type and wrapped names work.
enum SceneDragLayout {
    /// Where a dragged row lands: the slot (counted in the list without the
    /// row) whose center is nearest the row's dragged center, so it swaps
    /// halfway across a neighbour. `slotDelta` is the distance from the
    /// row's starting center to that slot's center, where it settles.
    static func target(
        dragging index: Int,
        heights: [CGFloat],
        spacing: CGFloat,
        translation: CGFloat
    ) -> (index: Int, slotDelta: CGFloat) {
        guard heights.indices.contains(index) else { return (index, 0) }
        let startCenter = heights[..<index].reduce(0, +) + CGFloat(index) * spacing + heights[index] / 2
        let draggedCenter = startCenter + translation
        var others = heights
        let height = others.remove(at: index)

        var best = (index: index, slotDelta: CGFloat(0))
        var bestDistance = CGFloat.infinity
        var top: CGFloat = 0
        for slot in 0...others.count {
            let center = top + height / 2
            let distance = abs(draggedCenter - center)
            if distance < bestDistance {
                bestDistance = distance
                best = (slot, center - startCenter)
            }
            if slot < others.count { top += others[slot] + spacing }
        }
        return best
    }

    /// How far a row that isn't being dragged moves to open the target
    /// slot: rows between the start and the target step one dragged-row
    /// height (plus spacing) toward the start. Committing the new order then
    /// puts every row exactly where it's drawn, so the drop doesn't jump.
    static func shift(
        forRowAt row: Int,
        dragging index: Int,
        to target: Int,
        draggedHeight: CGFloat,
        spacing: CGFloat
    ) -> CGFloat {
        let step = draggedHeight + spacing
        if index < target, row > index, row <= target { return -step }
        if target < index, row >= target, row < index { return step }
        return 0
    }
}

// MARK: - Rows

/// Past this size the name, up to three controls and the handle don't
/// share a 375pt row, so the controls drop to a line of their own.
private func stacksManageControls(_ size: DynamicTypeSize) -> Bool {
    size > .xLarge
}

/// A scene in manage mode: name, inline actions, drag handle. Not a button —
/// tapping a row while managing doesn't load it.
struct SceneManageRow: View {
    /// Named space the drag handles measure in: the scene list's own stack,
    /// which doesn't move with the dragged row (a local space would, and the
    /// row would chase its own offset).
    static let coordinateSpace = "sceneManageList"

    let name: String
    let detail: String
    let actions: [SceneManageAction]
    var isLifted = false
    var canMoveUp = false
    var canMoveDown = false
    let perform: (SceneManageAction) -> Void
    /// -1 up, 1 down: the VoiceOver Move Up / Move Down actions.
    let onMove: (Int) -> Void
    /// Vertical translation since the handle was grabbed.
    let onDragChanged: (CGFloat) -> Void
    let onDragEnded: () -> Void

    /// Resets on its own when the system cancels the drag (onEnded doesn't
    /// run then), so a cancelled drag still settles.
    @GestureState private var isHandleHeld = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var stacksControls: Bool { stacksManageControls(dynamicTypeSize) }

    var body: some View {
        Group {
            if stacksControls {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        title
                        handle
                    }
                    controls
                }
            } else {
                HStack(spacing: 8) {
                    title
                    controls
                    handle
                }
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, 4)
        .padding(.vertical, 11)
        .background {
            RoundedRectangle(cornerRadius: HushRadius.sm, style: .continuous)
                // Opaque while lifted: it slides over the rows below it.
                .fill(isLifted ? HushPalette.surfaceRaised : HushPalette.surface.opacity(0.6))
                .overlay(
                    RoundedRectangle(cornerRadius: HushRadius.sm, style: .continuous)
                        .strokeBorder(isLifted ? HushPalette.outlineStrong : HushPalette.outline, lineWidth: 1)
                )
        }
        // The lift is a shadow plus, without Reduce Motion, a slight scale.
        .scaleEffect(isLifted && !reduceMotion ? 1.02 : 1)
        .shadow(color: isLifted ? HushPalette.scrim.opacity(0.35) : .clear, radius: 12, y: 6)
        .accessibilityElement(children: .contain)
        .onChange(of: isHandleHeld) { _, held in
            if !held { onDragEnded() }
        }
    }

    private var title: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(HushPalette.textPrimary)
                .lineLimit(stacksControls ? nil : 2)
            Text(detail)
                .font(.caption)
                .foregroundStyle(HushPalette.textSecondary)
                .lineLimit(stacksControls ? 2 : 1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name). \(detail)")
        // The drag handle is hidden from VoiceOver; these do its job, and
        // repeat the inline buttons so one element carries everything.
        .accessibilityActions {
            if canMoveUp {
                Button("Move Up") { onMove(-1) }
            }
            if canMoveDown {
                Button("Move Down") { onMove(1) }
            }
            ForEach(actions) { action in
                Button(action.title) { perform(action) }
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 0) {
            ForEach(actions) { action in
                Button(role: action.isDestructive ? .destructive : nil) {
                    perform(action)
                } label: {
                    ManageGlyph(
                        systemName: action.systemImage,
                        tint: action.isDestructive ? HushPalette.danger : HushPalette.textSecondary
                    )
                }
                .buttonStyle(HushPressButtonStyle())
                .accessibilityLabel("\(action.title) \(name)")
                .accessibilityInputLabels([action.title, "\(action.title) \(name)"])
            }
        }
        // Glyphs stop growing at AX1 so three of them still fit a phone row.
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
    }

    private var handle: some View {
        ManageGlyph(
            systemName: "line.3.horizontal",
            tint: isLifted ? HushPalette.textPrimary : HushPalette.textMuted
        )
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        // Zero distance: the row lifts on touch, like a List handle, and the
        // touch can't start a scroll instead.
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.coordinateSpace))
                .updating($isHandleHeld) { _, held, _ in held = true }
                .onChanged { onDragChanged($0.translation.height) }
                .onEnded { _ in onDragEnded() }
        )
        .accessibilityHidden(true)
    }
}

/// A hidden built-in in manage mode's Hidden group, with a way back.
struct HiddenSceneRow: View {
    let preset: Preset
    let onShow: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let layout = stacksManageControls(dynamicTypeSize)
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(spacing: 12))

        layout {
            HStack(spacing: 14) {
                Image(systemName: preset.icon)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(HushPalette.textMuted)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(HushPalette.chipMuted))
                    .accessibilityHidden(true)

                Text(preset.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(HushPalette.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: onShow) {
                Label("Show", systemImage: "eye")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(HushPalette.accentSoft)
                    .padding(.horizontal, 14)
                    .frame(minHeight: 44)
                    .background(Capsule().fill(HushPalette.chipMuted))
                    .contentShape(Capsule())
            }
            .buttonStyle(HushPressButtonStyle())
            .accessibilityLabel("Show \(preset.name)")
            .accessibilityInputLabels(["Show", "Show \(preset.name)"])
        }
        .padding(.leading, 16)
        .padding(.trailing, 11)
        .padding(.vertical, 11)
        .background(
            RoundedRectangle(cornerRadius: HushRadius.sm, style: .continuous)
                .fill(HushPalette.surface.opacity(0.3))
                .overlay(
                    RoundedRectangle(cornerRadius: HushRadius.sm, style: .continuous)
                        .strokeBorder(HushPalette.outline, lineWidth: 1)
                )
        )
        .accessibilityElement(children: .contain)
    }
}

/// An icon control with a 44pt target that scales with Dynamic Type.
private struct ManageGlyph: View {
    let systemName: String
    var tint: Color = HushPalette.textSecondary

    @ScaledMetric(relativeTo: .body) private var size: CGFloat = 44

    var body: some View {
        Image(systemName: systemName)
            .font(.body.weight(.semibold))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .contentShape(Rectangle())
    }
}

/// Lets a manage row fly into the Hidden group (and back) as one view.
/// Off under Reduce Motion, which falls back to a plain crossfade.
struct SceneManageMatch: ViewModifier {
    let id: UUID
    let namespace: Namespace.ID
    let enabled: Bool

    func body(content: Content) -> some View {
        if enabled {
            content.matchedGeometryEffect(id: id, in: namespace)
        } else {
            content
        }
    }
}
