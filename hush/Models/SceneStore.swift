import Foundation
import SwiftData


// MARK: - Scene list helpers

/// The order scenes appear in. By default: built-in slots first (an edited
/// built-in's saved version takes its slot, hidden ones are skipped, renames
/// applied), then user-created scenes. A custom `order` (the user's drag
/// order, `PrefsKey.sceneOrder`) puts its IDs first, in that order; scenes
/// it doesn't mention follow in the default order. Generic over the saved
/// type so it's testable without SwiftData.
enum SceneOrdering {
    static func ordered<Saved>(
        builtIns: [Preset] = Preset.builtIn,
        saved: [Saved],
        stableID: (Saved) -> UUID,
        toPreset: (Saved) -> Preset,
        hidden: Set<UUID>,
        renamed: [UUID: String],
        order: [UUID] = []
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
        return applying(order, to: result, id: \.preset.id)
    }

    /// `order`'s IDs first, in that order, then every other item in its
    /// existing order. IDs that match no item (deleted scenes, hidden
    /// built-ins) are skipped, and a repeated ID counts once.
    static func applying<Element>(_ order: [UUID], to items: [Element], id: (Element) -> UUID) -> [Element] {
        guard !order.isEmpty else { return items }
        var rank: [UUID: Int] = [:]
        for (index, value) in order.enumerated() where rank[value] == nil {
            rank[value] = index
        }
        return items.enumerated()
            .map { (rank: rank[id($0.element)], offset: $0.offset, element: $0.element) }
            .sorted { lhs, rhs in
                switch (lhs.rank, rhs.rank) {
                case let (left?, right?): return left == right ? lhs.offset < rhs.offset : left < right
                case (.some, nil): return true
                case (nil, .some): return false
                case (nil, nil): return lhs.offset < rhs.offset
                }
            }
            .map(\.element)
    }

    /// Built-ins in the hidden set whose slot isn't owned by an edited saved
    /// version (that version stays listed even when the stock one is hidden),
    /// with renames applied. The manage list's "Hidden" group.
    static func hiddenBuiltIns(
        builtIns: [Preset] = Preset.builtIn,
        savedIDs: Set<UUID>,
        hidden: Set<UUID>,
        renamed: [UUID: String]
    ) -> [Preset] {
        builtIns.compactMap { builtIn in
            guard hidden.contains(builtIn.id), !savedIDs.contains(builtIn.id) else { return nil }
            var preset = builtIn
            if let newName = renamed[builtIn.id] { preset.name = newName }
            return preset
        }
    }

    // MARK: Reordering

    /// `onMove` semantics: the items at `source` move, keeping their
    /// relative order, to sit before the item that was at `destination`
    /// (`ids.count` means the end).
    static func moving(_ ids: [UUID], fromOffsets source: IndexSet, toOffset destination: Int) -> [UUID] {
        let moved = source.filter { ids.indices.contains($0) }
        guard !moved.isEmpty else { return ids }
        var remaining = ids.enumerated().filter { !moved.contains($0.offset) }.map(\.element)
        let insertion = destination - moved.filter { $0 < destination }.count
        remaining.insert(contentsOf: moved.map { ids[$0] }, at: min(max(insertion, 0), remaining.count))
        return remaining
    }

    /// One step toward the top (`step: -1`) or bottom (`step: 1`), for the
    /// VoiceOver Move Up / Move Down actions. Nil when `id` isn't listed or
    /// can't move that way.
    static func moving(_ id: UUID, by step: Int, in ids: [UUID]) -> [UUID]? {
        guard let index = ids.firstIndex(of: id), step != 0, ids.indices.contains(index + step) else { return nil }
        var result = ids
        result.remove(at: index)
        result.insert(id, at: index + step)
        return result
    }

    /// The order to store after the user reorders the visible list. Entries
    /// of the previous order that aren't visible (hidden built-ins) are kept
    /// after it, so Show brings them back near where they were. Returns []
    /// (no custom order) when the result is just the default order.
    static func storedOrder(afterReordering visible: [UUID], previous: [UUID], defaultOrder: [UUID]) -> [UUID] {
        guard visible != defaultOrder else { return [] }
        let visibleIDs = Set(visible)
        return visible + previous.filter { !visibleIDs.contains($0) }
    }

    /// `order` without `id`: a deleted scene leaves the stored order.
    static func pruning(_ id: UUID, from order: [UUID]) -> [UUID] {
        order.filter { $0 != id }
    }

    /// User scenes that left the saved list between two snapshots of its
    /// stable IDs: the ones to prune. A reverted built-in keeps its place,
    /// and an ID that's still present (a duplicate record) isn't gone.
    static func removedUserSceneIDs(from old: [UUID], to new: [UUID], builtInIDs: Set<UUID>) -> Set<UUID> {
        Set(old).subtracting(new).subtracting(builtInIDs)
    }
}

/// The user's custom scene order: JSON `[UUID]` under `PrefsKey.sceneOrder`.
/// Empty (or missing) means the default order. Views read it through
/// `@AppStorage`; this is the codec plus the writes that happen outside the
/// drag (delete pruning, Settings' reset).
enum SceneOrderStore {
    static func decode(_ data: Data) -> [UUID] {
        (try? JSONDecoder().decode([UUID].self, from: data)) ?? []
    }

    /// An empty order encodes to empty data, the "no custom order" default.
    static func encode(_ order: [UUID]) -> Data {
        order.isEmpty ? Data() : BuiltInSceneStore.encode(order)
    }

    static func order(in defaults: UserDefaults = .standard) -> [UUID] {
        decode(defaults.data(forKey: PrefsKey.sceneOrder) ?? Data())
    }

    static func hasCustomOrder(_ data: Data) -> Bool {
        !decode(data).isEmpty
    }

    /// Settings → Reset Scene Order.
    static func reset(in defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: PrefsKey.sceneOrder)
    }

    /// Drops a deleted user scene from the stored order.
    static func prune(_ id: UUID, in defaults: UserDefaults = .standard) {
        let current = order(in: defaults)
        let pruned = SceneOrdering.pruning(id, from: current)
        guard pruned != current else { return }
        if pruned.isEmpty {
            defaults.removeObject(forKey: PrefsKey.sceneOrder)
        } else {
            defaults.set(encode(pruned), forKey: PrefsKey.sceneOrder)
        }
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
