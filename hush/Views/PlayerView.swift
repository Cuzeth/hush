import Accessibility
import SwiftUI
import SwiftData

struct PlayerView: View {
    @Bindable var viewModel: PlayerViewModel
    @State private var showSavePreset = false
    @State private var presetName = ""
    @State private var presetIcon = "star.fill"
    /// Bumped on every completed save so the success haptic fires once.
    @State private var saveFeedbackCount = 0
    /// The scene just hidden, while its Undo toast is up.
    @State private var hiddenSceneUndo: HiddenSceneUndo?
    /// The timer sheet opens on the duration picker (chip long press) rather
    /// than the countdown.
    @State private var timerSheetChoosesDuration = false

    private static let iconChoices = [
        "star.fill", "heart.fill", "bolt.fill", "moon.fill", "leaf.fill",
        "flame.fill", "drop.fill", "brain.head.profile", "sparkles",
        "headphones", "music.note", "waveform.circle"
    ]

    @Environment(\.modelContext) private var modelContext
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.horizontalSizeClass) private var sizeClass

    @ScaledMetric(relativeTo: .title) private var playButtonHeight: CGFloat = 62
    /// Touch-target floor for the stacked chip; its capped text sets the rest.
    private let stackedTimerChipHeight: CGFloat = 44
    @ScaledMetric(relativeTo: .subheadline) private var saveButtonSize: CGFloat = 44

    private var contentMaxWidth: CGFloat {
        sizeClass == .regular ? 600 : .infinity
    }

    /// Measured width and fold position; picks one column or two panes.
    @State private var paneGeometry = PlayerPaneGeometry()

    private var paneLayout: PlayerPaneLayout {
        PlayerPaneLayout.resolve(
            isRegularWidth: sizeClass == .regular,
            containerWidth: paneGeometry.width,
            folds: paneGeometry.folds
        )
    }

    var body: some View {
        NavigationStack {
            ZStack {
                HushBackdrop()

                switch paneLayout {
                case .singleColumn:
                    singleColumn
                case let .split(leading, gutter, trailing):
                    // Split at the fold (iPhone Duo) or down the middle
                    // (iPad): no control ever straddles the crease.
                    HStack(spacing: 0) {
                        playerPane
                            .frame(width: leading)
                        Color.clear
                            .frame(width: gutter)
                            .accessibilityHidden(true)
                        scenesPane
                            .frame(width: trailing)
                    }
                }
            }
            .onGeometryChange(for: PlayerPaneGeometry.self) { proxy in
                PlayerPaneGeometry(width: proxy.size.width, folds: PlayerPaneLayout.foldFrames(in: proxy))
            } action: { geometry in
                paneGeometry = geometry
            }
            .navigationTitle("Hush")
            .navigationBarTitleDisplayMode(.large)
            .toolbar { toolbarItems }
            .sensoryFeedback(.selection, trigger: viewModel.isPlaying)
            .sensoryFeedback(.selection, trigger: viewModel.currentPreset?.id)
            .sensoryFeedback(.impact(weight: .light), trigger: viewModel.showMixer)
            .sensoryFeedback(.impact(weight: .light), trigger: viewModel.activeSources.count)
            .sensoryFeedback(.success, trigger: saveFeedbackCount)
            .tint(HushPalette.accentSoft)
            .onAppear(perform: startFirstSceneAfterOnboardingIfNeeded)
            // One toast at a time, newest wins: a fresh layer removal
            // replaces a pending hidden-scene undo.
            .onChange(of: viewModel.lastRemovedLayer?.id) { _, id in
                if id != nil { hiddenSceneUndo = nil }
            }
            .sheet(isPresented: $viewModel.showTimer) {
                TimerView(viewModel: viewModel, choosingDuration: timerSheetChoosesDuration)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $viewModel.showSettings) {
                SettingsView(viewModel: viewModel)
            }
            .alert(
                viewModel.activeAlert?.title ?? "",
                isPresented: Binding(
                    get: { viewModel.activeAlert != nil },
                    set: { if !$0 { viewModel.dismissActiveAlert() } }
                ),
                presenting: viewModel.activeAlert
            ) { _ in
                Button("OK") {}
            } message: { alert in
                Text(alert.message)
            }
            .sheet(isPresented: $showSavePreset) {
                SavePresetSheet(
                    name: $presetName,
                    icon: $presetIcon,
                    iconChoices: Self.iconChoices
                ) {
                    // Trimmed like Rename: an all-spaces name isn't a name.
                    let name = presetName.trimmingCharacters(in: .whitespaces)
                    guard !name.isEmpty else { return }
                    viewModel.saveCurrentAsPreset(name: name, icon: presetIcon, context: modelContext)
                    presetName = ""
                    presetIcon = "star.fill"
                    showSavePreset = false
                    confirmSave("Saved \(name)")
                }
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
        }
    }

    // MARK: - Layouts

    /// iPhone, iPhone Duo closed, and any space too narrow (or folded the
    /// wrong way) for two panes.
    private var singleColumn: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 16) {
                nowPlayingHeader
                mixerSection
                presetSelector
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .frame(maxWidth: contentMaxWidth)
            .frame(maxWidth: .infinity)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            bottomBar
                .frame(maxWidth: contentMaxWidth)
                .frame(maxWidth: .infinity)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            warningBanner
                .frame(maxWidth: contentMaxWidth)
                .frame(maxWidth: .infinity)
        }
    }

    /// Leading pane in the split: the mix and its transport.
    private var playerPane: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 16) {
                nowPlayingHeader
                mixerSection
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar }
        .safeAreaInset(edge: .top, spacing: 0) { warningBanner }
    }

    /// Trailing pane in the split: the scene list, scrolling on its own.
    private var scenesPane: some View {
        ScrollView(showsIndicators: false) {
            presetSelector
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 20)
        }
    }

    private var presetSelector: some View {
        PresetSelector(
            onSelect: { preset in viewModel.loadPreset(preset) },
            onRandom: { viewModel.randomMix() },
            onDelete: { preset in viewModel.handlePresetDeleted(preset) },
            selectedPreset: viewModel.currentPreset,
            isPlaying: viewModel.isPlaying,
            onRename: { id, name in viewModel.handlePresetRenamed(id: id, newName: name) },
            onHide: { preset in showHiddenSceneUndo(for: preset) }
        )
    }

    private var bottomBar: some View {
        VStack(spacing: 0) {
            undoToast
            transportBar
        }
        .animation(reduceMotion ? nil : HushMotion.standard, value: undoToastID)
    }

    // MARK: - Toolbar

    // The timer lives in the transport bar (TimerChip); only Settings here.
    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button { viewModel.showSettings = true } label: {
                Image(systemName: "gearshape")
                    .foregroundStyle(HushPalette.textSecondary)
            }
            .accessibilityLabel("Settings")
        }
    }

    // MARK: - Now Playing (concise state, not marketing copy)

    private var nowPlayingHeader: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(currentTitle)
                    .font(.system(.title, design: .serif, weight: .semibold))
                    .foregroundStyle(HushPalette.textPrimary)

                // The level strip below names every layer, so a summary
                // line would only repeat it — show guidance when empty only.
                if viewModel.activeSources.isEmpty {
                    Text("Pick a scene below, or build your own mix in Customize.")
                        .font(.subheadline)
                        .foregroundStyle(HushPalette.textSecondary)
                        .transition(.opacity)
                }
            }

            // The mix up front: a level and a remove per layer. The
            // transport button's pause-state stays the canonical "are we
            // playing" indicator, so no separate Playing pill here.
            // Hidden while Customize is open: its full rows carry the same
            // sliders, and two sets for one layer read as two layers.
            if !viewModel.activeSources.isEmpty && !viewModel.showMixer {
                LayerLevelStrip(viewModel: viewModel)
                    // Let the remove buttons' hit areas run into the panel
                    // padding, so the xmarks sit on the content edge.
                    .padding(.trailing, -12)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .hushPanel(radius: HushRadius.lg, fill: HushPalette.surface)
    }

    // MARK: - Mixer Section (progressive disclosure, compact)

    private var mixerSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            // A real Button for the disclosure, with Save as a SIBLING.
            // The old shape (onTapGesture + .isButton + label on a container
            // that also held the save button) risked VoiceOver exposing one
            // "Show mixer" element and hiding Save entirely.
            HStack(spacing: 10) {
                Button {
                    if reduceMotion {
                        viewModel.showMixer.toggle()
                    } else {
                        withAnimation(HushMotion.standard) {
                            viewModel.showMixer.toggle()
                        }
                    }
                } label: {
                    HStack {
                        Text("Customize")
                            .font(.headline)
                            .foregroundStyle(HushPalette.textPrimary)
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 14)
                    .contentShape(Rectangle())
                }
                .buttonStyle(HushRowButtonStyle())
                // Keep the visible "Customize" name (Voice Control matches on
                // it); the state goes in the value.
                .accessibilityValue(viewModel.showMixer ? "Expanded" : "Collapsed")

                if !viewModel.activeSources.isEmpty {
                    if let scene = updatableScene {
                        // A tweaked scene is loaded: offer to write the
                        // tweaks back to it, or branch off a new one.
                        Menu {
                            Button {
                                updateCurrentScene()
                            } label: {
                                Label("Update \u{201C}\(scene.name)\u{201D}", systemImage: "arrow.triangle.2.circlepath")
                            }
                            Button {
                                presentSavePreset()
                            } label: {
                                Label("Save as New Scene…", systemImage: "plus.square.on.square")
                            }
                        } label: {
                            saveButtonLabel
                        }
                        .accessibilityLabel("Save current mix")
                    } else {
                        Button(action: presentSavePreset) {
                            saveButtonLabel
                        }
                        .buttonStyle(HushPressButtonStyle())
                        .accessibilityLabel("Save current mix as preset")
                    }
                }

                Image(systemName: viewModel.showMixer ? "chevron.up" : "chevron.down")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(HushPalette.textSecondary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 20)

            if viewModel.showMixer {
                MixerView(viewModel: viewModel)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 12)
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            }
        }
        .hushPanel(fill: HushPalette.panelFillSoft)
    }

    // MARK: - Warning Banner (in place of the old stacked .alerts)

    @ViewBuilder
    private var warningBanner: some View {
        if let warning = viewModel.activeWarning {
            HushBanner(
                icon: warning.icon,
                title: warning.title,
                message: warning.message,
                accent: warning.accent
            ) {
                viewModel.dismissWarning()
            }
            .padding(.horizontal, 20)
            .padding(.top, 4)
            .padding(.bottom, 6)
            .transition(reduceMotion
                        ? .opacity
                        : .move(edge: .top).combined(with: .opacity))
        }
    }

    // MARK: - Fixed Transport Bar (always visible at bottom)

    private var transportBar: some View {
        VStack(spacing: 0) {
            // Gradient fade to make scroll content disappear under the bar
            LinearGradient(colors: [.clear, HushPalette.background.opacity(0.95)],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: 24)
                .allowsHitTesting(false)

            transportControls
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
                .background(HushPalette.background.opacity(0.95))
        }
    }

    /// Play/Pause with the timer chip beside it. At accessibility text
    /// sizes the chip drops below, so it never squeezes Play, which stays
    /// the dominant control.
    @ViewBuilder
    private var transportControls: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(spacing: 8) {
                playButton
                // Still large, but capped so the secondary control doesn't
                // double the height of a bar that never scrolls away.
                timerChip(minHeight: stackedTimerChipHeight)
                    .dynamicTypeSize(...DynamicTypeSize.accessibility2)
            }
        } else {
            HStack(spacing: 12) {
                playButton
                timerChip(minHeight: playButtonHeight)
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
    }

    private var playButton: some View {
        Button {
            viewModel.togglePlayback()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: viewModel.isPlaying ? "pause.fill" : "play.fill")
                    .font(.body.weight(.bold))
                    .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))

                Text(viewModel.isPlaying ? "Pause" : "Play")
                    .font(.body.weight(.semibold))
            }
            .foregroundStyle(viewModel.activeSources.isEmpty ? HushPalette.textSecondary : HushPalette.onAccent)
            .frame(maxWidth: .infinity)
            .frame(minHeight: playButtonHeight)
            .background(
                Capsule()
                    .fill(viewModel.activeSources.isEmpty ? HushPalette.surfaceRaised : HushPalette.accent)
            )
        }
        .buttonStyle(HushPrimaryButtonStyle())
        .disabled(viewModel.activeSources.isEmpty)
        .accessibilityLabel(viewModel.isPlaying ? "Pause" : "Play")
        .accessibilityHint(viewModel.activeSources.isEmpty
                           ? "Add a sound or choose a scene first"
                           : "")
    }

    private func timerChip(minHeight: CGFloat) -> some View {
        TimerChip(viewModel: viewModel, minHeight: minHeight) { choosingDuration in
            timerSheetChoosesDuration = choosingDuration
            viewModel.showTimer = true
        }
    }

    // MARK: - Undo Toast

    /// Identity of whichever toast is up, for the show/hide animation.
    private var undoToastID: UUID? {
        viewModel.lastRemovedLayer?.id ?? hiddenSceneUndo?.id
    }

    /// At most one toast. Each undoable action clears the other's record
    /// (newest wins), so the order here only matters within a frame.
    @ViewBuilder
    private var undoToast: some View {
        if let removed = viewModel.lastRemovedLayer {
            let name = removed.source.displayName
            UndoToast(
                id: removed.id,
                icon: removed.source.displayIcon,
                message: "Removed \(name)",
                announcement: "\(name) removed. Undo is available.",
                undoAccessibilityLabel: "Undo remove \(name)",
                onUndo: { undoRemoveLayer(removed) },
                onExpire: {
                    // Transient: the sound picker is the lasting way back.
                    guard viewModel.lastRemovedLayer?.id == removed.id else { return }
                    viewModel.discardRemovedLayer()
                }
            )
        } else if let hidden = hiddenSceneUndo {
            UndoToast(
                id: hidden.id,
                icon: "eye.slash",
                message: "\u{201C}\(hidden.preset.name)\u{201D} hidden",
                announcement: "\(hidden.preset.name) hidden. Undo is available.",
                undoAccessibilityLabel: "Undo hide \(hidden.preset.name)",
                onUndo: { undoHide(hidden) },
                onExpire: {
                    // Transient: Settings → Show Hidden Scenes is the
                    // lasting way back.
                    guard hiddenSceneUndo?.id == hidden.id else { return }
                    hiddenSceneUndo = nil
                }
            )
        }
    }

    private func showHiddenSceneUndo(for preset: Preset) {
        // Newest wins: a pending layer undo leaves with its toast.
        viewModel.discardRemovedLayer()
        hiddenSceneUndo = HiddenSceneUndo(
            preset: preset,
            wasLoaded: viewModel.currentPreset?.id == preset.id
        )
    }

    private func undoHide(_ undo: HiddenSceneUndo) {
        BuiltInSceneStore.unhide(undo.preset.id)
        // Hiding the loaded scene dropped it to "Custom Mix"; put it back.
        if undo.wasLoaded, viewModel.currentPreset == nil {
            viewModel.currentPreset = undo.preset
        }
        hiddenSceneUndo = nil
        AccessibilityNotification.Announcement("\(undo.preset.name) is back").post()
    }

    private func undoRemoveLayer(_ removed: RemovedLayer) {
        let name = removed.source.displayName
        if viewModel.undoRemoveLayer() {
            AccessibilityNotification.Announcement("\(name) is back").post()
        } else {
            // The mix filled up since the removal; the toast is gone either way.
            AccessibilityNotification.Announcement("The mix is full, so \(name) couldn't come back").post()
        }
    }

    // MARK: - Saving

    private var saveButtonLabel: some View {
        Image(systemName: "square.and.arrow.down")
            .font(.subheadline.weight(.medium))
            .foregroundStyle(HushPalette.textSecondary)
            .frame(width: saveButtonSize, height: saveButtonSize)
            .contentShape(Rectangle())
    }

    /// The loaded scene, when the mix has drifted from it and can be written
    /// back. Built-ins qualify too: the edit-save path stores the update as
    /// the scene's saved version, same as Edit Sounds does.
    private var updatableScene: Preset? {
        guard let preset = viewModel.currentPreset, viewModel.isCurrentPresetModified else { return nil }
        return preset
    }

    private func presentSavePreset() {
        presetName = defaultPresetName
        showSavePreset = true
    }

    private func updateCurrentScene() {
        guard var preset = updatableScene else { return }
        let sources = viewModel.activeSources
        let updated = ScenePersistence.saveEdited(
            preset,
            sources: sources,
            renamedBuiltIns: BuiltInSceneStore.renamed(),
            context: modelContext
        )
        // The scene's record is gone (deleted since it was loaded): saving
        // as new is the only way to keep this mix.
        guard updated else {
            presentSavePreset()
            return
        }
        // The loaded scene now matches what's playing, so it's no longer
        // "edited". Assigned directly: reloading would restart playback.
        preset.sources = sources
        viewModel.currentPreset = preset
        confirmSave("Updated \(preset.name)")
    }

    private func confirmSave(_ announcement: String) {
        saveFeedbackCount += 1
        AccessibilityNotification.Announcement(announcement).post()
    }

    // MARK: - First Run

    /// "Get Started" should land on a playing scene, not an empty mix with a
    /// disabled transport. Onboarding can't reach the view model, so it
    /// leaves a one-shot flag that the first PlayerView appearance consumes.
    private func startFirstSceneAfterOnboardingIfNeeded() {
        guard OnboardingHandoff.consumeStartFirstScene() else { return }
        let saved = (try? modelContext.fetch(
            FetchDescriptor<SavedPreset>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        )) ?? []
        let scenes = Preset.resolvedSceneList(
            saved: saved,
            hiddenIDs: Preset.hiddenBuiltInIDs(),
            renames: Preset.renamedBuiltIns()
        )
        guard let first = scenes.first else { return }
        viewModel.loadPreset(first)
    }

    // MARK: - Helpers

    private var currentTitle: String {
        if let preset = viewModel.currentPreset {
            return viewModel.isCurrentPresetModified ? "\(preset.name) (edited)" : preset.name
        }
        if !viewModel.activeSources.isEmpty { return "Custom Mix" }
        return "Choose a Scene"
    }

    /// Suggested preset name based on the active mix — keeps the save sheet
    /// from looking empty so the focus delay doesn't feel like a dead field.
    private var defaultPresetName: String {
        let names = viewModel.activeSources.map(\.displayName)
        switch names.count {
        case 0: return "My Mix"
        case 1, 2: return names.joined(separator: " + ")
        default: return "\(names[0]) + \(names.count - 1) more"
        }
    }

}

/// A scene the user just hid, kept while its Undo toast is on screen.
private struct HiddenSceneUndo: Identifiable {
    let id = UUID()
    let preset: Preset
    /// The hidden scene was the loaded one, so Undo restores the header too.
    let wasLoaded: Bool
}

private struct SavePresetSheet: View {
    @Binding var name: String
    @Binding var icon: String
    let iconChoices: [String]
    let onSave: () -> Void

    @Environment(\.dismiss) private var dismiss
    @FocusState private var nameFieldFocused: Bool
    @ScaledMetric(relativeTo: .body) private var iconSize: CGFloat = 44

    /// Adaptive, not a fixed 6 columns: six 44pt circles plus spacing
    /// overflowed 375pt phones and every accessibility text size.
    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: iconSize), spacing: 12)]
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespaces)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                HushBackdrop()

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 24) {
                        VStack(spacing: 16) {
                            ZStack {
                                Circle()
                                    .fill(HushPalette.surfaceRaised)
                                    .frame(width: 64, height: 64)
                                Image(systemName: icon)
                                    .font(.title2.weight(.semibold))
                                    .foregroundStyle(HushPalette.accent)
                            }

                            TextField("Preset name", text: $name)
                                .font(.title3.weight(.semibold))
                                .multilineTextAlignment(.center)
                                .foregroundStyle(HushPalette.textPrimary)
                                .focused($nameFieldFocused)
                        }
                        .padding(.top, 8)

                        VStack(alignment: .leading, spacing: 12) {
                            Text("Icon")
                                .font(.headline)
                                .foregroundStyle(HushPalette.textPrimary)

                            LazyVGrid(columns: columns, spacing: 12) {
                                ForEach(iconChoices, id: \.self) { choice in
                                    let selected = icon == choice
                                    Button {
                                        icon = choice
                                    } label: {
                                        Image(systemName: choice)
                                            .font(.body.weight(.semibold))
                                            .foregroundStyle(selected ? HushPalette.onAccent : HushPalette.textPrimary)
                                            .frame(width: iconSize, height: iconSize)
                                            .background(
                                                Circle()
                                                    .fill(selected ? HushPalette.accent : HushPalette.surfaceRaised)
                                            )
                                    }
                                    .buttonStyle(HushPressButtonStyle())
                                    .accessibilityLabel(HushSymbolName.label(for: choice))
                                    .accessibilityAddTraits(selected ? .isSelected : [])
                                }
                            }
                            .sensoryFeedback(.selection, trigger: icon)
                        }
                        .padding(20)
                        .hushPanel(fill: HushPalette.panelFillSoft)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                    .padding(.bottom, 28)
                }
                .scrollDismissesKeyboard(.immediately)
            }
            .navigationTitle("Save Preset")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(HushPalette.textSecondary)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { onSave() }
                        .fontWeight(.semibold)
                        .foregroundStyle(trimmedName.isEmpty ? HushPalette.textMuted : HushPalette.accentSoft)
                        .disabled(trimmedName.isEmpty)
                }
            }
            // Defer focus past the sheet presentation animation. The keyboard
            // snapshot done by UIKit when this field becomes first responder
            // mid-animation used to starve the audio render thread; the
            // 450ms delay was found by profiling on-device. `.defaultFocus`
            // is undocumented to defer past presentation, so we keep the
            // explicit delay until verified otherwise.
            .task {
                try? await Task.sleep(for: .milliseconds(450))
                nameFieldFocused = true
            }
        }
        .tint(HushPalette.accentSoft)
    }
}
