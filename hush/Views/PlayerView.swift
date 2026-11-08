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

    private static let iconChoices = [
        "star.fill", "heart.fill", "bolt.fill", "moon.fill", "leaf.fill",
        "flame.fill", "drop.fill", "brain.head.profile", "sparkles",
        "headphones", "music.note", "waveform.circle"
    ]

    @Environment(\.modelContext) private var modelContext
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @Environment(\.horizontalSizeClass) private var sizeClass

    @ScaledMetric(relativeTo: .title) private var playButtonHeight: CGFloat = 62
    @ScaledMetric(relativeTo: .subheadline) private var saveButtonSize: CGFloat = 44

    private var contentMaxWidth: CGFloat {
        sizeClass == .regular ? 600 : .infinity
    }

    var body: some View {
        NavigationStack {
            ZStack {
                HushBackdrop()

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 16) {
                        nowPlayingHeader
                        PresetSelector(
                            onSelect: { preset in viewModel.loadPreset(preset) },
                            onRandom: { viewModel.randomMix() },
                            onDelete: { preset in viewModel.handlePresetDeleted(preset) },
                            selectedPreset: viewModel.currentPreset,
                            isPlaying: viewModel.isPlaying,
                            onRename: { id, name in viewModel.handlePresetRenamed(id: id, newName: name) },
                            onHide: { preset in showHiddenSceneUndo(for: preset) }
                        )
                        mixerSection
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .frame(maxWidth: contentMaxWidth)
                    .frame(maxWidth: .infinity)
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    VStack(spacing: 0) {
                        if let hiddenSceneUndo {
                            hiddenSceneToast(hiddenSceneUndo)
                        }
                        transportBar
                    }
                    .frame(maxWidth: contentMaxWidth)
                    .frame(maxWidth: .infinity)
                }
                .safeAreaInset(edge: .top, spacing: 0) {
                    warningBanner
                        .frame(maxWidth: contentMaxWidth)
                        .frame(maxWidth: .infinity)
                }
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
            .sheet(isPresented: $viewModel.showTimer) {
                TimerView(viewModel: viewModel)
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

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            if viewModel.timerState.isRunning {
                Button { viewModel.showTimer = true } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "timer")
                            .font(.caption.weight(.bold))
                        Text(viewModel.timerState.displayTime)
                            .font(.caption.weight(.semibold))
                            .monospacedDigit()
                    }
                    .foregroundStyle(HushPalette.onAccent)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(HushPalette.accent))
                }
                .accessibilityLabel("Timer")
                .accessibilityValue(TimerSpeech.remaining(viewModel.timerState.remainingSeconds))
            } else {
                Button { viewModel.showTimer = true } label: {
                    Image(systemName: "timer")
                        .foregroundStyle(HushPalette.textSecondary)
                }
                .accessibilityLabel("Timer")
            }

            Button { viewModel.showSettings = true } label: {
                Image(systemName: "gearshape")
                    .foregroundStyle(HushPalette.textSecondary)
            }
            .accessibilityLabel("Settings")
        }
    }

    // MARK: - Now Playing (concise state, not marketing copy)

    private var nowPlayingHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(currentTitle)
                    .font(.system(.title, design: .serif, weight: .semibold))
                    .foregroundStyle(HushPalette.textPrimary)

                if !viewModel.activeSources.isEmpty {
                    Text(sourcesSummary)
                        .font(.subheadline)
                        .foregroundStyle(HushPalette.textSecondary)
                        .transition(.opacity)
                }
            }

            // Source chips — only when mix is loaded. The chips already carry
            // the "what's playing" signal, so we don't duplicate with a
            // separate Playing pill; the transport button's pause-state is the
            // canonical "are we playing" indicator.
            if !viewModel.activeSources.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(viewModel.activeSources.prefix(6)) { source in
                            HStack(spacing: 6) {
                                // Decorative: the name next to it says it all.
                                Image(systemName: source.displayIcon)
                                    .font(.caption2.weight(.bold))
                                    .accessibilityHidden(true)
                                Text(source.displayName)
                                    .font(.caption2.weight(.medium))
                            }
                            .foregroundStyle(HushPalette.textPrimary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(
                                Capsule()
                                    .fill(HushPalette.raisedFill)
                                    .overlay(Capsule().strokeBorder(HushPalette.outline, lineWidth: 1))
                            )
                        }
                    }
                }
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

            HStack(spacing: 14) {
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
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
            .background(HushPalette.background.opacity(0.95))
        }
    }

    // MARK: - Hidden Scene Undo Toast

    private func hiddenSceneToast(_ undo: HiddenSceneUndo) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "eye.slash")
                .font(.caption)
                .foregroundStyle(HushPalette.textSecondary)
                .accessibilityHidden(true)
            Text("\u{201C}\(undo.preset.name)\u{201D} hidden")
                .font(.footnote)
                .foregroundStyle(HushPalette.textPrimary)
            Spacer(minLength: 8)
            Button {
                undoHide(undo)
            } label: {
                Text("Undo")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(HushPalette.accentSoft)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(HushPressButtonStyle())
            .accessibilityLabel("Undo hide \(undo.preset.name)")
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
        // Transient: Settings → Show Hidden Scenes is the lasting way back.
        // VoiceOver users get longer to reach the button.
        .task(id: undo.id) {
            try? await Task.sleep(for: .seconds(voiceOverEnabled ? 12 : 5))
            guard !Task.isCancelled, hiddenSceneUndo?.id == undo.id else { return }
            withAnimation(reduceMotion ? nil : HushMotion.standard) {
                hiddenSceneUndo = nil
            }
        }
    }

    private func showHiddenSceneUndo(for preset: Preset) {
        let undo = HiddenSceneUndo(
            preset: preset,
            wasLoaded: viewModel.currentPreset?.id == preset.id
        )
        withAnimation(reduceMotion ? nil : HushMotion.standard) {
            hiddenSceneUndo = undo
        }
        AccessibilityNotification.Announcement("\(preset.name) hidden. Undo is available.").post()
    }

    private func undoHide(_ undo: HiddenSceneUndo) {
        BuiltInSceneStore.unhide(undo.preset.id)
        // Hiding the loaded scene dropped it to "Custom Mix"; put it back.
        if undo.wasLoaded, viewModel.currentPreset == nil {
            viewModel.currentPreset = undo.preset
        }
        withAnimation(reduceMotion ? nil : HushMotion.standard) {
            hiddenSceneUndo = nil
        }
        AccessibilityNotification.Announcement("\(undo.preset.name) is back").post()
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
        let scenes = SceneOrdering.ordered(
            saved: saved,
            stableID: \.stableID,
            toPreset: { $0.toPreset() },
            hidden: BuiltInSceneStore.hidden(),
            renamed: BuiltInSceneStore.renamed()
        )
        guard let first = scenes.first?.preset else { return }
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

    private var sourcesSummary: String {
        soundSourceSummary(viewModel.activeSources)
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
