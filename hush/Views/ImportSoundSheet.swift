@preconcurrency import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

/// Sheet shown after the user picks a file (or taps Edit on an existing
/// import). Lets them name the sound, pick a category and icon, and toggle
/// crossfading. Also handles the actual `library.importSound` /
/// `library.update` call so callers don't have to.
struct ImportSoundSheet: View {
    enum Mode {
        /// Importing a brand-new file. The URL is security-scoped from
        /// `.fileImporter` and the sheet handles `start/stopAccessing...`.
        case newImport(sourceURL: URL)
        /// Editing an already-imported asset (rename, recategorize, change
        /// crossfade settings).
        case edit(asset: UserSoundAsset)
    }

    let mode: Mode
    let library: UserSoundLibrary
    var onComplete: ((UserSoundAsset) -> Void)? = nil

    @Environment(\.dismiss) private var dismiss

    @State private var displayName: String = ""
    @State private var category: SoundCategory = .things
    @State private var iconOverride: String? = nil
    @State private var crossfadeEnabled: Bool = true
    @State private var crossfadeDurationMs: Int = 100

    @State private var isPreviewing = false
    @State private var previewError: String?
    @State private var importError: String?
    @State private var isWorking = false

    @State private var previewPlayer: AVAudioPlayer?
    /// Retained so the AVAudioPlayer delegate (which AVFoundation holds
    /// weakly) stays alive long enough to fire `audioPlayerDidFinishPlaying`.
    @State private var previewObserver: PreviewObserver?

    private static let iconChoices: [String] = [
        "music.note", "waveform", "speaker.wave.2.fill", "headphones",
        "mic.fill", "leaf.fill", "drop.fill", "flame.fill",
        "moon.fill", "sun.max.fill", "cloud.fill", "sparkles"
    ]

    private static let crossfadeOptions: [(label: String, ms: Int)] = [
        ("50ms", 50), ("100ms", 100), ("300ms", 300)
    ]

    var body: some View {
        NavigationStack {
            ZStack {
                HushBackdrop()

                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        previewSection
                        nameSection
                        categorySection
                        iconSection
                        crossfadeSection
                        limitationNote

                        if let importError {
                            Text(importError)
                                .font(.caption)
                                .foregroundStyle(HushPalette.danger)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 20)
                    .padding(.bottom, 40)
                }
            }
            .navigationTitle(isEditing ? "Edit Sound" : "Import Sound")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { cancelAndDismiss() }
                        .foregroundStyle(HushPalette.textSecondary)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isEditing ? "Save" : "Import", action: commit)
                        .fontWeight(.semibold)
                        .foregroundStyle(canSubmit ? HushPalette.accentSoft : HushPalette.textMuted)
                        .disabled(!canSubmit || isWorking)
                }
            }
            .onAppear(perform: hydrateFromMode)
            .onDisappear(perform: stopPreview)
        }
        .tint(HushPalette.accentSoft)
    }

    // MARK: - Sections

    @ViewBuilder private var previewSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Preview")
                .font(.caption.weight(.semibold))
                .textCase(.uppercase)
                .foregroundStyle(HushPalette.textSecondary)

            HStack(spacing: 14) {
                Button(action: togglePreview) {
                    Image(systemName: isPreviewing ? "stop.fill" : "play.fill")
                        .font(.title3)
                        .foregroundStyle(HushPalette.textPrimary)
                        .frame(width: 48, height: 48)
                        .background(Circle().fill(HushPalette.raisedFill))
                }
                .buttonStyle(HushPressButtonStyle())
                .accessibilityLabel(isPreviewing ? "Stop preview" : "Play preview")

                VStack(alignment: .leading, spacing: 2) {
                    Text(isPreviewing ? "Playing" : "Tap to hear a snippet")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(HushPalette.textPrimary)
                    if let previewError {
                        Text(previewError)
                            .font(.caption)
                            .foregroundStyle(HushPalette.danger)
                    } else {
                        Text("Plays at low volume so you can confirm the file.")
                            .font(.caption)
                            .foregroundStyle(HushPalette.textSecondary)
                    }
                }
                Spacer()
            }
            .padding(14)
            .hushPanel(radius: 20)
        }
    }

    @ViewBuilder private var nameSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Name")
                .font(.caption.weight(.semibold))
                .textCase(.uppercase)
                .foregroundStyle(HushPalette.textSecondary)

            TextField("Sound name", text: $displayName)
                .textFieldStyle(.plain)
                .font(.title3.weight(.semibold))
                .foregroundStyle(HushPalette.textPrimary)
                .padding(.vertical, 14)
                .padding(.horizontal, 16)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(HushPalette.raisedFill)
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .strokeBorder(HushPalette.outline, lineWidth: 1)
                        )
                )
        }
    }

    @ViewBuilder private var categorySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Category")
                .font(.caption.weight(.semibold))
                .textCase(.uppercase)
                .foregroundStyle(HushPalette.textSecondary)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(SoundCategory.allCases) { cat in
                        let isSelected = cat == category
                        Button {
                            category = cat
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: cat.icon)
                                    .font(.caption)
                                Text(cat.rawValue)
                                    .font(.caption.weight(.semibold))
                            }
                            .foregroundStyle(isSelected ? HushPalette.textPrimary : HushPalette.textSecondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(
                                Capsule()
                                    .fill(isSelected ? HushPalette.chipActive : HushPalette.chipMuted)
                            )
                        }
                        .buttonStyle(HushPressButtonStyle())
                    }
                }
            }
            .sensoryFeedback(.selection, trigger: category)
        }
    }

    @ViewBuilder private var iconSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Icon")
                .font(.caption.weight(.semibold))
                .textCase(.uppercase)
                .foregroundStyle(HushPalette.textSecondary)

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 6), spacing: 8) {
                iconChip(symbol: nil, isCategoryDefault: true)
                ForEach(Self.iconChoices, id: \.self) { symbol in
                    iconChip(symbol: symbol, isCategoryDefault: false)
                }
            }
        }
    }

    @ViewBuilder private func iconChip(symbol: String?, isCategoryDefault: Bool) -> some View {
        let isSelected = (symbol == iconOverride) || (isCategoryDefault && iconOverride == nil)
        let renderedSymbol = symbol ?? category.icon

        Button {
            iconOverride = isCategoryDefault ? nil : symbol
        } label: {
            Image(systemName: renderedSymbol)
                .font(.headline)
                .foregroundStyle(isSelected ? HushPalette.textPrimary : HushPalette.textSecondary)
                .frame(width: 44, height: 44)
                .background(
                    Circle()
                        .fill(isSelected ? HushPalette.chipActive : HushPalette.chipMuted)
                        .overlay(
                            Circle().strokeBorder(
                                isCategoryDefault ? HushPalette.outline : Color.clear,
                                lineWidth: 1
                            )
                        )
                )
        }
        .buttonStyle(HushPressButtonStyle())
        .accessibilityLabel(isCategoryDefault ? "Use category icon" : "Icon \(renderedSymbol)")
    }

    @ViewBuilder private var crossfadeSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Smooth loop")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(HushPalette.textPrimary)
                    Text("Blends the end of the sound into the start.")
                        .font(.caption)
                        .foregroundStyle(HushPalette.textSecondary)
                }
                Spacer()
                Toggle("", isOn: $crossfadeEnabled)
                    .labelsHidden()
                    .tint(HushPalette.accentSoft)
            }

            if crossfadeEnabled {
                HStack(spacing: 8) {
                    ForEach(Self.crossfadeOptions, id: \.ms) { option in
                        let isSelected = option.ms == crossfadeDurationMs
                        Button {
                            crossfadeDurationMs = option.ms
                        } label: {
                            Text(option.label)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(isSelected ? HushPalette.textPrimary : HushPalette.textSecondary)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(
                                    Capsule()
                                        .fill(isSelected ? HushPalette.chipActive : HushPalette.chipMuted)
                                )
                        }
                        .buttonStyle(HushPressButtonStyle())
                    }
                    Spacer()
                }
                .sensoryFeedback(.selection, trigger: crossfadeDurationMs)
            }
        }
        .padding(16)
        .hushPanel(radius: 20)
    }

    @ViewBuilder private var limitationNote: some View {
        Text("Imported sounds may click at the loop point because they weren't recorded to loop. Crossfade smooths this by blending a moment of the start into the end.")
            .font(.caption)
            .foregroundStyle(HushPalette.textSecondary)
            .lineSpacing(2)
            .padding(.horizontal, 4)
    }

    // MARK: - Actions

    private var isEditing: Bool {
        if case .edit = mode { return true } else { return false }
    }

    private var canSubmit: Bool {
        !displayName.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func hydrateFromMode() {
        switch mode {
        case .newImport(let url):
            // Display name defaults to the original filename (sans extension).
            displayName = url.deletingPathExtension().lastPathComponent
            // Sniff a category from filename when possible — purely cosmetic.
            category = guessCategory(from: url.lastPathComponent)
        case .edit(let asset):
            displayName = asset.displayName
            category = asset.category
            iconOverride = asset.iconOverride
            crossfadeEnabled = asset.crossfadeEnabled
            crossfadeDurationMs = asset.crossfadeDurationMs
        }
    }

    private func togglePreview() {
        if isPreviewing {
            stopPreview()
        } else {
            startPreview()
        }
    }

    private func startPreview() {
        previewError = nil
        let url: URL
        switch mode {
        case .newImport(let sourceURL):
            // We need security-scoped access for files outside the app sandbox.
            guard sourceURL.startAccessingSecurityScopedResource() else {
                previewError = "Couldn't access this file."
                return
            }
            url = sourceURL
        case .edit(let asset):
            url = library.url(for: asset)
        }

        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.volume = 0.6
            // Flip the UI back to the play state when the file finishes
            // naturally — AVAudioPlayer doesn't loop and there's no other
            // signal, so the play button would stay in "playing" forever.
            // Extract just the URL (Sendable) to release the security scope;
            // capturing the whole Mode enum would drag in UserSoundAsset.
            let scopedURL: URL? = {
                if case .newImport(let url) = mode { return url }
                return nil
            }()
            let observer = PreviewObserver { [_isPreviewing, _previewPlayer, scopedURL] in
                _previewPlayer.wrappedValue?.stop()
                _previewPlayer.wrappedValue = nil
                _isPreviewing.wrappedValue = false
                scopedURL?.stopAccessingSecurityScopedResource()
            }
            player.delegate = observer
            previewObserver = observer
            player.prepareToPlay()
            player.play()
            previewPlayer = player
            isPreviewing = true
        } catch {
            previewError = "Couldn't play this file."
            if case .newImport(let sourceURL) = mode {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }
    }

    private func stopPreview() {
        previewPlayer?.stop()
        previewPlayer = nil
        previewObserver = nil
        isPreviewing = false
        if case .newImport(let sourceURL) = mode {
            sourceURL.stopAccessingSecurityScopedResource()
        }
    }

    private func commit() {
        guard canSubmit, !isWorking else { return }
        isWorking = true
        importError = nil
        stopPreview()

        let trimmedName = displayName.trimmingCharacters(in: .whitespaces)

        do {
            switch mode {
            case .newImport(let sourceURL):
                let scoped = sourceURL.startAccessingSecurityScopedResource()
                defer { if scoped { sourceURL.stopAccessingSecurityScopedResource() } }
                let asset = try library.importSound(
                    from: sourceURL,
                    displayName: trimmedName,
                    category: category,
                    crossfadeEnabled: crossfadeEnabled,
                    crossfadeDurationMs: crossfadeDurationMs,
                    iconOverride: iconOverride
                )
                onComplete?(asset)
                dismiss()

            case .edit(let asset):
                library.update(asset) { rec in
                    rec.displayName = trimmedName
                    rec.category = category
                    rec.iconOverride = iconOverride
                    rec.crossfadeEnabled = crossfadeEnabled
                    rec.crossfadeDurationMs = crossfadeDurationMs
                }
                onComplete?(asset)
                dismiss()
            }
        } catch let error as UserSoundImportError {
            importError = error.errorDescription
            isWorking = false
        } catch {
            importError = "Something went wrong importing this sound."
            isWorking = false
        }
    }

    private func cancelAndDismiss() {
        stopPreview()
        dismiss()
    }

    private func guessCategory(from filename: String) -> SoundCategory {
        let lower = filename.lowercased()
        // Match keywords against word *prefixes* (split on non-alphanumerics)
        // rather than naive substrings — otherwise "train-passing.mp3" would
        // match "rain" inside "train" before we ever check "train". Order
        // still matters where one keyword is a prefix of another at the word
        // level (e.g. "campfire" before "fire"). Plurals work via hasPrefix:
        // "birds".hasPrefix("bird") == true.
        let words = lower.components(separatedBy: CharacterSet.alphanumerics.inverted)
        let keywords: [(String, SoundCategory)] = [
            ("rain", .rain),
            ("thunder", .thunder), ("storm", .thunder),
            ("ocean", .ocean), ("wave", .ocean), ("sea", .ocean),
            ("campfire", .fire), ("fire", .fire), ("flame", .fire),
            ("wind", .wind),
            ("bird", .birds), ("chirp", .birds),
            ("water", .water), ("river", .water), ("stream", .water),
            ("traffic", .urban), ("city", .urban), ("siren", .urban),
            ("train", .transport), ("plane", .transport), ("airplane", .transport),
        ]
        for (token, category) in keywords {
            if words.contains(where: { $0.hasPrefix(token) }) { return category }
        }
        // Fallback — full rawValue substring match (handles longer names
        // where the category label appears verbatim in the filename).
        for category in SoundCategory.allCases {
            if lower.contains(category.rawValue.lowercased()) { return category }
        }
        return .things
    }
}

/// Bridges `AVAudioPlayerDelegate.audioPlayerDidFinishPlaying` to a Swift
/// closure so the import sheet can flip its UI back to the play state when
/// a preview ends naturally. AVFoundation holds the delegate weakly, so
/// the sheet must retain this object via `@State`.
private final class PreviewObserver: NSObject, AVAudioPlayerDelegate {
    private let onFinish: @MainActor () -> Void

    init(onFinish: @escaping @MainActor () -> Void) {
        self.onFinish = onFinish
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in onFinish() }
    }
}
