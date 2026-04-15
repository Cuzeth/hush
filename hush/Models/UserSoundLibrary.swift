@preconcurrency import AVFoundation
import CryptoKit
import Foundation
import os.log
import SwiftData

/// Errors surfaced from the import pipeline so the UI can show a useful message
/// instead of swallowing the failure.
enum UserSoundImportError: LocalizedError, Equatable {
    case unreadable
    case unsupportedFormat
    case tooShort(seconds: Double)
    case tooLong(seconds: Double, maxSeconds: Double)
    case tooLarge(maxBytes: Int64)
    case duplicate(existingDisplayName: String)
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
        case .tooLong(let seconds, let maxSeconds):
            let s = String(format: "%.1f", seconds)
            let mins = Int(maxSeconds / 60)
            return "Sound is too long (\(s)s). Pick something under \(mins) minutes."
        case .tooLarge(let maxBytes):
            let mb = Int(maxBytes / 1_000_000)
            return "Sound is too large. Pick a file under \(mb) MB."
        case .duplicate(let existing):
            return "You've already imported this sound as \"\(existing)\"."
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

    /// Hard cap on a single import file (~50 MB). First-line guard against
    /// pulling a huge file off disk before we even probe it. Doesn't catch
    /// long compressed audio (a 50 MB MP3 decodes to ~1 GB of PCM) — that's
    /// what `maximumDurationSeconds` is for. Overridable per-instance for tests.
    static let defaultMaximumImportFileSizeBytes: Int64 = 50_000_000

    /// Hard cap on imported sound duration (10 minutes). Decoded PCM scales
    /// linearly with duration regardless of source format — a 50-minute MP3
    /// expands to ~1 GB of Float32 stereo and would blow out the engine's
    /// 200 MB buffer cache plus starve memory during load. Looping ambient
    /// sounds rarely need more than a few minutes anyway.
    static let maximumDurationSeconds: Double = 600.0

    /// Subdirectory under `Documents/` that holds all imported audio files.
    static let storageDirectoryName = "UserSounds"

    let maximumImportFileSizeBytes: Int64
    private let modelContext: ModelContext
    private let storageDirectory: URL

    /// Cached snapshot for the registry hook. Refreshed on every mutation
    /// and after `verify()`. We keep it as `[UUID: UserSoundAsset]` to match
    /// how the registry will look things up.
    private(set) var assetsByID: [UUID: UserSoundAsset] = [:]

    init(
        modelContext: ModelContext,
        storageDirectory: URL? = nil,
        maximumImportFileSizeBytes: Int64 = UserSoundLibrary.defaultMaximumImportFileSizeBytes
    ) {
        self.modelContext = modelContext
        self.storageDirectory = storageDirectory ?? Self.defaultStorageDirectory()
        self.maximumImportFileSizeBytes = maximumImportFileSizeBytes
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
        let probe = try validateAudioSource(at: sourceURL)
        let format = probe.file.processingFormat
        let duration = probe.duration

        // Hash the source so we can spot a re-import of the same file. Read
        // up to 2 MB — enough to disambiguate audio files in practice without
        // re-reading large WAVs into memory.
        let hash = Self.hashFilePrefix(at: sourceURL)
        if let hash, let existing = assetsByID.values.first(where: { $0.contentHash == hash }) {
            throw UserSoundImportError.duplicate(existingDisplayName: existing.displayName)
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
            originalSampleRate: format.sampleRate,
            channelCount: Int(format.channelCount),
            fileSizeBytes: size,
            crossfadeEnabled: crossfadeEnabled,
            crossfadeDurationMs: crossfadeDurationMs,
            iconOverride: iconOverride,
            contentHash: hash
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
    /// presets continue to resolve. Validates the new file the same way an
    /// import would — relink isn't a back door around the size/duration caps.
    func relink(_ asset: UserSoundAsset, to sourceURL: URL) throws {
        let probe = try validateAudioSource(at: sourceURL)
        let format = probe.file.processingFormat

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

        let size = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? Int64) ?? 0

        asset.fileName = newFileName
        asset.durationSeconds = probe.duration
        asset.originalSampleRate = format.sampleRate
        asset.channelCount = Int(format.channelCount)
        asset.fileSizeBytes = size
        asset.isMissing = false
        // Refresh the dedupe hash to match the new file. Without this, a
        // later import whose first 2 MB happens to match the OLD hash would
        // be flagged as a duplicate of this asset, naming a file that no
        // longer corresponds to its data.
        asset.contentHash = Self.hashFilePrefix(at: sourceURL)
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

    /// Result of probing a source file — the live AVAudioFile (held only for
    /// the caller's immediate use) and the duration we already computed.
    private struct AudioProbe {
        let file: AVAudioFile
        let duration: Double
    }

    /// Shared size + format + duration validation for both `importSound` and
    /// `relink`. Throws the user-facing error; the size check runs first so
    /// we never parse a file we're going to reject anyway.
    private func validateAudioSource(at sourceURL: URL) throws -> AudioProbe {
        if let size = (try? FileManager.default.attributesOfItem(atPath: sourceURL.path)[.size] as? Int64),
           size > maximumImportFileSizeBytes {
            throw UserSoundImportError.tooLarge(maxBytes: maximumImportFileSizeBytes)
        }

        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: sourceURL)
        } catch {
            Self.logger.error("Audio probe failed: \(error.localizedDescription)")
            throw UserSoundImportError.unreadable
        }

        let format = file.processingFormat
        guard format.sampleRate > 0 else { throw UserSoundImportError.unsupportedFormat }

        let duration = Double(file.length) / format.sampleRate
        guard duration >= Self.minimumDurationSeconds else {
            throw UserSoundImportError.tooShort(seconds: duration)
        }
        guard duration <= Self.maximumDurationSeconds else {
            throw UserSoundImportError.tooLong(seconds: duration, maxSeconds: Self.maximumDurationSeconds)
        }
        return AudioProbe(file: file, duration: duration)
    }

    /// SHA-256 of the first ~2 MB of the file at `url`. Returns nil if the
    /// file can't be opened — in that case the caller skips dedupe and lets
    /// the AVAudioFile probe surface the real error.
    static func hashFilePrefix(at url: URL, byteLimit: Int = 2_000_000) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: byteLimit) else { return nil }
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

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
