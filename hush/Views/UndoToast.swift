import Accessibility
import SwiftUI

/// The transient "did X — Undo" bar above the transport. One shape and one
/// lifetime for every undoable action (hiding a scene, removing a layer).
/// The host shows at most one: a newer action's toast replaces the older
/// one, and the older Undo goes with it.
struct UndoToast: View {
    /// Identity of the action. A new id restarts the timeout and the
    /// announcement even when the toast stays on screen.
    let id: UUID
    let icon: String
    let message: String
    /// Posted when the toast appears, so VoiceOver users learn Undo exists.
    let announcement: String
    let undoAccessibilityLabel: String
    let onUndo: () -> Void
    /// The timeout ran out; the host drops the toast and its undo record.
    let onExpire: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @ScaledMetric(relativeTo: .footnote) private var undoMinSize: CGFloat = 44

    /// Transient by design, with a lasting way back elsewhere (Settings →
    /// Show Hidden Scenes, the sound picker). VoiceOver users get longer to
    /// reach the button.
    static func lifetime(voiceOverEnabled: Bool) -> Duration {
        .seconds(voiceOverEnabled ? 12 : 5)
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(HushPalette.textSecondary)
                .accessibilityHidden(true)
            Text(message)
                .font(.footnote)
                .foregroundStyle(HushPalette.textPrimary)
            Spacer(minLength: 8)
            Button(action: onUndo) {
                Text("Undo")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(HushPalette.accentSoft)
                    .frame(minWidth: undoMinSize, minHeight: undoMinSize)
                    .contentShape(Rectangle())
            }
            .buttonStyle(HushPressButtonStyle())
            .accessibilityLabel(undoAccessibilityLabel)
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .padding(.vertical, 4)
        // Opaque: it floats over scrolling rows, which bled through the
        // default translucent panel fill.
        .hushPanel(radius: HushRadius.sm, fill: HushPalette.surface)
        .padding(.horizontal, 20)
        .padding(.bottom, 4)
        .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
        .task(id: id) {
            AccessibilityNotification.Announcement(announcement).post()
            try? await Task.sleep(for: Self.lifetime(voiceOverEnabled: voiceOverEnabled))
            guard !Task.isCancelled else { return }
            onExpire()
        }
    }
}
