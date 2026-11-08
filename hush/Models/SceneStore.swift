import Foundation
import SwiftData


// MARK: - Scene list helpers

/// The order scenes appear in: built-in slots first (an edited built-in's
/// saved version takes its slot, hidden ones are skipped, renames applied),
/// then user-created scenes. Generic over the saved type so it's testable
/// without SwiftData.
enum SceneOrdering {
    static func ordered<Saved>(
        builtIns: [Preset] = Preset.builtIn,
        saved: [Saved],
        stableID: (Saved) -> UUID,
        toPreset: (Saved) -> Preset,
        hidden: Set<UUID>,
        renamed: [UUID: String]
    ) -> [(preset: Preset, saved: Saved?)] {
        let builtInIDs = Set(builtIns.map(\.id))
        // `stableID` isn't `@Attribute(.unique)`, so duplicates are possible.
        // Keep the first (newest, given the @Query sort) instead of trapping.
        let savedByID = Dictionary(saved.map { (stableID($0), $0) }, uniquingKeysWith: { first, _ in first })
        var result: [(preset: Preset, saved: Saved?)] = []

        for builtIn in builtIns {
            if let edited = savedByID[builtIn.id] {
                result.append((toPreset(edited), edited))
            } else if !hidden.contains(builtIn.id) {
                var preset = builtIn
                if let newName = renamed[builtIn.id] { preset.name = newName }
                result.append((preset, nil))
            }
        }

        var seen = Set<UUID>()
        for entry in saved {
            let id = stableID(entry)
            guard !builtInIDs.contains(id), seen.insert(id).inserted else { continue }
            result.append((toPreset(entry), entry))
        }
        return result
    }
}

/// The edit-save path: Edit Sounds and the header's "Update scene" both write
/// through here.
enum ScenePersistence {
    /// Returns false when there was nothing to write to (a saved scene that
    /// has since been deleted).
    @discardableResult
    static func saveEdited(
        _ preset: Preset,
        sources: [SoundSource],
        renamedBuiltIns: [UUID: String],
        context: ModelContext
    ) -> Bool {
        let targetID = preset.id
        let descriptor = FetchDescriptor<SavedPreset>(
            predicate: #Predicate { $0.stableID == targetID }
        )
        if let saved = try? context.fetch(descriptor).first {
            saved.sources = sources
            return true
        }

        // Built-in preset: convert to saved, keeping the same ID
        guard preset.isBuiltIn else { return false }
        let name = renamedBuiltIns[preset.id] ?? preset.name
        let saved = SavedPreset(name: name, icon: preset.icon, sources: sources)
        saved.stableID = preset.id
        context.insert(saved)
        // Don't hide the built-in — SceneOrdering already prefers the saved version
        return true
    }
}

/// Hidden and renamed built-in scenes, stored as JSON blobs in UserDefaults
/// under `PrefsKey`. Views read them through `@AppStorage`; this is the
/// shared codec plus the writes that happen outside the scene list.
enum BuiltInSceneStore {
    static func decodeHidden(_ data: Data) -> Set<UUID> {
        (try? JSONDecoder().decode(Set<UUID>.self, from: data)) ?? []
    }

    static func decodeRenamed(_ data: Data) -> [UUID: String] {
        (try? JSONDecoder().decode([UUID: String].self, from: data)) ?? [:]
    }

    static func encode<Value: Encodable>(_ value: Value) -> Data {
        (try? JSONEncoder().encode(value)) ?? Data()
    }

    static func hidden(in defaults: UserDefaults = .standard) -> Set<UUID> {
        decodeHidden(defaults.data(forKey: PrefsKey.hiddenBuiltInPresets) ?? Data())
    }

    static func renamed(in defaults: UserDefaults = .standard) -> [UUID: String] {
        decodeRenamed(defaults.data(forKey: PrefsKey.renamedBuiltInPresets) ?? Data())
    }

    /// Undo for Hide.
    static func unhide(_ id: UUID, in defaults: UserDefaults = .standard) {
        var ids = hidden(in: defaults)
        guard ids.remove(id) != nil else { return }
        defaults.set(encode(ids), forKey: PrefsKey.hiddenBuiltInPresets)
    }
}
