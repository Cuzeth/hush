import Foundation
import SwiftData
import SwiftUI
import Testing
@testable import hush

// Scene manage mode: the custom scene order, the move and drag helpers, the
// inline actions, and persistence. Pure helpers only; nothing here renders
// the selector or starts the audio engine.

/// Snapshot and restore the standard-defaults keys a test writes, so the
/// stored order can't leak into the other scene-list tests.
@MainActor
private func preservingSceneDefaults(_ body: () -> Void) {
    let keys = [PrefsKey.sceneOrder, PrefsKey.hiddenBuiltInPresets, PrefsKey.renamedBuiltInPresets]
    let defaults = UserDefaults.standard
    let saved = keys.map { defaults.object(forKey: $0) }
    keys.forEach { defaults.removeObject(forKey: $0) }
    defer {
        for (key, value) in zip(keys, saved) {
            if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
        }
    }
    body()
}

@MainActor private let builtInIDs = Preset.builtIn.map(\.id)

// MARK: - Ordering with a custom order

@MainActor
struct CustomSceneOrderTests {
    /// Stand-in for SavedPreset so ordering is testable without SwiftData.
    private struct FakeSaved {
        let id: UUID
        let preset: Preset
    }

    private func saved(id: UUID = UUID(), name: String) -> FakeSaved {
        FakeSaved(id: id, preset: Preset(id: id, name: name, icon: "star.fill",
                                         sources: [SoundSource(type: .pinkNoise, volume: 0.5)],
                                         isBuiltIn: false))
    }

    private func ordered(_ saved: [FakeSaved] = [], hidden: Set<UUID> = [],
                         renamed: [UUID: String] = [:], order: [UUID])
        -> [(preset: Preset, saved: FakeSaved?)] {
        SceneOrdering.ordered(saved: saved, stableID: \.id, toPreset: \.preset,
                              hidden: hidden, renamed: renamed, order: order)
    }

    private func ids(_ saved: [FakeSaved] = [], hidden: Set<UUID> = [],
                     renamed: [UUID: String] = [:], order: [UUID]) -> [UUID] {
        ordered(saved, hidden: hidden, renamed: renamed, order: order).map(\.preset.id)
    }

    @Test func emptyOrderIsTodaysDefault() {
        let mine = saved(name: "Mine")
        #expect(ids([mine], order: []) == builtInIDs + [mine.id])
    }

    @Test func partialOrderComesFirstAndTheRestKeepDefaultOrder() {
        let b = builtInIDs
        let mine = saved(name: "Mine")

        let result = ids([mine], order: [mine.id, b[3], b[0]])

        #expect(result == [mine.id, b[3], b[0]] + b.filter { $0 != b[3] && $0 != b[0] })
    }

    @Test func unknownIDsAreIgnored() {
        let b = builtInIDs
        let result = ids(order: [UUID(), b[2], UUID()])
        #expect(result == [b[2]] + b.filter { $0 != b[2] })
    }

    @Test func deletedUserSceneIDsAreIgnored() {
        let kept = saved(name: "Kept")
        let deleted = UUID()

        let result = ids([kept], order: [deleted, kept.id])

        #expect(result.first == kept.id)
        #expect(!result.contains(deleted))
        #expect(result.count == Preset.builtIn.count + 1)
    }

    @Test func repeatedIDsCountOnce() {
        let b = builtInIDs
        let result = ids(order: [b[1], b[1], b[0], b[1]])
        #expect(Array(result.prefix(2)) == [b[1], b[0]])
        #expect(Set(result).count == result.count)
        #expect(result.count == Preset.builtIn.count)
    }

    @Test func hiddenBuiltInStaysHiddenAndShowReturnsItToItsPlace() {
        let b = builtInIDs
        let order = [b[4], b[0], b[1]]

        let whileHidden = ids(hidden: [b[0]], order: order)
        #expect(!whileHidden.contains(b[0]))
        #expect(Array(whileHidden.prefix(2)) == [b[4], b[1]])

        let shown = ids(order: order)
        #expect(Array(shown.prefix(3)) == order, "Show puts it back where the order had it")
    }

    @Test func editedBuiltInKeepsItsCustomPosition() {
        let b = builtInIDs
        let edited = saved(id: b[2], name: "My Edit")

        // Edited versions own their slot even when the stock one is hidden.
        let result = ordered([edited], hidden: [b[2]], renamed: [b[2]: "Ignored"], order: [b[2], b[0]])

        #expect(result.count == Preset.builtIn.count)
        #expect(result[0].preset.id == b[2])
        #expect(result[0].preset.name == "My Edit")
        #expect(result[0].saved?.id == b[2])
        #expect(result[1].preset.id == b[0])
    }

    @Test func renamesApplyInACustomOrder() {
        let b = builtInIDs
        let result = ordered(renamed: [b[6]: "Bright"], order: [b[6]])
        #expect(result.first?.preset.id == b[6])
        #expect(result.first?.preset.name == "Bright")
    }

    @Test func scenesCreatedAfterACustomOrderFollowIt() {
        let older = saved(name: "Older")
        let newer = saved(name: "Newer")
        // The order was stored before `newer` existed.
        let order = [older.id] + builtInIDs

        #expect(ids([newer, older], order: order) == order + [newer.id])
    }

    @Test func hiddenGroupListsUnshadowedHiddenBuiltInsWithRenames() {
        let b = Preset.builtIn
        let result = SceneOrdering.hiddenBuiltIns(
            savedIDs: [b[3].id],
            hidden: [b[0].id, b[3].id, b[5].id],
            renamed: [b[5].id: "Muffled"]
        )
        #expect(result.map(\.id) == [b[0].id, b[5].id],
                "An edited built-in owns its slot, so it isn't in Hidden")
        #expect(result.last?.name == "Muffled")
    }
}

// MARK: - Move helpers

@MainActor
struct SceneMoveTests {
    private let ids = (0..<5).map { _ in UUID() }

    @Test func moveFromOffsetsFollowsOnMoveSemantics() {
        #expect(SceneOrdering.moving(ids, fromOffsets: [0], toOffset: 3) == [ids[1], ids[2], ids[0], ids[3], ids[4]])
        #expect(SceneOrdering.moving(ids, fromOffsets: [4], toOffset: 1) == [ids[0], ids[4], ids[1], ids[2], ids[3]])
        #expect(SceneOrdering.moving(ids, fromOffsets: [1], toOffset: 5) == [ids[0], ids[2], ids[3], ids[4], ids[1]])
        #expect(SceneOrdering.moving(ids, fromOffsets: [0, 2], toOffset: 5) == [ids[1], ids[3], ids[4], ids[0], ids[2]])
        #expect(SceneOrdering.moving(ids, fromOffsets: [2], toOffset: 2) == ids)
        #expect(SceneOrdering.moving(ids, fromOffsets: [2], toOffset: 3) == ids)
        #expect(SceneOrdering.moving(ids, fromOffsets: [9], toOffset: 0) == ids, "Out-of-range offsets are ignored")
    }

    @Test func moveFromOffsetsAgreesWithSwiftUIsMove() {
        for source in ids.indices {
            for destination in 0...ids.count {
                var expected = ids
                expected.move(fromOffsets: [source], toOffset: destination)
                #expect(SceneOrdering.moving(ids, fromOffsets: [source], toOffset: destination) == expected)
            }
        }
    }

    @Test func stepMovesForVoiceOver() {
        #expect(SceneOrdering.moving(ids[2], by: -1, in: ids) == [ids[0], ids[2], ids[1], ids[3], ids[4]])
        #expect(SceneOrdering.moving(ids[2], by: 1, in: ids) == [ids[0], ids[1], ids[3], ids[2], ids[4]])
        #expect(SceneOrdering.moving(ids[0], by: -1, in: ids) == nil, "Already at the top")
        #expect(SceneOrdering.moving(ids[4], by: 1, in: ids) == nil, "Already at the bottom")
        #expect(SceneOrdering.moving(UUID(), by: 1, in: ids) == nil)
        #expect(SceneOrdering.moving(ids[1], by: 0, in: ids) == nil)
    }

    @Test func aDropMovesSeveralSlotsAtOnce() {
        #expect(SceneOrdering.moving(ids[0], by: 3, in: ids) == [ids[1], ids[2], ids[3], ids[0], ids[4]])
        #expect(SceneOrdering.moving(ids[4], by: -4, in: ids) == [ids[4], ids[0], ids[1], ids[2], ids[3]])
    }

    @Test func storedOrderKeepsHiddenEntriesAfterTheVisibleOnes() {
        let hiddenID = UUID()
        let previous = [ids[1], hiddenID, ids[0]]
        let visible = [ids[2], ids[0], ids[1]]

        let stored = SceneOrdering.storedOrder(afterReordering: visible, previous: previous, defaultOrder: ids)

        #expect(stored == visible + [hiddenID])
    }

    @Test func storedOrderMatchingTheDefaultIsCleared() {
        let stored = SceneOrdering.storedOrder(afterReordering: ids, previous: [ids[1], ids[0]], defaultOrder: ids)
        #expect(stored.isEmpty, "Moving everything back means there's no custom order to reset")
    }

    @Test func pruningRemovesOnlyThatID() {
        #expect(SceneOrdering.pruning(ids[1], from: ids) == [ids[0], ids[2], ids[3], ids[4]])
        #expect(SceneOrdering.pruning(UUID(), from: ids) == ids)
    }

    @Test func onlyRemovedUserScenesArePruned() {
        let builtIn = Preset.builtIn[0].id
        let deleted = UUID()
        let kept = UUID()
        let duplicated = UUID()

        let removed = SceneOrdering.removedUserSceneIDs(
            from: [builtIn, deleted, kept, duplicated, duplicated],
            to: [kept, duplicated],
            builtInIDs: Set(builtInIDs)
        )

        #expect(removed == [deleted],
                "A reverted built-in keeps its place, and a surviving duplicate isn't gone")
    }
}

// MARK: - Drag geometry

@MainActor
struct SceneDragLayoutTests {
    private let spacing: CGFloat = 12

    @Test func swapsHalfwayAcrossANeighbour() {
        let heights: [CGFloat] = [66, 66, 66, 66]
        // One slot is 78pt (row plus spacing); the swap happens at 39.
        #expect(SceneDragLayout.target(dragging: 0, heights: heights, spacing: spacing, translation: 0).index == 0)
        #expect(SceneDragLayout.target(dragging: 0, heights: heights, spacing: spacing, translation: 38).index == 0)

        let down = SceneDragLayout.target(dragging: 0, heights: heights, spacing: spacing, translation: 40)
        #expect(down.index == 1)
        #expect(down.slotDelta == 78)

        let up = SceneDragLayout.target(dragging: 3, heights: heights, spacing: spacing, translation: -100)
        #expect(up.index == 2)
        #expect(up.slotDelta == -78)

        let farUp = SceneDragLayout.target(dragging: 3, heights: heights, spacing: spacing, translation: -160)
        #expect(farUp.index == 1)
        #expect(farUp.slotDelta == -156)
    }

    @Test func dragsPastTheEndsClampToTheFirstAndLastSlot() {
        let heights: [CGFloat] = [66, 66, 66, 66]
        let top = SceneDragLayout.target(dragging: 1, heights: heights, spacing: spacing, translation: -1000)
        #expect(top.index == 0)
        #expect(top.slotDelta == -78)

        let bottom = SceneDragLayout.target(dragging: 1, heights: heights, spacing: spacing, translation: 1000)
        #expect(bottom.index == 3)
        #expect(bottom.slotDelta == 156)
    }

    @Test func tallNeighboursNeedAFurtherDrag() {
        // Dynamic Type and wrapped names make rows uneven.
        let heights: [CGFloat] = [60, 100, 60]
        #expect(SceneDragLayout.target(dragging: 0, heights: heights, spacing: spacing, translation: 50).index == 0)

        let past = SceneDragLayout.target(dragging: 0, heights: heights, spacing: spacing, translation: 90)
        #expect(past.index == 1)
        #expect(past.slotDelta == 112, "Settles below the 100pt row: its height plus spacing")
    }

    @Test func passedRowsStepAsideByTheDraggedRowsHeight() {
        let down = (0..<5).map {
            SceneDragLayout.shift(forRowAt: $0, dragging: 1, to: 3, draggedHeight: 66, spacing: spacing)
        }
        #expect(down == [0, 0, -78, -78, 0])

        let up = (0..<5).map {
            SceneDragLayout.shift(forRowAt: $0, dragging: 3, to: 1, draggedHeight: 66, spacing: spacing)
        }
        #expect(up == [0, 78, 78, 0, 0])

        let still = (0..<5).map {
            SceneDragLayout.shift(forRowAt: $0, dragging: 2, to: 2, draggedHeight: 66, spacing: spacing)
        }
        #expect(still.allSatisfy { $0 == 0 })
    }

    /// The drop must not jump: where every row is drawn at release (layout
    /// plus drag offset) is exactly where the committed order lays it out.
    @Test func drawnPositionsMatchTheCommittedOrder() {
        let heights: [CGFloat] = [50, 80, 66, 100, 66]
        let ids = heights.map { _ in UUID() }
        let heightByID = Dictionary(uniqueKeysWithValues: zip(ids, heights))

        func tops(_ order: [UUID]) -> [UUID: CGFloat] {
            var result: [UUID: CGFloat] = [:]
            var y: CGFloat = 0
            for id in order {
                result[id] = y
                y += (heightByID[id] ?? 0) + spacing
            }
            return result
        }

        let startTops = tops(ids)
        for start in ids.indices {
            for translation in stride(from: CGFloat(-420), through: 420, by: 15) {
                let landing = SceneDragLayout.target(dragging: start, heights: heights,
                                                     spacing: spacing, translation: translation)
                let committed = SceneOrdering.moving(ids[start], by: landing.index - start, in: ids) ?? ids
                let finalTops = tops(committed)

                for (row, id) in ids.enumerated() {
                    let offset = row == start
                        ? landing.slotDelta
                        : SceneDragLayout.shift(forRowAt: row, dragging: start, to: landing.index,
                                                draggedHeight: heights[start], spacing: spacing)
                    #expect((startTops[id] ?? 0) + offset == finalTops[id],
                            "row \(row), dragging \(start) by \(translation)")
                }
            }
        }
    }
}

// MARK: - Inline actions

@MainActor
struct SceneManageActionTests {
    @Test func builtInsHideAndResetOnlyOnceChanged() {
        #expect(SceneManageAction.available(isBuiltIn: true, isEdited: false, isRenamed: false) == [.rename, .hide])
        #expect(SceneManageAction.available(isBuiltIn: true, isEdited: false, isRenamed: true) == [.rename, .reset, .hide])
        #expect(SceneManageAction.available(isBuiltIn: true, isEdited: true, isRenamed: false) == [.rename, .reset],
                "Hiding the stock scene wouldn't remove an edited version")
        #expect(SceneManageAction.available(isBuiltIn: true, isEdited: true, isRenamed: true) == [.rename, .reset])
    }

    @Test func userScenesDelete() {
        #expect(SceneManageAction.available(isBuiltIn: false, isEdited: false, isRenamed: false) == [.rename, .delete])
        #expect(SceneManageAction.delete.isDestructive)
        #expect(!SceneManageAction.hide.isDestructive)
        #expect(!SceneManageAction.reset.isDestructive)
    }
}

// MARK: - Persistence

@MainActor
struct SceneOrderStoreTests {
    private func makeDefaults() -> (UserDefaults, String) {
        let suite = "hush-tests-\(UUID().uuidString)"
        return (UserDefaults(suiteName: suite)!, suite)
    }

    @Test func codecRoundTripsAndEmptyMeansNoCustomOrder() {
        let order = [UUID(), UUID(), UUID()]
        let data = SceneOrderStore.encode(order)
        #expect(SceneOrderStore.decode(data) == order, "Order is kept, not just membership")
        #expect(SceneOrderStore.hasCustomOrder(data))

        #expect(SceneOrderStore.encode([]).isEmpty)
        #expect(!SceneOrderStore.hasCustomOrder(Data()))
        #expect(SceneOrderStore.decode(Data("junk".utf8)).isEmpty)
    }

    @Test func storedOrderPersistsAndResets() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let order = [builtInIDs[3], builtInIDs[0]]
        defaults.set(SceneOrderStore.encode(order), forKey: PrefsKey.sceneOrder)

        #expect(SceneOrderStore.order(in: defaults) == order)

        SceneOrderStore.reset(in: defaults)

        #expect(SceneOrderStore.order(in: defaults).isEmpty)
        #expect(defaults.data(forKey: PrefsKey.sceneOrder) == nil)
    }

    @Test func resetLeavesHiddenAndRenamedScenesAlone() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let id = builtInIDs[1]
        defaults.set(SceneOrderStore.encode([id]), forKey: PrefsKey.sceneOrder)
        defaults.set(BuiltInSceneStore.encode(Set([id])), forKey: PrefsKey.hiddenBuiltInPresets)
        defaults.set(BuiltInSceneStore.encode([id: "Morning"]), forKey: PrefsKey.renamedBuiltInPresets)

        SceneOrderStore.reset(in: defaults)

        #expect(BuiltInSceneStore.hidden(in: defaults) == [id])
        #expect(BuiltInSceneStore.renamed(in: defaults) == [id: "Morning"])
    }

    @Test func pruneDropsOnlyTheDeletedScene() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let deleted = UUID()
        let kept = UUID()
        let builtIn = builtInIDs[0]
        defaults.set(SceneOrderStore.encode([kept, deleted, builtIn]), forKey: PrefsKey.sceneOrder)

        SceneOrderStore.prune(deleted, in: defaults)
        #expect(SceneOrderStore.order(in: defaults) == [kept, builtIn])

        SceneOrderStore.prune(UUID(), in: defaults)
        #expect(SceneOrderStore.order(in: defaults) == [kept, builtIn], "Unknown IDs are a no-op")
    }

    @Test func pruningTheLastEntryClearsTheCustomOrder() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let only = UUID()
        defaults.set(SceneOrderStore.encode([only]), forKey: PrefsKey.sceneOrder)

        SceneOrderStore.prune(only, in: defaults)

        #expect(defaults.data(forKey: PrefsKey.sceneOrder) == nil)
    }
}

// MARK: - resolvedSceneList and remote next/previous

@MainActor
struct ResolvedSceneListOrderTests {
    @Test func explicitOrderIsHonored() {
        let b = builtInIDs
        let mine = SavedPreset(name: "Mine", icon: "star", sources: [])

        let list = Preset.resolvedSceneList(saved: [mine], hiddenIDs: [], renames: [:],
                                            order: [mine.stableID, b[2]])

        #expect(list.map(\.id) == [mine.stableID, b[2]] + b.filter { $0 != b[2] })
    }

    @Test func defaultReadsTheStoredOrderAndResetRestoresIt() {
        preservingSceneDefaults {
            let b = builtInIDs
            let mine = SavedPreset(name: "Mine", icon: "star", sources: [])
            UserDefaults.standard.set(SceneOrderStore.encode([b[5], mine.stableID]), forKey: PrefsKey.sceneOrder)

            let list = Preset.resolvedSceneList(saved: [mine], hiddenIDs: [], renames: [:])
            #expect(list.map(\.id) == [b[5], mine.stableID] + b.filter { $0 != b[5] })

            SceneOrderStore.reset()
            let reset = Preset.resolvedSceneList(saved: [mine], hiddenIDs: [], renames: [:])
            #expect(reset.map(\.id) == b + [mine.stableID], "Reset Scene Order brings back the default list")
        }
    }

    @Test func storedOrderWorksWithHiddenAndRenamedScenes() {
        preservingSceneDefaults {
            let b = builtInIDs
            UserDefaults.standard.set(SceneOrderStore.encode([b[3], b[0], b[1]]), forKey: PrefsKey.sceneOrder)

            let list = Preset.resolvedSceneList(saved: [], hiddenIDs: [b[0]], renames: [b[1]: "Night"])

            #expect(list.prefix(2).map(\.id) == [b[3], b[1]])
            #expect(list[1].name == "Night")
            #expect(!list.contains { $0.id == b[0] })
        }
    }

    @Test func remoteNextAndPreviousFollowTheStoredOrder() throws {
        let schema = Schema([SavedPreset.self, UserSoundAsset.self])
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let context = ModelContext(container)
        let mine = SavedPreset(name: "Mine", icon: "star", sources: [SoundSource(type: .brownNoise)])
        context.insert(mine)
        try context.save()

        preservingSceneDefaults {
            let b = Preset.builtIn
            UserDefaults.standard.set(SceneOrderStore.encode([b[4].id, mine.stableID, b[0].id]),
                                      forKey: PrefsKey.sceneOrder)

            let vm = PlayerViewModel()
            vm.bindModelContext(context)

            #expect(vm.adjacentScene(forward: true)?.id == b[4].id, "Nothing loaded: next is the first in your order")

            vm.currentPreset = b[4]
            #expect(vm.adjacentScene(forward: true)?.id == mine.stableID)
            #expect(vm.adjacentScene(forward: false)?.id == b.last?.id, "Previous from the top wraps to the end")

            vm.currentPreset = mine.toPreset()
            #expect(vm.adjacentScene(forward: true)?.id == b[0].id)
        }
    }
}
