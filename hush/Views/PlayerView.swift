import SwiftUI
import SwiftData

struct PlayerView: View {
    @Bindable var viewModel: PlayerViewModel
    @State private var showSavePreset = false
    @State private var presetName = ""
    @State private var presetIcon = "star.fill"

    private static let iconChoices = [
        "star.fill", "heart.fill", "bolt.fill", "moon.fill", "leaf.fill",
        "flame.fill", "drop.fill", "brain.head.profile", "sparkles",
        "headphones", "music.note", "waveform.circle"
    ]

    @Environment(\.modelContext) private var modelContext
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.horizontalSizeClass) private var sizeClass

    @ScaledMetric(relativeTo: .title) private var playButtonHeight: CGFloat = 62

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
                            selectedPreset: viewModel.currentPreset
                        )
                        mixerSection
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .frame(maxWidth: contentMaxWidth)
                    .frame(maxWidth: .infinity)
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    transportBar
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
            .tint(HushPalette.accentSoft)
            .sheet(isPresented: $viewModel.showTimer) {
                TimerView(viewModel: viewModel)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $viewModel.showSettings) {
                SettingsView(viewModel: viewModel)
            }
            .alert("Audio Error", isPresented: Binding(
                get: { viewModel.errorMessage != nil },
                set: { if !$0 { viewModel.errorMessage = nil } }
            )) {
                Button("OK") {}
            } message: {
                Text(viewModel.errorMessage ?? "")
            }
            .alert("Storage Error", isPresented: Binding(
                get: { viewModel.storageFailureMessage != nil },
                set: { if !$0 { viewModel.storageFailureMessage = nil } }
            )) {
                Button("OK") {}
            } message: {
                Text(viewModel.storageFailureMessage ?? "")
            }
            .sheet(isPresented: $showSavePreset) {
                SavePresetSheet(
                    name: $presetName,
                    icon: $presetIcon,
                    iconChoices: Self.iconChoices
                ) {
                    guard !presetName.isEmpty else { return }
                    viewModel.saveCurrentAsPreset(name: presetName, icon: presetIcon, context: modelContext)
                    presetName = ""
                    presetIcon = "star.fill"
                    showSavePreset = false
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
                    .foregroundStyle(Color.black)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(HushPalette.accent))
                }
                .accessibilityLabel("Timer")
                .accessibilityValue("\(viewModel.timerState.displayTime) remaining")
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
            HStack(alignment: .top) {
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

                Spacer()

                if viewModel.isPlaying {
                    HushInfoPill(icon: "waveform", text: "Playing", highlighted: true)
                        .accessibilityLabel("Now playing")
                        .transition(.opacity.combined(with: .scale(scale: 0.92)))
                }
            }

            // Source chips — only when mix is loaded
            if !viewModel.activeSources.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(viewModel.activeSources.prefix(6)) { source in
                            HStack(spacing: 6) {
                                Image(systemName: source.displayIcon)
                                    .font(.caption2.weight(.bold))
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
        .background(heroBackground)
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(HushPalette.outlineStrong, lineWidth: 1)
        )
    }

    // MARK: - Mixer Section (progressive disclosure, compact)

    private var mixerSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Customize")
                    .font(.headline)
                    .foregroundStyle(HushPalette.textPrimary)

                Spacer()

                HStack(spacing: 10) {
                    if !viewModel.activeSources.isEmpty {
                        Button {
                            presetName = defaultPresetName
                            showSavePreset = true
                        } label: {
                            Image(systemName: "square.and.arrow.down")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(HushPalette.textSecondary)
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(HushPressButtonStyle())
                        .accessibilityLabel("Save current mix as preset")
                    }

                    Image(systemName: viewModel.showMixer ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(HushPalette.textSecondary)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
            .onTapGesture {
                if reduceMotion {
                    viewModel.showMixer.toggle()
                } else {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        viewModel.showMixer.toggle()
                    }
                }
            }
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(viewModel.showMixer ? "Hide mixer" : "Show mixer")

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
                    .foregroundStyle(viewModel.activeSources.isEmpty ? HushPalette.textMuted : Color.black)
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
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
            .background(HushPalette.background.opacity(0.95))
        }
    }

    // MARK: - Hero Background

    private var heroBackground: some View {
        let colors = activePalette
        return RoundedRectangle(cornerRadius: 24, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [colors[0].opacity(0.5), colors[1].opacity(0.18), HushPalette.surface],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
    }

    // MARK: - Helpers

    private var currentTitle: String {
        if let preset = viewModel.currentPreset { return preset.name }
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

    private var activePalette: [Color] {
        let primaryType = viewModel.activeSources.first?.type ?? viewModel.currentPreset?.sources.first?.type
        switch primaryType {
        case .rain, .stream, .ocean:
            return [Color(red: 0.23, green: 0.36, blue: 0.42), Color(red: 0.12, green: 0.17, blue: 0.23)]
        case .birdsong, .wind:
            return [Color(red: 0.28, green: 0.40, blue: 0.31), Color(red: 0.12, green: 0.18, blue: 0.15)]
        case .fire, .thunder:
            return [Color(red: 0.44, green: 0.27, blue: 0.18), Color(red: 0.18, green: 0.11, blue: 0.10)]
        case .speechMasking:
            return [Color(red: 0.30, green: 0.33, blue: 0.38), Color(red: 0.14, green: 0.16, blue: 0.20)]
        case .binauralBeats, .isochronicTones, .monauralBeats, .pureTone, .drone:
            return [Color(red: 0.31, green: 0.25, blue: 0.44), Color(red: 0.16, green: 0.12, blue: 0.23)]
        case .whiteNoise, .pinkNoise, .brownNoise, .grayNoise:
            return [Color(red: 0.33, green: 0.32, blue: 0.28), Color(red: 0.16, green: 0.15, blue: 0.13)]
        case .sampleAsset:
            return [Color(red: 0.25, green: 0.30, blue: 0.35), Color(red: 0.13, green: 0.15, blue: 0.18)]
        case .none:
            return [HushPalette.accentGlow, HushPalette.surfaceRaised]
        }
    }
}

private struct SavePresetSheet: View {
    @Binding var name: String
    @Binding var icon: String
    let iconChoices: [String]
    let onSave: () -> Void

    @Environment(\.dismiss) private var dismiss
    @FocusState private var nameFieldFocused: Bool

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 6)

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
                                            .foregroundStyle(selected ? Color.black : HushPalette.textPrimary)
                                            .frame(width: 44, height: 44)
                                            .background(
                                                Circle()
                                                    .fill(selected ? HushPalette.accent : HushPalette.surfaceRaised)
                                            )
                                    }
                                    .buttonStyle(HushPressButtonStyle())
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
                        .foregroundStyle(name.isEmpty ? HushPalette.textMuted : HushPalette.accentSoft)
                        .disabled(name.isEmpty)
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
