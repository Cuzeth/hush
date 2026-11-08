import SwiftUI

/// Press handling for previewable Add Sound cards: a tap adds the sound, a
/// long press previews it. A PrimitiveButtonStyle owns both gestures, so a
/// long press never also fires the add when the finger lifts (a regular
/// Button with a long-press gesture attached does both). VoiceOver still
/// activates the Button's action as usual.
struct SoundCardButtonStyle: PrimitiveButtonStyle {
    let onLongPress: () -> Void

    func makeBody(configuration: Configuration) -> some View {
        SoundCardButton(configuration: configuration, onLongPress: onLongPress)
    }
}

private struct SoundCardButton: View {
    let configuration: PrimitiveButtonStyleConfiguration
    let onLongPress: () -> Void

    @State private var isPressed = false

    var body: some View {
        configuration.label
            // Same feedback as HushPressButtonStyle, so previewable cards
            // feel identical to the rest of the grid.
            .opacity(isPressed ? 0.7 : 1)
            .animation(HushMotion.quick, value: isPressed)
            .contentShape(RoundedRectangle(cornerRadius: HushRadius.lg, style: .continuous))
            .onTapGesture { configuration.trigger() }
            .onLongPressGesture(minimumDuration: 0.4) {
                onLongPress()
            } onPressingChanged: { pressing in
                isPressed = pressing
            }
    }
}
