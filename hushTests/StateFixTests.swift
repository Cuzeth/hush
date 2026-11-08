import AVFoundation
import Foundation
import SwiftData
import SwiftUI
import Testing
@testable import hush

// Regression tests for the state-layer audit fixes: preset/session
// bookkeeping in PlayerViewModel, the scene list, lossy persistence, and the
// user sound library's re-import and relink paths. Nothing here starts the
// audio engine — VM paths that would call play() are driven through their
// internal seams instead.

private let sessionKey = "lastSessionSources"

/// Snapshot and restore UserDefaults keys a test writes, so tests don't leak
/// into each other or into the simulator's app state.
@MainActor
private func preservingDefaults(_ keys: [String], _ body: () throws -> Void) rethrows {
    let defaults = UserDefaults.standard
    let saved = keys.map { defaults.object(forKey: $0) }
    keys.forEach { defaults.removeObject(forKey: $0) }
    defer {
        for (key, value) in zip(keys, saved) {
            if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
        }
    }
    try body()
}

// MARK: - removeSource

@MainActor
struct RemoveSourceStopsOnEmptyTests {

    @Test func removingLastSourceStopsPlayback() {
        let vm = PlayerViewModel()
        let source = SoundSource(type: .brownNoise, volume: 0.5)
        vm.activeSources = [source]
        vm.isPlaying = true

        vm.removeSource(source)

        #expect(vm.activeSources.isEmpty)
        #expect(vm.isPlaying == false, "An empty mix must not stay in the playing state")
    }

    @Test func removingOneOfSeveralKeepsPlaying() {
        let vm = PlayerViewModel()
        let a = SoundSource(type: .brownNoise, volume: 0.5)
        let b = SoundSource(type: .pinkNoise, volume: 0.5)
        vm.activeSources = [a, b]
        vm.isPlaying = true

        vm.removeSource(a)

        #expect(vm.activeSources.map(\.id) == [b.id])
        #expect(vm.isPlaying)
        vm.isPlaying = false
    }
}

// MARK: - Default add volume

@MainActor
struct DefaultAddVolumeTests {

    @Test func generatorsAndSamplesShareOneDefault() throws {
        let vm = PlayerViewModel()
        vm.addSource(.brownNoise)
        let asset = try #require(SoundAssetRegistry.bundled.first)
        vm.addAsset(asset)

        #expect(vm.activeSources.count == 2)
        #expect(vm.activeSources[0].volume == AudioConstants.defaultSourceVolume)
        #expect(vm.activeSources[1].volume == AudioConstants.defaultSourceVolume,
                "Samples used to come in at 1.0 while generators came in at 0.5")
        #expect(AudioConstants.defaultSourceVolume == 0.5)
    }
}

// MARK: - isCurrentPresetModified

@MainActor
struct PresetModifiedTests {

    private func makePreset() -> Preset {
        Preset(name: "Test", icon: "star", sources: [
            SoundSource(type: .brownNoise, volume: 0.6),
            SoundSource(type: .binauralBeats, volume: 0.3, binauralRange: .beta, binauralFrequency: 20),
            SoundSource(type: .sampleAsset, volume: 0.8, assetID: "moodist.rain.light"),
        ], isBuiltIn: false)
    }

    @Test func noPresetIsNeverModified() {
        let vm = PlayerViewModel()
        vm.activeSources = [SoundSource(type: .whiteNoise, volume: 0.5)]
        #expect(vm.isCurrentPresetModified == false)
    }

    @Test func freshlyLoadedPresetIsUnmodified() {
        let vm = PlayerViewModel()
        let preset = makePreset()
        vm.replaceActiveSources(with: preset.sources, preset: preset, animated: false)
        #expect(vm.isCurrentPresetModified == false)
    }

    @Test func volumeWithinToleranceIsUnmodified() {
        let vm = PlayerViewModel()
        let preset = makePreset()
        vm.replaceActiveSources(with: preset.sources, preset: preset, animated: false)

        vm.updateVolume(for: vm.activeSources[0], volume: 0.605)
        #expect(vm.isCurrentPresetModified == false)

        vm.updateVolume(for: vm.activeSources[0], volume: 0.2)
        #expect(vm.isCurrentPresetModified)
    }

    @Test func addingOrRemovingALayerIsModified() {
        let vm = PlayerViewModel()
        let preset = makePreset()
        vm.replaceActiveSources(with: preset.sources, preset: preset, animated: false)

        vm.addSource(.pinkNoise)
        #expect(vm.isCurrentPresetModified)

        vm.replaceActiveSources(with: preset.sources, preset: preset, animated: false)
        vm.activeSources.removeLast()
        #expect(vm.isCurrentPresetModified)
    }

    @Test func parameterChangeIsModified() {
        let vm = PlayerViewModel()
        let preset = makePreset()
        vm.replaceActiveSources(with: preset.sources, preset: preset, animated: false)

        vm.updateBinaural(for: vm.activeSources[1], range: nil, frequency: 25)
        #expect(vm.isCurrentPresetModified)
    }

    @Test func swappedAssetIsModified() {
        let vm = PlayerViewModel()
        let preset = makePreset()
        vm.replaceActiveSources(with: preset.sources, preset: preset, animated: false)

        vm.activeSources[2].assetID = "moodist.rain.heavy"
        #expect(vm.isCurrentPresetModified)
    }

    @Test func reorderedOrReIdentifiedLayersAreUnmodified() {
        // A restored session carries the previous launch's source UUIDs,
        // while built-ins mint fresh ones every launch — compare content.
        let vm = PlayerViewModel()
        let preset = makePreset()
        vm.currentPreset = preset
        vm.activeSources = preset.sources.reversed().map { source in
            var copy = source
            copy.id = UUID()
            return copy
        }
        #expect(vm.isCurrentPresetModified == false)
    }
}

// MARK: - Missing-set pruning

@MainActor
struct MissingSetPruningTests {

    @Test func replacingTheMixClearsBannerForSoundsNoLongerPresent() throws {
        let vm = PlayerViewModel()
        vm.activeSources = [SoundSource(type: .sampleAsset, volume: 0.5, assetID: "user.aaa")]
        vm.recordMissingAsset("user.aaa")
        guard case .missingUserSounds = vm.activeWarning else {
            Issue.record("Expected missing banner")
            return
        }

        let cozy = try #require(Preset.builtIn.first { $0.name == "Cozy" })
        vm.replaceActiveSources(with: cozy.sources, preset: cozy)

        #expect(vm.activeWarning == nil, "Banner must not outlive the mix that caused it")
    }

    @Test func replacingTheMixKeepsCountForSoundsStillPresent() {
        let vm = PlayerViewModel()
        let kept = SoundSource(type: .sampleAsset, volume: 0.5, assetID: "user.kept")
        vm.activeSources = [kept, SoundSource(type: .sampleAsset, volume: 0.5, assetID: "user.gone")]
        vm.recordMissingAsset("user.kept")
        vm.recordMissingAsset("user.gone")

        vm.replaceActiveSources(with: [kept, SoundSource(type: .brownNoise)], preset: nil)

        guard case .missingUserSounds(let count) = vm.activeWarning else {
            Issue.record("Banner should stay for the missing sound still in the mix")
            return
        }
        #expect(count == 1)
    }

    @Test func restoringASessionPrunesMissingSet() throws {
        preservingDefaults([sessionKey]) {
            let writer = PlayerViewModel()
            writer.activeSources = [SoundSource(type: .brownNoise, volume: 0.4)]
            writer.saveLastSession()

            let vm = PlayerViewModel()
            vm.activeSources = [SoundSource(type: .sampleAsset, volume: 0.5, assetID: "user.old")]
            vm.recordMissingAsset("user.old")

            #expect(vm.restoreLastSession())
            #expect(vm.activeWarning == nil)
        }
    }
}

// MARK: - relinkSource / handleUserAssetRelinked

@MainActor
struct UserAssetRelinkTests {

    @Test func relinkingASourceNeverReportedMissingDoesNotTrap() {
        // Pause, add a missing import (the engine never saw it), relink: the
        // old debug assert fired here.
        let vm = PlayerViewModel()
        let source = SoundSource(type: .sampleAsset, volume: 0.5, assetID: "user.never-reported")
        vm.activeSources = [source]

        vm.relinkSource(source)

        #expect(vm.activeSources.map(\.id) == [source.id])
    }

    @Test func relinkDropsOnlyThatAssetFromBanner() {
        let vm = PlayerViewModel()
        vm.recordMissingAsset("user.aaa")
        vm.recordMissingAsset("user.bbb")

        vm.handleUserAssetRelinked(assetID: "user.aaa")

        guard case .missingUserSounds(let count) = vm.activeWarning else {
            Issue.record("Banner should remain for the other missing sound")
            return
        }
        #expect(count == 1)

        vm.handleUserAssetRelinked(assetID: "user.bbb")
        #expect(vm.activeWarning == nil)
    }
}

// MARK: - handleUserAssetDeleted

@MainActor
struct UserAssetDeletedTests {

    @Test func deletingRemovesLayersPrunesBannerAndSavesSession() throws {
        preservingDefaults([sessionKey]) {
            let vm = PlayerViewModel()
            let doomed = SoundSource(type: .sampleAsset, volume: 0.5, assetID: "user.doomed")
            let brown = SoundSource(type: .brownNoise, volume: 0.4)
            let preset = Preset(name: "Mine", icon: "star", sources: [doomed, brown], isBuiltIn: false)
            vm.currentPreset = preset
            vm.activeSources = [doomed, brown]
            vm.recordMissingAsset("user.doomed")

            vm.handleUserAssetDeleted(assetID: "user.doomed")

            #expect(vm.activeSources.map(\.id) == [brown.id])
            #expect(vm.activeWarning == nil)
            #expect(vm.isCurrentPresetModified == false,
                    "A deleted import is dropped from the preset too, so it doesn't read as edited")

            let restored = PlayerViewModel()
            #expect(restored.restoreLastSession())
            #expect(restored.activeSources.map(\.id) == [brown.id], "Deletion must reach the saved session")
        }
    }

    @Test func deletingTheOnlyLayerStopsPlayback() throws {
        preservingDefaults([sessionKey]) {
            let vm = PlayerViewModel()
            vm.activeSources = [SoundSource(type: .sampleAsset, volume: 0.5, assetID: "user.solo")]
            vm.isPlaying = true

            vm.handleUserAssetDeleted(assetID: "user.solo")

            #expect(vm.activeSources.isEmpty)
            #expect(vm.isPlaying == false)
        }
    }
}

// MARK: - handlePresetRenamed

@MainActor
struct PresetRenamedTests {

    @Test func renamingCurrentPresetUpdatesHeaderNowPlayingAndSession() throws {
        preservingDefaults([sessionKey]) {
            let vm = PlayerViewModel()
            let preset = Preset(name: "Old Name", icon: "star",
                                sources: [SoundSource(type: .brownNoise, volume: 0.4)], isBuiltIn: false)
            vm.currentPreset = preset
            vm.activeSources = preset.sources

            vm.handlePresetRenamed(id: preset.id, newName: "New Name")

            #expect(vm.currentPreset?.name == "New Name")
            #expect(AudioEngine.shared.currentPresetName == "New Name")

            let restored = PlayerViewModel()
            #expect(restored.restoreLastSession())
            #expect(restored.currentPreset?.id == preset.id)
            #expect(restored.currentPreset?.name == "New Name", "Rename must survive relaunch")
        }
    }

    @Test func renamingAnotherPresetChangesNothing() {
        let vm = PlayerViewModel()
        let preset = Preset(name: "Mine", icon: "star", sources: [], isBuiltIn: false)
        vm.currentPreset = preset

        vm.handlePresetRenamed(id: UUID(), newName: "Other")

        #expect(vm.currentPreset?.name == "Mine")
    }
}

// MARK: - saveCurrentAsPreset

@MainActor
struct SaveCurrentAsPresetTests {

    @Test func savingSelectsTheNewPreset() throws {
        let env = try StateTestEnv.make()
        let vm = PlayerViewModel()
        vm.activeSources = [SoundSource(type: .brownNoise, volume: 0.4)]

        vm.saveCurrentAsPreset(name: "  Evening  ", icon: "moon.fill", context: env.context)

        let saved = try env.context.fetch(FetchDescriptor<SavedPreset>())
        #expect(saved.count == 1)
        #expect(vm.currentPreset?.id == saved.first?.stableID)
        #expect(vm.currentPreset?.name == "Evening")
        #expect(vm.currentPreset?.isBuiltIn == false)
        #expect(vm.isCurrentPresetModified == false)
        #expect(AudioEngine.shared.currentPresetName == "Evening")
    }

    @Test func whitespaceOnlyNameSavesNothing() throws {
        let env = try StateTestEnv.make()
        let vm = PlayerViewModel()
        vm.activeSources = [SoundSource(type: .brownNoise, volume: 0.4)]

        vm.saveCurrentAsPreset(name: "   ", icon: "star", context: env.context)

        #expect(try env.context.fetch(FetchDescriptor<SavedPreset>()).isEmpty)
        #expect(vm.currentPreset == nil)
    }
}

// MARK: - Lossy decode

@MainActor
struct LossyDecodeTests {

    private func jsonObject(_ source: SoundSource) throws -> Any {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(source))
    }

    @Test func lossyArraySkipsBadElementsOfAnyShape() throws {
        let good1 = SoundSource(type: .brownNoise, volume: 0.4)
        let good2 = SoundSource(type: .sampleAsset, volume: 0.6, assetID: "moodist.rain.light")
        let array: [Any] = [
            try jsonObject(good1),
            ["id": UUID().uuidString, "type": "Not A Real Type", "volume": 0.5] as [String: Any],
            42,
            NSNull(),
            "string",
            try jsonObject(good2),
        ]
        let data = try JSONSerialization.data(withJSONObject: array)

        let decoded = try JSONDecoder().decode(LossyDecodableArray<SoundSource>.self, from: data)

        #expect(decoded.elements.map(\.id) == [good1.id, good2.id])
        #expect(decoded.skippedCount == 4)
    }

    @Test func oneBadSourceDoesNotWipeTheSession() throws {
        try preservingDefaults([sessionKey]) {
            let good = SoundSource(type: .brownNoise, volume: 0.4)
            let presetID = UUID()
            let snapshot: [String: Any] = [
                "version": 1,
                "sources": [
                    try jsonObject(good),
                    ["id": UUID().uuidString, "type": "Future Sound", "volume": 0.5] as [String: Any],
                ] as [Any],
                "presetID": presetID.uuidString,
                "presetName": "Mine",
                "presetIcon": "star",
                "presetIsBuiltIn": false,
            ]
            UserDefaults.standard.set(try JSONSerialization.data(withJSONObject: snapshot), forKey: sessionKey)

            let vm = PlayerViewModel()
            #expect(vm.restoreLastSession())
            #expect(vm.activeSources.map(\.id) == [good.id])
            #expect(vm.currentPreset?.id == presetID)
            #expect(vm.currentPreset?.name == "Mine")
        }
    }

    @Test func legacyBareArrayIsLossyToo() throws {
        try preservingDefaults([sessionKey]) {
            let good = SoundSource(type: .pinkNoise, volume: 0.3)
            let legacy: [Any] = [["type": "Nope"], try jsonObject(good)]
            UserDefaults.standard.set(try JSONSerialization.data(withJSONObject: legacy), forKey: sessionKey)

            let vm = PlayerViewModel()
            #expect(vm.restoreLastSession())
            #expect(vm.activeSources.map(\.id) == [good.id])
        }
    }

    @Test func savedPresetKeepsGoodSourcesWhenOneIsBad() throws {
        let good = SoundSource(type: .brownNoise, volume: 0.4)
        let saved = SavedPreset(name: "Mine", icon: "star", sources: [good])
        let array: [Any] = [try jsonObject(good), ["type": 7]]
        saved.sourcesData = try JSONSerialization.data(withJSONObject: array)

        #expect(saved.sources.map(\.id) == [good.id],
                "One bad layer must not turn the preset empty")
    }
}

// MARK: - resolvedSceneList

@MainActor
struct ResolvedSceneListTests {

    private func builtIn(_ name: String) throws -> Preset {
        try #require(Preset.builtIn.first { $0.name == name })
    }

    @Test func defaultsMatchBuiltInOrder() {
        let list = Preset.resolvedSceneList(saved: [], hiddenIDs: [], renames: [:], order: [])
        #expect(list.map(\.id) == Preset.builtIn.map(\.id))
    }

    @Test func hiddenBuiltInsAreSkippedAndRenamesApply() throws {
        let focus = try builtIn("Focus")
        let sleep = try builtIn("Sleep")

        let list = Preset.resolvedSceneList(saved: [], hiddenIDs: [focus.id], renames: [sleep.id: "Night"], order: [])

        #expect(!list.contains { $0.id == focus.id })
        #expect(list.first { $0.id == sleep.id }?.name == "Night")
        #expect(list.count == Preset.builtIn.count - 1)
    }

    @Test func editedBuiltInTakesItsSlotEvenWhenHidden() throws {
        let calm = try builtIn("Calm")
        let edited = SavedPreset(name: "My Calm", icon: calm.icon, sources: [SoundSource(type: .whiteNoise)])
        edited.stableID = calm.id

        let list = Preset.resolvedSceneList(
            saved: [edited],
            hiddenIDs: [calm.id],
            renames: [calm.id: "Ignored Rename"], order: [])

        let index = try #require(Preset.builtIn.firstIndex { $0.id == calm.id })
        #expect(list.count == Preset.builtIn.count, "Override replaces the slot, isn't appended")
        #expect(list[index].id == calm.id)
        #expect(list[index].name == "My Calm", "The saved name wins over a built-in rename")
        #expect(list[index].isBuiltIn == false)
        #expect(list[index].sources.first?.type == .whiteNoise)
    }

    @Test func userPresetsFollowBuiltInsInGivenOrder() {
        let newer = SavedPreset(name: "Newer", icon: "star", sources: [])
        let older = SavedPreset(name: "Older", icon: "star", sources: [])

        let list = Preset.resolvedSceneList(saved: [newer, older], hiddenIDs: [], renames: [:], order: [])

        #expect(list.count == Preset.builtIn.count + 2)
        #expect(list.suffix(2).map(\.id) == [newer.stableID, older.stableID])
    }

    @Test func duplicateStableIDsResolveToFirstWithoutTrapping() throws {
        let cozy = try builtIn("Cozy")
        let firstOverride = SavedPreset(name: "Cozy A", icon: "star", sources: [])
        firstOverride.stableID = cozy.id
        let secondOverride = SavedPreset(name: "Cozy B", icon: "star", sources: [])
        secondOverride.stableID = cozy.id
        let user = SavedPreset(name: "Mine", icon: "star", sources: [])
        let userDuplicate = SavedPreset(name: "Mine Again", icon: "star", sources: [])
        userDuplicate.stableID = user.stableID

        let list = Preset.resolvedSceneList(
            saved: [firstOverride, secondOverride, user, userDuplicate],
            hiddenIDs: [],
            renames: [:], order: [])

        #expect(list.filter { $0.id == cozy.id }.map(\.name) == ["Cozy A"])
        #expect(list.filter { $0.id == user.stableID }.map(\.name) == ["Mine"])
        #expect(Set(list.map(\.id)).count == list.count, "Every scene appears once")
    }
}

// MARK: - Remote next/previous

@MainActor
struct CyclePresetTests {

    private static let prefsKeys = [PrefsKey.hiddenBuiltInPresets, PrefsKey.renamedBuiltInPresets, PrefsKey.sceneOrder]

    @Test func cyclingWalksIntoAndOutOfUserPresets() throws {
        try preservingDefaults(Self.prefsKeys) {
            let env = try StateTestEnv.make()
            let user = SavedPreset(name: "Mine", icon: "star", sources: [SoundSource(type: .brownNoise)])
            env.context.insert(user)
            try env.context.save()

            let vm = PlayerViewModel()
            vm.bindModelContext(env.context)

            let lastBuiltIn = try #require(Preset.builtIn.last)
            vm.currentPreset = lastBuiltIn
            #expect(vm.adjacentScene(forward: true)?.id == user.stableID,
                    "Next from the last built-in reaches the user preset")

            vm.currentPreset = user.toPreset()
            #expect(vm.adjacentScene(forward: true)?.id == Preset.builtIn.first?.id,
                    "Next from a user preset wraps to the first scene")
            #expect(vm.adjacentScene(forward: false)?.id == lastBuiltIn.id,
                    "Previous from a user preset steps back instead of jumping to the start")
        }
    }

    @Test func cyclingUsesEditedAndRenamedBuiltIns() throws {
        try preservingDefaults(Self.prefsKeys) {
            let focus = try #require(Preset.builtIn.first { $0.name == "Focus" })
            let deepWork = try #require(Preset.builtIn.first { $0.name == "Deep Work" })
            let renames = [deepWork.id: "Heads Down"]
            UserDefaults.standard.set(try JSONEncoder().encode(renames), forKey: PrefsKey.renamedBuiltInPresets)

            let env = try StateTestEnv.make()
            let edited = SavedPreset(name: "Focus Edit", icon: focus.icon,
                                     sources: [SoundSource(type: .pinkNoise, volume: 0.2)])
            edited.stableID = focus.id
            env.context.insert(edited)
            try env.context.save()

            let vm = PlayerViewModel()
            vm.bindModelContext(env.context)

            let first = try #require(vm.adjacentScene(forward: true))
            #expect(first.id == focus.id)
            #expect(first.name == "Focus Edit")
            #expect(first.sources.first?.type == .pinkNoise, "The edited mix plays, not the stock one")

            vm.currentPreset = first
            let second = try #require(vm.adjacentScene(forward: true))
            #expect(second.id == deepWork.id)
            #expect(second.name == "Heads Down")
        }
    }
}

// MARK: - Deleted user imports in presets and sessions

@MainActor
struct DeletedImportFilteringTests {

    private struct Fixture {
        let env: StateTestEnv
        let present: SoundSource
        let fileMissing: SoundSource
        let deleted: SoundSource
        let brown: SoundSource
    }

    private func makeFixture() throws -> Fixture {
        let env = try StateTestEnv.make()
        let keep = try env.library.importSound(
            from: env.makeAudioFixture(name: "keep", durationSeconds: 2.0), displayName: "Keep", category: .things)
        let lost = try env.library.importSound(
            from: env.makeAudioFixture(name: "lost", durationSeconds: 2.0), displayName: "Lost", category: .things)
        let gone = try env.library.importSound(
            from: env.makeAudioFixture(name: "gone", durationSeconds: 2.0), displayName: "Gone", category: .things)
        let goneAssetID = gone.assetID

        try FileManager.default.removeItem(at: env.library.url(for: lost))
        env.library.verify()
        env.library.delete(gone)

        return Fixture(
            env: env,
            present: SoundSource(type: .sampleAsset, volume: 0.5, assetID: keep.assetID),
            fileMissing: SoundSource(type: .sampleAsset, volume: 0.5, assetID: lost.assetID),
            deleted: SoundSource(type: .sampleAsset, volume: 0.5, assetID: goneAssetID),
            brown: SoundSource(type: .brownNoise, volume: 0.4)
        )
    }

    @Test func loadingAPresetDropsDeletedImportsButKeepsMissingFiles() throws {
        let f = try makeFixture()
        let vm = PlayerViewModel()
        vm.bindUserSoundLibrary(f.env.library)
        let bogus = SoundSource(type: .sampleAsset, volume: 0.5, assetID: "user.not-a-uuid")
        let preset = Preset(name: "Mixed", icon: "star",
                            sources: [f.present, f.fileMissing, f.deleted, bogus, f.brown], isBuiltIn: false)

        vm.replaceActiveSources(with: preset.sources, preset: preset)

        #expect(vm.activeSources.map(\.id) == [f.present.id, f.fileMissing.id, f.brown.id],
                "Deleted imports drop out; a record with a missing file stays for relink")
        #expect(vm.isCurrentPresetModified == false)
    }

    @Test func restoringASessionDropsDeletedImports() throws {
        try preservingDefaults([sessionKey]) {
            let f = try makeFixture()
            let writer = PlayerViewModel()
            writer.activeSources = [f.deleted, f.fileMissing, f.brown]
            writer.saveLastSession()

            let vm = PlayerViewModel()
            vm.bindUserSoundLibrary(f.env.library)
            #expect(vm.restoreLastSession())
            #expect(vm.activeSources.map(\.id) == [f.fileMissing.id, f.brown.id])
        }
    }

    @Test func sessionOfOnlyDeletedImportsDoesNotRestore() throws {
        try preservingDefaults([sessionKey]) {
            let f = try makeFixture()
            let writer = PlayerViewModel()
            writer.activeSources = [f.deleted]
            writer.saveLastSession()

            let vm = PlayerViewModel()
            vm.bindUserSoundLibrary(f.env.library)
            #expect(vm.restoreLastSession() == false)
            #expect(vm.activeSources.isEmpty)
        }
    }
}

// MARK: - Timer chime gating

@MainActor
struct TimerChimeGatingTests {

    @Test func chimeOnlyPlaysWhileActive() throws {
        preservingDefaults([sessionKey, "timerPlayChimeOnEnd", "timerEndDate", "timerDuration"]) {
            let vm = PlayerViewModel()
            vm.timerState.playChimeOnEnd = true
            #expect(vm.shouldChimeOnTimerEnd(wasPlaying: true))

            vm.handleScenePhaseChange(.background)
            #expect(vm.shouldChimeOnTimerEnd(wasPlaying: true) == false,
                    "In the background the notification sound already plays")

            vm.handleScenePhaseChange(.inactive)
            #expect(vm.shouldChimeOnTimerEnd(wasPlaying: true) == false)

            vm.handleScenePhaseChange(.active)
            #expect(vm.shouldChimeOnTimerEnd(wasPlaying: true))
            #expect(vm.shouldChimeOnTimerEnd(wasPlaying: false) == false)

            vm.timerState.playChimeOnEnd = false
            #expect(vm.shouldChimeOnTimerEnd(wasPlaying: true) == false)
        }
    }
}

// MARK: - Library: re-import of a missing record, atomic relink

@MainActor
struct LibraryReimportAndRelinkTests {

    @Test func reimportingAMissingFileRelinksTheExistingRecord() throws {
        let env = try StateTestEnv.make()
        let source = try env.makeAudioFixture(name: "ghost", durationSeconds: 2.0)
        let original = try env.library.importSound(from: source, displayName: "Ghost", category: .things)
        let originalID = original.id
        try FileManager.default.removeItem(at: env.library.url(for: original))
        env.library.verify()
        #expect(original.isMissing)

        var reported: [String] = []
        env.library.onMissingAssetReimported = { reported.append($0) }

        let result = try env.library.importSound(from: source, displayName: "Ghost Again", category: .water)

        #expect(result.id == originalID, "Same record, so presets and the mix keep resolving")
        #expect(result.isMissing == false)
        #expect(result.displayName == "Ghost Again")
        #expect(result.category == .water)
        #expect(env.library.assetsByID.count == 1, "No second record for the same file")
        #expect(FileManager.default.fileExists(atPath: env.library.url(for: result).path))
        #expect(reported == [result.assetID])
    }

    @Test func reimportRelinksEvenBeforeVerifyFlagsTheFile() throws {
        let env = try StateTestEnv.make()
        let source = try env.makeAudioFixture(name: "unverified", durationSeconds: 2.0)
        let original = try env.library.importSound(from: source, displayName: "Unverified", category: .things)
        try FileManager.default.removeItem(at: env.library.url(for: original))

        let result = try env.library.importSound(from: source, displayName: "", category: .things)

        #expect(result.id == original.id)
        #expect(result.displayName == "Unverified", "An empty name keeps the existing one")
        #expect(FileManager.default.fileExists(atPath: env.library.url(for: result).path))
    }

    @Test func reimportOfAPresentFileStillThrowsDuplicate() throws {
        let env = try StateTestEnv.make()
        let source = try env.makeAudioFixture(name: "present", durationSeconds: 2.0)
        _ = try env.library.importSound(from: source, displayName: "Present", category: .things)

        #expect(throws: UserSoundImportError.duplicate(existingDisplayName: "Present")) {
            try env.library.importSound(from: source, displayName: "Again", category: .things)
        }
    }

    @Test func reimportClearsTheViewModelBanner() throws {
        let env = try StateTestEnv.make()
        let source = try env.makeAudioFixture(name: "banner", durationSeconds: 2.0)
        let asset = try env.library.importSound(from: source, displayName: "Banner", category: .things)
        try FileManager.default.removeItem(at: env.library.url(for: asset))
        env.library.verify()

        let vm = PlayerViewModel()
        vm.bindUserSoundLibrary(env.library)
        vm.activeSources = [SoundSource(type: .sampleAsset, volume: 0.5, assetID: asset.assetID)]
        vm.recordMissingAsset(asset.assetID)
        guard case .missingUserSounds = vm.activeWarning else {
            Issue.record("Expected missing banner")
            return
        }

        _ = try env.library.importSound(from: source, displayName: "Banner", category: .things)

        #expect(vm.activeWarning == nil)
    }

    @Test func failedRelinkCopyLeavesOldFileAndRecordIntact() throws {
        let env = try StateTestEnv.make()
        let original = try env.library.importSound(
            from: env.makeAudioFixture(name: "orig", durationSeconds: 2.0), displayName: "Orig", category: .things)
        let oldURL = env.library.url(for: original)
        let oldFileName = original.fileName
        let replacement = try env.makeAudioFixture(name: "replacement", durationSeconds: 3.0)

        // Read-only storage: the copy into it fails.
        let fm = FileManager.default
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: env.storage.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: env.storage.path) }

        #expect(throws: UserSoundImportError.copyFailed) {
            try env.library.relink(original, to: replacement)
        }
        #expect(fm.fileExists(atPath: oldURL.path), "The old file must survive a failed relink")
        #expect(original.fileName == oldFileName)
        #expect(original.durationSeconds < 2.5)
    }

    @Test func successfulRelinkLeavesNoTempFiles() throws {
        let env = try StateTestEnv.make()
        let original = try env.library.importSound(
            from: env.makeAudioFixture(name: "first", durationSeconds: 2.0), displayName: "First", category: .things)
        let replacement = try env.makeAudioFixture(name: "second", durationSeconds: 3.0)

        try env.library.relink(original, to: replacement)

        let contents = try FileManager.default.contentsOfDirectory(atPath: env.storage.path)
        #expect(contents == [original.fileName])
        #expect(original.durationSeconds >= 2.9 && original.durationSeconds <= 3.1)
        #expect(UserSoundLibrary.hashFilePrefix(at: env.library.url(for: original))
                == UserSoundLibrary.hashFilePrefix(at: replacement))
    }
}

// MARK: - Helpers

@MainActor
private struct StateTestEnv {
    let library: UserSoundLibrary
    let context: ModelContext
    let tempDir: URL
    let storage: URL

    static func make() throws -> StateTestEnv {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hush-state-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let storage = tempDir.appendingPathComponent("UserSounds", isDirectory: true)
        let schema = Schema([SavedPreset.self, UserSoundAsset.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        let context = ModelContext(container)
        let library = UserSoundLibrary(modelContext: context, storageDirectory: storage)
        return StateTestEnv(library: library, context: context, tempDir: tempDir, storage: storage)
    }

    /// Short sine-wave WAV; frequency derives from `name` so different names
    /// hash differently and the same name hashes the same.
    func makeAudioFixture(name: String, durationSeconds: Double) throws -> URL {
        let url = tempDir.appendingPathComponent("\(name).wav")
        let sampleRate: Double = 44100
        let frameCount = AVAudioFrameCount(sampleRate * durationSeconds)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
              let dst = buffer.floatChannelData?[0] else {
            throw CocoaError(.fileWriteUnknown)
        }
        buffer.frameLength = frameCount
        let nameSeed = name.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        let freq = Float(220 + (abs(nameSeed) % 440))
        let twoPiF = 2 * Float.pi * freq / Float(sampleRate)
        for i in 0..<Int(frameCount) {
            dst[i] = sinf(twoPiF * Float(i)) * 0.2
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        return url
    }
}
