import Foundation
import SwiftData

// A user-imported audio file registered in the library. The file itself lives
// in `Documents/UserSounds/<id>.<ext>`; this record stores the metadata needed
// to surface it through `SoundAssetRegistry` and play it through the engine.
//
// `id` doubles as the storage filename stem AND the public asset ID
// (`user.<uuid-string>`), so saved presets can reference user sounds the same
// way they reference bundled ones.
@Model
final class UserSoundAsset {
    @Attribute(.unique) var id: UUID

    var displayName: String
    var categoryRaw: String
    var iconOverride: String?

    /// File on disk: stored as the leaf name only (e.g. "ABCD-EF12.mp3"), so
    /// the record stays valid across app upgrades that move the sandbox path.
    var fileName: String

    /// Audio metadata captured at import time — used for UI display and to
    /// catch incompatible files before they hit the engine.
    var durationSeconds: Double
    var originalSampleRate: Double
    var channelCount: Int
    var fileSizeBytes: Int64

    var crossfadeEnabled: Bool
    var crossfadeDurationMs: Int

    var dateImported: Date

    /// Set during `UserSoundLibrary.verify()` when the backing file is gone.
    /// Transient (recomputed each launch); we still persist it so UI can
    /// render the missing badge before the verify pass finishes.
    var isMissing: Bool

    init(
        id: UUID = UUID(),
        displayName: String,
        category: SoundCategory,
        fileName: String,
        durationSeconds: Double,
        originalSampleRate: Double,
        channelCount: Int,
        fileSizeBytes: Int64,
        crossfadeEnabled: Bool = true,
        crossfadeDurationMs: Int = 100,
        iconOverride: String? = nil,
        dateImported: Date = Date(),
        isMissing: Bool = false
    ) {
        self.id = id
        self.displayName = displayName
        self.categoryRaw = category.rawValue
        self.fileName = fileName
        self.durationSeconds = durationSeconds
        self.originalSampleRate = originalSampleRate
        self.channelCount = channelCount
        self.fileSizeBytes = fileSizeBytes
        self.crossfadeEnabled = crossfadeEnabled
        self.crossfadeDurationMs = crossfadeDurationMs
        self.iconOverride = iconOverride
        self.dateImported = dateImported
        self.isMissing = isMissing
    }

    var category: SoundCategory {
        get { SoundCategory(rawValue: categoryRaw) ?? .things }
        set { categoryRaw = newValue.rawValue }
    }

    /// Public asset ID — what `SoundSource.assetID` stores and what the
    /// registry resolves through.
    var assetID: String { Self.assetID(for: id) }

    static func assetID(for uuid: UUID) -> String {
        "user.\(uuid.uuidString)"
    }

    /// Parses an asset ID back into a UUID, returning nil for non-user IDs.
    static func uuid(fromAssetID id: String) -> UUID? {
        guard id.hasPrefix("user."), id.count > 5 else { return nil }
        return UUID(uuidString: String(id.dropFirst(5)))
    }
}
