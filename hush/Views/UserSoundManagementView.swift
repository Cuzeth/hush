import SwiftUI
import UniformTypeIdentifiers

/// Library management screen reached from Settings. Lists every imported
/// sound with disk usage and the same edit/relink/delete actions you can
/// reach via long-press in the mixer.
struct UserSoundManagementView: View {
    @Environment(UserSoundLibrary.self) private var library
    @Environment(\.dismiss) private var dismiss

    @State private var showImporter = false
    @State private var editingAsset: UserSoundAsset?
    @State private var relinkAsset: UserSoundAsset?
    @State private var pendingNewImportURL: ImportURL?
    @State private var importerError: String?

    private var assets: [UserSoundAsset] {
        library.sortedAssets
    }

    var body: some View {
        ZStack {
            HushBackdrop()

            if assets.isEmpty {
                emptyState
            } else {
                listContent
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
        .navigationTitle("Imported Sounds")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showImporter = true
                } label: {
                    Image(systemName: "plus")
                        .foregroundStyle(HushPalette.accentSoft)
                }
                .accessibilityLabel("Import sound")
            }
        }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.audio],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let first = urls.first {
                    pendingNewImportURL = ImportURL(url: first)
                }
            case .failure(let error):
                showImporterError(error.localizedDescription)
            }
        }
        .sheet(item: $editingAsset) { asset in
            ImportSoundSheet(mode: .edit(asset: asset), library: library)
        }
        .sheet(item: $pendingNewImportURL) { wrap in
            ImportSoundSheet(mode: .newImport(sourceURL: wrap.url), library: library)
        }
        .fileImporter(
            isPresented: Binding(
                get: { relinkAsset != nil },
                set: { if !$0 { relinkAsset = nil } }
            ),
            allowedContentTypes: [.audio],
            allowsMultipleSelection: false
        ) { result in
            guard let asset = relinkAsset else { return }
            relinkAsset = nil
            if case .success(let urls) = result, let url = urls.first {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                do {
                    try library.relink(asset, to: url)
                } catch let error as UserSoundImportError {
                    showImporterError(error.errorDescription ?? "Couldn't relink.")
                } catch {
                    showImporterError("Couldn't relink.")
                }
            }
        }
    }

    @ViewBuilder private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "music.note.list")
                .font(.title2)
                .foregroundStyle(HushPalette.textSecondary)
            Text("No imported sounds yet")
                .font(.headline)
                .foregroundStyle(HushPalette.textPrimary)
            Text("Tap + above or open the mixer to add audio files from your device.")
                .font(.subheadline)
                .foregroundStyle(HushPalette.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
    }

    @ViewBuilder private var listContent: some View {
        ScrollView {
            VStack(spacing: 12) {
                summaryCard

                ForEach(assets) { asset in
                    AssetRow(
                        asset: asset,
                        onEdit: { editingAsset = asset },
                        onRelink: { relinkAsset = asset },
                        onDelete: { library.delete(asset) }
                    )
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 28)
        }
    }

    @ViewBuilder private var summaryCard: some View {
        let totalMB = Double(library.totalDiskUsage) / 1_000_000
        let exceedsSoftCap = library.totalDiskUsage > 200_000_000
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("\(assets.count) sound\(assets.count == 1 ? "" : "s")")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(HushPalette.textPrimary)
                Spacer()
                Text(String(format: "%.1f MB", totalMB))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(exceedsSoftCap ? HushPalette.danger : HushPalette.textSecondary)
                    .monospacedDigit()
            }
            if exceedsSoftCap {
                Text("Your library is over 200 MB. Imported audio is included in iCloud and device backups, which can slow them down.")
                    .font(.caption)
                    .foregroundStyle(HushPalette.textSecondary)
                    .lineSpacing(2)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .hushPanel(radius: HushRadius.md)
    }

    private func showImporterError(_ message: String) {
        withAnimation(HushMotion.quick) {
            importerError = message
        }
        // No auto-dismiss — user taps the inline close button. WCAG 2.2.1.
    }
}

private struct AssetRow: View {
    let asset: UserSoundAsset
    let onEdit: () -> Void
    let onRelink: () -> Void
    let onDelete: () -> Void

    @State private var showDeleteConfirmation = false

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(HushPalette.raisedFill)
                    .frame(width: 42, height: 42)
                Image(systemName: asset.iconOverride ?? asset.category.icon)
                    .font(.headline)
                    .foregroundStyle(HushPalette.textPrimary)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(asset.displayName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(HushPalette.textPrimary)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Text(asset.category.rawValue)
                    Text("·")
                    Text(formatDuration(asset.durationSeconds))
                    Text("·")
                    Text(formatSize(asset.fileSizeBytes))
                }
                .font(.caption)
                .foregroundStyle(HushPalette.textSecondary)
                .monospacedDigit()
            }

            Spacer(minLength: 8)

            if asset.isMissing {
                Button(action: onRelink) {
                    Text("Relink")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(HushPalette.danger)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            Capsule().fill(HushPalette.danger.opacity(0.15))
                        )
                }
                .buttonStyle(HushPressButtonStyle())
            }

            Menu {
                Button(action: onEdit) { Label("Edit", systemImage: "pencil") }
                Button(action: onRelink) { Label("Relink File", systemImage: "arrow.triangle.2.circlepath") }
                Button(role: .destructive) {
                    showDeleteConfirmation = true
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(HushPalette.textSecondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("More actions for \(asset.displayName)")
        }
        .padding(14)
        .hushPanel(radius: HushRadius.md)
        .confirmationDialog(
            "Delete \(asset.displayName)?",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive, action: onDelete)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Presets that use this sound will skip it.")
        }
    }

    private func formatDuration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let m = total / 60
        let s = total % 60
        return m > 0 ? String(format: "%d:%02d", m, s) : "\(s)s"
    }

    private func formatSize(_ bytes: Int64) -> String {
        let mb = Double(bytes) / 1_000_000
        if mb >= 1 { return String(format: "%.1f MB", mb) }
        let kb = Double(bytes) / 1_000
        return String(format: "%.0f KB", kb)
    }
}

/// Wrapper used to drive `.sheet(item:)` from a URL without polluting the
/// global `URL` type with a retroactive `Identifiable` conformance.
struct ImportURL: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}
