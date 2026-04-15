@preconcurrency import AVFoundation
import Foundation
import os.log
import SwiftData

/// Errors surfaced from the import pipeline so the UI can show a useful message
/// instead of swallowing the failure.
enum UserSoundImportError: LocalizedError, Equatable {
    case unreadable
    case unsupportedFormat
    case tooShort(seconds: Double)
    case copyFailed
    case unknown

    var errorDescription: String? {
        switch self {
        case .unreadable:
            return "Couldn't read this audio file."
        case .unsupportedFormat:
            return "This audio format isn't supported."
        case .tooShort(let seconds):
            let s = String(format: "%.1f", seconds)
            return "Sound is too short (\(s)s). Pick something at least 1 second long."
        case .copyFailed:
            return "Couldn't save the imported sound."
        case .unknown:
            return "Something went wrong importing this sound."
        }
    }
}

/// Owns the user-imported sound library: file storage, SwiftData records,
/// and the lookup hook that lets `SoundAssetRegistry` find user assets.
///
/// Convention: all access happens on the main thread. Matches how the rest
/// of the app (AudioEngine, views, view models) treats SwiftData. We don't
/// add `@MainActor` because it would require painful annotations across the
/// existing static `SoundAssetRegistry` callers.
@Observable
final class UserSoundLibrary {
    nonisolated private static let logger = Logger(subsystem: "dev.abdeen.hush", category: "UserSoundLibrary")

    /// Minimum playable duration. Anything shorter can't crossfade meaningfully
    /// and will sound like a buzz.
    static let minimumDurationSeconds: Double = 1.0

    /// Subdirectory under `Documents/` that holds all imported audio files.
    static let storageDirectoryName = "UserSounds"

    private let modelContext: ModelContext
    private let storageDirectory: URL

    /// Cached snapshot for the registry hook. Refreshed on every mutation
    /// and after `verify()`. We keep it as `[UUID: UserSoundAsset]` to match
    /// how the registry will look things up.
    private(set) var assetsByID: [UUID: UserSoundAsset] = [:]

    init(modelContext: ModelContext, storageDirectory: URL? = nil) {
        self.modelContext = modelContext
        self.storageDirectory = storageDirectory ?? Self.defaultStorageDirectory()
        try? FileManager.default.createDirectory(at: self.storageDirectory, withIntermediateDirectories: true)
        refresh()
    }

    static func defaultStorageDirectory() -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent(storageDirectoryName, isDirectory: true)
    }

    // MARK: - Lookup

    /// Resolves a `user.<uuid>` asset ID into a `SoundAsset` shaped record
    /// the rest of the app can consume. Returns nil for non-user IDs or
    /// records that no longer have a backing file.
    func asset(withID id: String) -> SoundAsset? {
        guard let uuid = UserSoundAsset.uuid(fromAssetID: id),
              let record = assetsByID[uuid] else { return nil }
        return makeSoundAsset(from: record)
    }

    /// All user assets in a category, ordered by import date.
    func assets(in category: SoundCategory) -> [SoundAsset] {
        sortedAssets
            .filter { $0.category == category }
            .map(makeSoundAsset(from:))
    }

    /// All user assets, newest first.
    var allSoundAssets: [SoundAsset] {
        sortedAssets.map(makeSoundAsset(from:))
    }

    var sortedAssets: [UserSoundAsset] {
        assetsByID.values.sorted { $0.dateImported > $1.dateImported }
    }

    var totalDiskUsage: Int64 {
        assetsByID.values.reduce(0) { $0 + $1.fileSizeBytes }
    }

    func url(for asset: UserSoundAsset) -> URL {
        storageDirectory.appendingPathComponent(asset.fileName)
    }

    // MARK: - Import

    /// Copies the file at `sourceURL` into the app library and creates a
    /// `UserSoundAsset` record. The source URL must be readable — if it's
    /// from `.fileImporter`, call `startAccessingSecurityScopedResource()`
    /// before invoking this and stop after it returns.
    @discardableResult
    func importSound(
        from sourceURL: URL,
        displayName: String,
        category: SoundCategory,
        crossfadeEnabled: Bool = true,
        crossfadeDurationMs: Int = 100,
        iconOverride: String? = nil
    ) throws -> UserSoundAsset {
        // Decode probe — we want to fail fast with a friendly error rather
        // than letting the engine encounter a broken file later.
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: sourceURL)
        } catch {
            Self.logger.error("Import probe failed: \(error.localizedDescription)")
            throw UserSoundImportError.unreadable
        }

        let format = file.processingFormat
        let frameCount = Double(file.length)
        let sampleRate = format.sampleRate
        guard sampleRate > 0 else { throw UserSoundImportError.unsupportedFormat }

        let duration = frameCount / sampleRate
        guard duration >= Self.minimumDurationSeconds else {
            throw UserSoundImportError.tooShort(seconds: duration)
        }

        // Copy into storage with a UUID-stable name, preserving extension.
        let id = UUID()
        let ext = sourceURL.pathExtension.isEmpty ? "audio" : sourceURL.pathExtension
        let fileName = "\(id.uuidString).\(ext)"
        let destination = storageDirectory.appendingPathComponent(fileName)

        do {
            // Defensive: the destination can't exist (UUID-named) but if a
            // previous import crashed mid-copy, clear it.
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: sourceURL, to: destination)
        } catch {
            Self.logger.error("Copy failed: \(error.localizedDescription)")
            throw UserSoundImportError.copyFailed
        }

        let size = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? Int64) ?? 0
        let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedName = trimmedName.isEmpty
            ? sourceURL.deletingPathExtension().lastPathComponent
            : trimmedName

        let record = UserSoundAsset(
            id: id,
            displayName: resolvedName,
            category: category,
            fileName: fileName,
            durationSeconds: duration,
            originalSampleRate: sampleRate,
            channelCount: Int(format.channelCount),
            fileSizeBytes: size,
            crossfadeEnabled: crossfadeEnabled,
            crossfadeDurationMs: crossfadeDurationMs,
            iconOverride: iconOverride
        )

        modelContext.insert(record)
        try? modelContext.save()
        refresh()

        Self.logger.info("Imported user sound: \(resolvedName) [\(record.assetID)]")
        return record
    }

    // MARK: - Mutation

    func update(_ asset: UserSoundAsset, mutate: (UserSoundAsset) -> Void) {
        mutate(asset)
        try? modelContext.save()
        refresh()
    }

    func delete(_ asset: UserSoundAsset) {
        let url = url(for: asset)
        try? FileManager.default.removeItem(at: url)
        modelContext.delete(asset)
        try? modelContext.save()
        refresh()
    }

    /// Re-binds an existing record to a new file (used when the original was
    /// deleted and the user wants to relink). Keeps the same `id` so saved
    /// presets continue to resolve.
    func relink(_ asset: UserSoundAsset, to sourceURL: URL) throws {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: sourceURL)
        } catch {
            throw UserSoundImportError.unreadable
        }

        let ext = sourceURL.pathExtension.isEmpty ? "audio" : sourceURL.pathExtension
        let newFileName = "\(asset.id.uuidString).\(ext)"
        let destination = storageDirectory.appendingPathComponent(newFileName)

        // Remove any prior file (could be a different extension).
        let oldURL = url(for: asset)
        if FileManager.default.fileExists(atPath: oldURL.path) {
            try? FileManager.default.removeItem(at: oldURL)
        }

        do {
            try FileManager.default.copyItem(at: sourceURL, to: destination)
        } catch {
            throw UserSoundImportError.copyFailed
        }

        let format = file.processingFormat
        let duration = Double(file.length) / format.sampleRate
        let size = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? Int64) ?? 0

        asset.fileName = newFileName
        asset.durationSeconds = duration
        asset.originalSampleRate = format.sampleRate
        asset.channelCount = Int(format.channelCount)
        asset.fileSizeBytes = size
        asset.isMissing = false
        try? modelContext.save()
        refresh()
    }

    // MARK: - Verification

    /// Checks every record's backing file. Sets `isMissing = true` for any
    /// record whose file is gone (manually deleted via Files app, restored
    /// from a partial backup, etc.). Returns the missing records so callers
    /// can surface a banner.
    @discardableResult
    func verify() -> [UserSoundAsset] {
        var missing: [UserSoundAsset] = []
        for asset in assetsByID.values {
            let exists = FileManager.default.fileExists(atPath: url(for: asset).path)
            if asset.isMissing != !exists {
                asset.isMissing = !exists
            }
            if !exists { missing.append(asset) }
        }
        try? modelContext.save()
        return missing
    }

    // MARK: - Internals

    private func refresh() {
        let descriptor = FetchDescriptor<UserSoundAsset>()
        let records = (try? modelContext.fetch(descriptor)) ?? []
        assetsByID = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
    }

    private func makeSoundAsset(from record: UserSoundAsset) -> SoundAsset {
        let style: CrossfadeStyle = {
            guard record.crossfadeEnabled else { return .percussive }
            switch record.crossfadeDurationMs {
            case ..<75: return .percussive
            case 75..<200: return .stochastic
            default: return .rhythmic
            }
        }()

        return SoundAsset(
            id: record.assetID,
            displayName: record.displayName,
            category: record.category,
            fileName: record.fileName,
            fileExtension: "",
            subdirectory: "",
            license: .userImported,
            crossfadeStyle: style,
            isMono: record.channelCount == 1,
            iconOverride: record.iconOverride,
            absolutePath: url(for: record).path,
            crossfadeOverrideMs: record.crossfadeEnabled ? Double(record.crossfadeDurationMs) : 0
        )
    }
}
