import Accessibility
import SwiftUI
import UniformTypeIdentifiers

extension SoundSource {
    var subtitle: String {
        switch type {
        case .binauralBeats, .isochronicTones, .monauralBeats:
            return binauralRange?.description ?? "Generated live"
        case .speechMasking:
            let pct = Int((maskingStrength ?? 0.5) * 100)
            return "Strength: \(pct)%"
        case .pureTone, .drone:
            if let freq = toneFrequency { return "\(Int(freq)) Hz" }
            return "432 Hz"
        case .sampleAsset:
            if let asset = resolvedAsset {
                return asset.category.rawValue
            }
            return "Recorded loop"
        default:
            return type.isGenerated ? "Generated live" : "Recorded loop"
        }
    }
}

struct MixerView: View {
    @Bindable var viewModel: PlayerViewModel
    @State private var showAddSound = false

    var body: some View {
        VStack(spacing: 14) {
            if viewModel.activeSources.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "waveform.badge.plus")
                        .font(.title2)
                        .foregroundStyle(HushPalette.textSecondary)

                    Text("Empty mix")
                        .font(.headline)
                        .foregroundStyle(HushPalette.textPrimary)

                    Text("Add a sound to start.")
                        .font(.subheadline)
                        .foregroundStyle(HushPalette.textSecondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            } else {
                // Keyed on the mix, so a scene swap replaces the rows in one
                // cut instead of fading the old set over the new.
                VStack(spacing: 14) {
                    ForEach(viewModel.activeSources) { source in
                        SourceRow(source: source, viewModel: viewModel)
                    }
                }
                .id(viewModel.mixGeneration)
                .transition(.asymmetric(insertion: .opacity, removal: .identity))
            }

            if viewModel.activeSources.count < AudioConstants.maxSimultaneousSources {
                Button {
                    showAddSound = true
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "plus")
                            .font(.subheadline.weight(.bold))
                        Text("Layer another sound")
                            .font(.subheadline.weight(.semibold))
                    }
                    .foregroundStyle(HushPalette.textPrimary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(
                        RoundedRectangle(cornerRadius: HushRadius.md, style: .continuous)
                            .fill(HushPalette.surfaceRaised.opacity(0.76))
                            .overlay(
                                RoundedRectangle(cornerRadius: HushRadius.md, style: .continuous)
                                    .strokeBorder(HushPalette.outline, style: StrokeStyle(lineWidth: 1, dash: [7, 7]))
                            )
                    )
                }
                .buttonStyle(HushPressButtonStyle())
            } else {
                // At the cap: say so instead of silently hiding the add
                // button — users never learned the limit existed.
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle")
                        .font(.subheadline.weight(.bold))
                    Text("Mix is full — \(AudioConstants.maxSimultaneousSources) of \(AudioConstants.maxSimultaneousSources) sounds")
                        .font(.subheadline.weight(.semibold))
                }
                .foregroundStyle(HushPalette.textSecondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .accessibilityElement(children: .combine)
            }
        }
        .sheet(isPresented: $showAddSound) {
            SoundPickerGrid(activeSources: viewModel.activeSources) { type in
                viewModel.addSource(type)
            } onSelectAsset: { asset in
                viewModel.addAsset(asset)
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
    }
}

private struct SourceRow: View {
    let source: SoundSource
    let viewModel: PlayerViewModel
    @Environment(UserSoundLibrary.self) private var library
    @State private var volume: Float
    @State private var maskingStrength: Float
    @State private var showRelinkPicker = false
    @State private var relinkError: String?

    init(source: SoundSource, viewModel: PlayerViewModel) {
        self.source = source
        self.viewModel = viewModel
        _volume = State(initialValue: source.volume)
        _maskingStrength = State(initialValue: source.maskingStrength ?? 0.5)
    }

    /// The backing user asset, if any, and whether its file is missing.
    private var missingUserAsset: UserSoundAsset? {
        guard let id = source.assetID,
              let uuid = UserSoundAsset.uuid(fromAssetID: id),
              let record = library.assetsByID[uuid],
              record.isMissing else { return nil }
        return record
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                // Identity block combined into ONE VoiceOver stop announcing
                // name + subtitle + current level. Scoped to exclude the
                // Remove button (a combine over the whole header would
                // swallow it) and skipped entirely for missing assets so the
                // relink button stays individually actionable.
                HStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(HushPalette.raisedFill)
                            .frame(width: 42, height: 42)

                        Image(systemName: source.displayIcon)
                            .font(.headline)
                            .foregroundStyle(missingUserAsset != nil ? HushPalette.danger : HushPalette.textPrimary)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text(source.displayName)
                            .font(.headline)
                            .foregroundStyle(HushPalette.textPrimary)

                        if let missing = missingUserAsset {
                            Button {
                                showRelinkPicker = true
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                    Text("Missing — tap to relink")
                                }
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(HushPalette.danger)
                                .frame(minHeight: 44)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Relink \(missing.displayName)")

                            if let relinkError {
                                Text(relinkError)
                                    .font(.caption2)
                                    .foregroundStyle(HushPalette.danger)
                            }
                        } else {
                            Text(source.subtitle)
                                .font(.caption)
                                .foregroundStyle(HushPalette.textSecondary)
                        }
                    }
                }
                .accessibilityElement(children: missingUserAsset == nil ? .combine : .contain)
                .accessibilityValue(missingUserAsset == nil ? "\(Int(volume * 100)) percent" : "")

                Spacer()

                Text("\(Int(volume * 100))%")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(HushPalette.textSecondary)
                    .monospacedDigit()
                    .accessibilityHidden(true)

                Button {
                    viewModel.removeSource(source)
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.bold))
                }
                .buttonStyle(HushCircleButtonStyle())
                .accessibilityLabel("Remove \(source.displayName)")
            }

            Slider(value: $volume, in: 0...1)
            .tint(HushPalette.accentSoft)
            .onChange(of: volume) {
                // Skip the echo of a sync from the view model below.
                guard volume != source.volume else { return }
                viewModel.updateVolume(for: source, volume: volume)
            }
            .accessibilityLabel("\(source.displayName) volume")
            .accessibilityValue("\(Int(volume * 100)) percent")
            .sensoryFeedback(.selection, trigger: Int(volume * 10))

            if isToneType {
                ToneFrequencyPicker(selected: source.toneFrequency) { freq in
                    viewModel.updateToneFrequency(for: source, frequency: freq)
                }
            }

            if isBinauralType {
                BinauralRangePicker(selected: source.binauralRange) { range in
                    viewModel.updateBinaural(for: source, range: range, frequency: range.defaultFrequency)
                }
            }

            if source.type == .speechMasking {
                MaskingStrengthSlider(strength: $maskingStrength)
                    .onChange(of: maskingStrength) {
                        guard maskingStrength != (source.maskingStrength ?? 0.5) else { return }
                        viewModel.updateMaskingStrength(for: source, strength: maskingStrength)
                    }
            }
        }
        .padding(18)
        .hushPanel(radius: HushRadius.lg)
        // The local @State keeps dragging smooth, but it only seeds once per
        // row identity. Presets reuse source UUIDs, so reloading one keeps
        // this row alive with a new level: follow the view model's value.
        .onChange(of: source.volume) { _, newValue in
            if volume != newValue { volume = newValue }
        }
        .onChange(of: source.maskingStrength) { _, newValue in
            let strength = newValue ?? 0.5
            if maskingStrength != strength { maskingStrength = strength }
        }
        .fileImporter(
            isPresented: $showRelinkPicker,
            allowedContentTypes: [.audio],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let url = urls.first,
                  let asset = missingUserAsset else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                try library.relink(asset, to: url)
                relinkError = nil
                // One relink path for every entry point (here and Settings →
                // Imported Sounds): the view model re-attaches every layer
                // using this asset and clears the missing banner.
                viewModel.handleUserAssetRelinked(assetID: asset.assetID)
            } catch {
                // Validation failures (too large, wrong format…) used to be
                // swallowed by try? — the tap just did nothing.
                let message = (error as? UserSoundImportError)?.errorDescription
                    ?? "Couldn't relink this file."
                relinkError = message
                AccessibilityNotification.Announcement(message).post()
            }
        }
    }

    private var isToneType: Bool {
        source.type == .pureTone || source.type == .drone
    }

    private var isBinauralType: Bool {
        [.binauralBeats, .isochronicTones, .monauralBeats].contains(source.type)
    }
}

struct SoundPickerGrid: View {
    let activeSources: [SoundSource]
    let onSelect: (SoundType) -> Void
    let onSelectAsset: (SoundAsset) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(UserSoundLibrary.self) private var library
    @State private var expandedCategories: Set<SoundCategory> = []
    @State private var showFileImporter = false
    @State private var pendingImportURL: ImportURL?
    @State private var importerError: String?
    @State private var searchQuery = ""
    @State private var preview = SoundPreviewPlayer()
    @State private var recents = RecentSounds()

    private var columns: [GridItem] {
        // One column at accessibility sizes: two cards side by side on a
        // 375pt phone left titles a word or two per line.
        let count = dynamicTypeSize.isAccessibilitySize ? 1 : (sizeClass == .regular ? 3 : 2)
        return Array(repeating: GridItem(.flexible(), spacing: 14), count: count)
    }

    private var activeAssetIDs: Set<String> {
        SoundSearch.activeAssetIDs(in: activeSources)
    }

    private var isSearching: Bool {
        !SoundSearch.normalized(searchQuery).isEmpty
    }

    private var activeGeneratedTypes: Set<SoundType> {
        Set(activeSources.map(\.type).filter(\.isGenerated))
    }

    private var availableGenerated: [SoundType] {
        SoundType.allCases.filter { $0.isGenerated && $0 != .sampleAsset && !activeGeneratedTypes.contains($0) }
    }

    /// Categories that have at least one non-active asset (bundled only —
    /// user imports are surfaced in their own section so they're easy to find).
    private var categoriesWithAssets: [SoundCategory] {
        SoundCategory.allCases.filter { cat in
            SoundAssetRegistry.bundled.contains { $0.category == cat && !activeAssetIDs.contains($0.id) }
        }
    }

    private var availableUserAssets: [SoundAsset] {
        library.allSoundAssets.filter { !activeAssetIDs.contains($0.id) }
    }

    /// Recent entries that still resolve and aren't in the mix. Reads user
    /// imports through the environment library so the row follows deletes.
    private var visibleRecents: [PickerSound] {
        recents.visible(excluding: activeSources) { id in
            library.asset(withID: id) ?? SoundAssetRegistry.asset(withID: id)
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                HushBackdrop()

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 24) {
                        if isSearching {
                            // Matches across every category in one flat,
                            // already-expanded grid.
                            searchResultsSection
                        } else {
                            recentSection

                            mySoundsSection

                            // Generated section
                            soundSection(
                                title: "Generated",
                                subtitle: "Noise and tones created live on this device",
                                sounds: availableGenerated
                            )

                            // Sample categories
                            ForEach(categoriesWithAssets) { category in
                                categorySection(category)
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                    .padding(.bottom, 28)
                }
                .scrollDismissesKeyboard(.immediately)
                .sensoryFeedback(.impact(weight: .light), trigger: preview.previewingID) { _, new in
                    new != nil
                }

                if let importerError {
                    VStack {
                        Spacer()
                        HStack(spacing: 10) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(HushPalette.danger)
                            Text(importerError)
                                .font(.footnote)
                                .foregroundStyle(HushPalette.textPrimary)
                            Spacer(minLength: 8)
                            Button {
                                withAnimation(HushMotion.quick) { self.importerError = nil }
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(HushPalette.textSecondary)
                                    .frame(width: 44, height: 44)
                                    .contentShape(Rectangle())
                            }
                            .accessibilityLabel("Dismiss error")
                        }
                        .padding(.leading, 14)
                        .padding(.vertical, 4)
                        .padding(.trailing, 4)
                        .hushPanel(radius: HushRadius.sm)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 24)
                    }
                    .transition(.opacity)
                }
            }
            .navigationTitle("Add Sound")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(
                text: $searchQuery,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "Search sounds"
            )
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        preview.stop()
                        dismiss()
                    }
                    .foregroundStyle(HushPalette.textPrimary)
                }
            }
            .fileImporter(
                isPresented: $showFileImporter,
                allowedContentTypes: [.audio],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    if let first = urls.first { pendingImportURL = ImportURL(url: first) }
                case .failure(let error):
                    flashError(error.localizedDescription)
                }
            }
            .sheet(item: $pendingImportURL) { wrap in
                ImportSoundSheet(mode: .newImport(sourceURL: wrap.url), library: library) { newAsset in
                    // Auto-add the freshly imported sound and dismiss the
                    // picker — user shouldn't have to find it in the list.
                    if let resolved = library.asset(withID: newAsset.assetID) {
                        add(.asset(resolved))
                    }
                }
            }
            // Swipe-down and the add paths all end here; the explicit stops
            // above just make Done and adding cut the preview immediately.
            .onDisappear { preview.stop() }
        }
        .tint(HushPalette.accentSoft)
    }

    // MARK: - Cards

    /// Every card in the picker, so Recent, My Sounds, search results and
    /// the category grids share one add path, one preview path and one look.
    @ViewBuilder
    private func card(_ sound: PickerSound, tag: String) -> some View {
        let isMissing = isMissingImport(sound)
        let previewAsset: SoundAsset? = {
            guard case .asset(let asset) = sound, !isMissing else { return nil }
            return asset
        }()
        let isPreviewing = previewAsset != nil && preview.previewingID == sound.id

        let button = Button { add(sound) } label: {
            SoundCardLabel(
                icon: sound.icon,
                title: sound.title,
                tag: tag,
                isPreviewing: isPreviewing,
                isMissing: isMissing
            )
        }
        .accessibilityLabel(sound.title)
        .accessibilityValue(isPreviewing ? "Previewing" : (isMissing ? "File missing" : tag))

        if let previewAsset {
            button
                .buttonStyle(SoundCardButtonStyle { togglePreview(previewAsset) })
                .accessibilityAction(named: isPreviewing ? "Stop preview" : "Preview") {
                    togglePreview(previewAsset)
                }
        } else {
            // Generated sounds and missing imports: no preview, plain button.
            button.buttonStyle(HushPressButtonStyle())
        }
    }

    private func add(_ sound: PickerSound) {
        Self.add(sound, preview: preview, recents: recents,
                 onSelect: onSelect, onSelectAsset: onSelectAsset)
        dismiss()
    }

    private func togglePreview(_ asset: SoundAsset) {
        let announcement: String
        switch preview.toggle(asset) {
        case .started: announcement = "Previewing \(asset.displayName)"
        case .stopped: announcement = "Preview stopped"
        case .unavailable: announcement = "No preview for \(asset.displayName)"
        }
        AccessibilityNotification.Announcement(announcement).post()
    }

    /// A user import whose file is gone. Same test as the mixer row (the
    /// library's flag), plus a live check for files removed since `verify()`.
    private func isMissingImport(_ sound: PickerSound) -> Bool {
        guard case .asset(let asset) = sound, asset.isUserImported else { return false }
        if let uuid = UserSoundAsset.uuid(fromAssetID: asset.id),
           library.assetsByID[uuid]?.isMissing == true {
            return true
        }
        return asset.resolvedURL == nil
    }

    // MARK: - Recent

    @ViewBuilder private var recentSection: some View {
        let sounds = visibleRecents
        if !sounds.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Recent")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(HushPalette.textPrimary)
                        .accessibilityAddTraits(.isHeader)

                    Text("Sounds you've added lately")
                        .font(.subheadline)
                        .foregroundStyle(HushPalette.textSecondary)
                }

                // A swipeable row rather than a grid, so up to 8 recents
                // don't push the rest of the picker below the medium detent.
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 14) {
                        ForEach(sounds) { sound in
                            card(sound, tag: recentTag(for: sound))
                                .containerRelativeFrame(.horizontal) { length, _ in
                                    recentCardWidth(in: length)
                                }
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollTargetBehavior(.viewAligned)
                // Bleed to the sheet edges while the first card stays
                // aligned with the section title.
                .contentMargins(.horizontal, 20, for: .scrollContent)
                .padding(.horizontal, -20)
            }
        }
    }

    /// The tag the card carries in its home section; bundled sounds show
    /// their category since the row mixes categories.
    private func recentTag(for sound: PickerSound) -> String {
        switch sound {
        case .generated: return "Generated"
        case .asset(let asset): return asset.isUserImported ? "Imported" : asset.category.rawValue
        }
    }

    /// Cards sized like the grid's, with the next one peeking in so the
    /// row reads as scrollable.
    private func recentCardWidth(in length: CGFloat) -> CGFloat {
        let visible: CGFloat = dynamicTypeSize.isAccessibilitySize ? 1.15 : (sizeClass == .regular ? 3.3 : 2.2)
        return (length - 14 * visible.rounded(.down)) / visible
    }

    // MARK: - My Sounds (user imports)

    @ViewBuilder private var mySoundsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("My Sounds")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(HushPalette.textPrimary)

                Text("Audio you've imported from your device")
                    .font(.subheadline)
                    .foregroundStyle(HushPalette.textSecondary)
            }

            LazyVGrid(columns: columns, spacing: 14) {
                Button {
                    preview.stop()
                    showFileImporter = true
                } label: {
                    SoundCardLabel(
                        icon: "plus",
                        iconTint: HushPalette.accentSoft,
                        iconDashed: true,
                        title: "Import sound",
                        tag: "Pick a file from your device"
                    )
                }
                .buttonStyle(HushPressButtonStyle())

                ForEach(availableUserAssets) { asset in
                    card(.asset(asset), tag: "Imported")
                }
            }
        }
    }

    // MARK: - Search results

    @ViewBuilder private var searchResultsSection: some View {
        let query = SoundSearch.normalized(searchQuery)
        let userMatches = SoundSearch.filter(availableUserAssets, query: query)
        let generatedMatches = availableGenerated.filter { SoundSearch.matches($0.rawValue, query: query) }
        let recordedMatches = SoundSearch.filter(
            SoundAssetRegistry.bundled.filter { !activeAssetIDs.contains($0.id) },
            query: query
        )
        let total = userMatches.count + generatedMatches.count + recordedMatches.count

        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Results")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(HushPalette.textPrimary)

                Text(total == 0
                     ? "No sounds match \u{201C}\(query)\u{201D}"
                     : "\(total) sound\(total == 1 ? "" : "s")")
                    .font(.subheadline)
                    .foregroundStyle(HushPalette.textSecondary)
            }
            .accessibilityElement(children: .combine)

            if total > 0 {
                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(userMatches) { asset in
                        card(.asset(asset), tag: "Imported")
                    }

                    ForEach(generatedMatches) { type in
                        card(.generated(type), tag: "Generated")
                    }

                    ForEach(recordedMatches) { asset in
                        card(.asset(asset), tag: asset.category.rawValue)
                    }
                }
            }
        }
    }

    private func flashError(_ message: String) {
        withAnimation(HushMotion.quick) {
            importerError = message
        }
        // The banner is visual-only; without this a VoiceOver user picking
        // an unreadable file hears nothing at all.
        AccessibilityNotification.Announcement(message).post()
        // No auto-dismiss — users may need time to read, and screen-reader
        // users were cut off by the old 3-second timer. The inline dismiss
        // button in the banner is the clear path out.
    }

    @ViewBuilder
    private func categorySection(_ category: SoundCategory) -> some View {
        // Bundled-only here — user imports live in the My Sounds section so
        // they don't get scattered across categories.
        let assets = SoundAssetRegistry.bundled.filter {
            $0.category == category && !activeAssetIDs.contains($0.id)
        }
        let isExpanded = expandedCategories.contains(category)

        VStack(alignment: .leading, spacing: 14) {
            Button {
                withAnimation(reduceMotion ? nil : HushMotion.standard) {
                    if isExpanded {
                        expandedCategories.remove(category)
                    } else {
                        expandedCategories.insert(category)
                    }
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: category.icon)
                        .font(.title3)
                        .foregroundStyle(HushPalette.accentSoft)
                        .frame(width: 28)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(category.rawValue)
                            .font(.headline)
                            .foregroundStyle(HushPalette.textPrimary)

                        Text("\(assets.count) sound\(assets.count == 1 ? "" : "s")")
                            .font(.caption)
                            .foregroundStyle(HushPalette.textSecondary)
                    }

                    Spacer()

                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(HushPalette.textSecondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
            }
            .buttonStyle(HushPressButtonStyle())
            // The chevron rotation is the only expanded/collapsed signal —
            // invisible to VoiceOver without an explicit value.
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")

            if isExpanded {
                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(assets) { asset in
                        card(.asset(asset), tag: "Recorded")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func soundSection(title: String, subtitle: String, sounds: [SoundType]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(HushPalette.textPrimary)

                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(HushPalette.textSecondary)
            }

            LazyVGrid(columns: columns, spacing: 14) {
                ForEach(sounds) { type in
                    card(.generated(type), tag: "Generated")
                }
            }
        }
    }
}

extension SoundPickerGrid {
    /// The one add path behind every card: end the preview, remember the
    /// sound for the Recent row, hand it to the caller. Static so tests can
    /// drive it without a view.
    static func add(
        _ sound: PickerSound,
        preview: SoundPreviewPlayer,
        recents: RecentSounds,
        onSelect: (SoundType) -> Void,
        onSelectAsset: (SoundAsset) -> Void
    ) {
        preview.stop()
        recents.record(sound)
        switch sound {
        case .generated(let type): onSelect(type)
        case .asset(let asset): onSelectAsset(asset)
        }
    }
}

/// Grid card used across the sound picker (imports, bundled assets, generated
/// types). One shape, one padding, one panel radius — new rows shouldn't
/// invent their own card treatment.
private struct SoundCardLabel: View {
    let icon: String
    var iconTint: Color = HushPalette.textPrimary
    var iconDashed: Bool = false
    let title: String
    let tag: String
    /// Long-press preview playing: animated waveform, "Previewing" tag and
    /// an accent outline, so it never relies on motion or color alone.
    var isPreviewing = false
    /// User import whose file is gone — same danger treatment as the
    /// mixer row's "Missing — tap to relink".
    var isMissing = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .headline) private var iconSize: CGFloat = 42

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ZStack {
                if iconDashed {
                    Circle()
                        .strokeBorder(HushPalette.outline, style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                } else {
                    Circle()
                        .fill(isPreviewing ? HushPalette.chipActive : HushPalette.raisedFill)
                }
                Image(systemName: isPreviewing ? "waveform" : icon)
                    .font(.headline)
                    .foregroundStyle(iconColor)
                    // Static under Reduce Motion; the tag still says so.
                    .symbolEffect(
                        .variableColor.iterative.dimInactiveLayers,
                        options: .repeating,
                        isActive: isPreviewing && !reduceMotion
                    )
                    .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
            }
            .frame(width: iconSize, height: iconSize)
            .accessibilityHidden(true)

            Text(title)
                .font(.headline)
                .foregroundStyle(HushPalette.textPrimary)
                .multilineTextAlignment(.leading)
                .lineLimit(2)

            if isPreviewing {
                Text("Previewing")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(HushPalette.accentSoft)
            } else if isMissing {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text("Missing file")
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(HushPalette.danger)
            } else {
                Text(tag)
                    .font(.caption)
                    .foregroundStyle(HushPalette.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 142, alignment: .leading)
        .padding(16)
        .hushPanel(radius: HushRadius.lg)
        .overlay(
            RoundedRectangle(cornerRadius: HushRadius.lg, style: .continuous)
                .strokeBorder(HushPalette.accentSoft, lineWidth: 1.5)
                .opacity(isPreviewing ? 1 : 0)
        )
        .animation(reduceMotion ? nil : HushMotion.quick, value: isPreviewing)
    }

    private var iconColor: Color {
        if isPreviewing { return HushPalette.accentSoft }
        if isMissing { return HushPalette.danger }
        return iconTint
    }
}

// MARK: - Shared Pickers
//
// One set of controls used by both MixerView (live engine updates) and
// EditPresetSheet (local state). Callers own the state and the write path.

/// Shared chip style for picker rows (also reused by ImportSoundSheet).
/// Target height is 44pt to satisfy WCAG 2.5.8. Selection is never shown by
/// color alone: the selected chip also carries a checkmark and an outline.
/// Callers add the `.isSelected` trait on the Button.
struct HushChipLabel: View {
    let text: String
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 5) {
            if isSelected {
                Image(systemName: "checkmark")
                    .font(.caption2.weight(.bold))
                    .accessibilityHidden(true)
            }
            Text(text)
                .font(.footnote.weight(.semibold))
        }
        .foregroundStyle(isSelected ? HushPalette.textPrimary : HushPalette.textSecondary)
        .padding(.horizontal, 14)
        .frame(minHeight: 44)
        .background(
            Capsule()
                .fill(isSelected ? HushPalette.chipActive : HushPalette.chipMuted)
                .overlay(
                    Capsule()
                        .strokeBorder(isSelected ? HushPalette.accentSoft : Color.clear, lineWidth: 1)
                )
        )
    }
}

struct ToneFrequencyPicker: View {
    let selected: Float?
    let onSelect: (Float) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(TonePreset.allCases) { preset in
                    let isSelected = selected == preset.frequency
                    Button { onSelect(preset.frequency) } label: {
                        HushChipLabel(text: preset.label, isSelected: isSelected)
                    }
                    .buttonStyle(HushPressButtonStyle())
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                    .animation(reduceMotion ? nil : HushMotion.quick, value: selected)
                }
            }
        }
        .sensoryFeedback(.selection, trigger: selected)
    }
}

struct BinauralRangePicker: View {
    let selected: BinauralRange?
    let onSelect: (BinauralRange) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(BinauralRange.allCases) { range in
                    let isSelected = selected == range
                    Button { onSelect(range) } label: {
                        HushChipLabel(text: range.rawValue, isSelected: isSelected)
                    }
                    .buttonStyle(HushPressButtonStyle())
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                    .animation(reduceMotion ? nil : HushMotion.quick, value: selected)
                }
            }
        }
        .sensoryFeedback(.selection, trigger: selected)
    }
}

struct MaskingStrengthSlider: View {
    @Binding var strength: Float

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Masking strength")
                    .font(.caption)
                    .foregroundStyle(HushPalette.textSecondary)
                Spacer()
                Text("\(Int(strength * 100))%")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(HushPalette.textSecondary)
                    .monospacedDigit()
            }
            Slider(value: $strength, in: 0...1)
            .tint(HushPalette.accentSoft)
            .accessibilityLabel("Masking strength")
            .accessibilityValue("\(Int(strength * 100)) percent")
        }
        // Subtle click every 10% during drag — matches TimerView's per-detent
        // model so the haptic language is consistent across sliders.
        .sensoryFeedback(.selection, trigger: Int(strength * 10))
    }
}

// MARK: - Sound picker search

/// Pure helpers behind the "Add Sound" picker: which assets are already in
/// the mix, and the search filter.
enum SoundSearch {
    /// Assets already layered, so the picker doesn't offer them twice.
    /// Legacy-typed sources (`.rain`, `.ocean`…) carry no `assetID` but play
    /// their type's default asset, so they count too.
    static func activeAssetIDs(in sources: [SoundSource]) -> Set<String> {
        Set(sources.compactMap { $0.assetID ?? $0.type.defaultAssetID })
    }

    static func normalized(_ query: String) -> String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Case- and diacritic-insensitive substring match. An empty query
    /// matches everything.
    static func matches(_ name: String, query: String) -> Bool {
        let query = normalized(query)
        guard !query.isEmpty else { return true }
        return name.localizedStandardContains(query)
    }

    static func filter(_ assets: [SoundAsset], query: String) -> [SoundAsset] {
        assets.filter { matches($0.displayName, query: query) }
    }
}
