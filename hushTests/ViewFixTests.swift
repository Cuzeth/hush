import Foundation
import SwiftData
import Testing
@testable import hush

// Pure helpers extracted from the views during the UI/accessibility pass.

// MARK: - Scene ordering

@MainActor
struct SceneOrderingTests {
    /// Stand-in for SavedPreset so ordering is testable without SwiftData.
    private struct FakeSaved {
        let id: UUID
        let preset: Preset
    }

    private func saved(id: UUID = UUID(), name: String, isBuiltIn: Bool = false) -> FakeSaved {
        FakeSaved(id: id, preset: Preset(id: id, name: name, icon: "star.fill",
                                         sources: [SoundSource(type: .pinkNoise, volume: 0.5)],
                                         isBuiltIn: isBuiltIn))
    }

    private func order(_ saved: [FakeSaved], hidden: Set<UUID> = [], renamed: [UUID: String] = [:])
        -> [(preset: Preset, saved: FakeSaved?)] {
        SceneOrdering.ordered(saved: saved, stableID: \.id, toPreset: \.preset,
                              hidden: hidden, renamed: renamed)
    }

    @Test func untouchedListIsBuiltInsInOrder() {
        let result = order([])
        #expect(result.map(\.preset.id) == Preset.builtIn.map(\.id))
        #expect(result.allSatisfy { $0.saved == nil })
    }

    @Test func hiddenBuiltInsAreSkipped() {
        let first = Preset.builtIn[0]
        let result = order([], hidden: [first.id])
        #expect(!result.contains { $0.preset.id == first.id })
        // The first visible scene (what onboarding plays) moves down a slot.
        #expect(result.first?.preset.id == Preset.builtIn[1].id)
    }

    @Test func renamesApplyToBuiltIns() {
        let first = Preset.builtIn[0]
        let result = order([], renamed: [first.id: "Morning"])
        #expect(result.first?.preset.name == "Morning")
        #expect(result.first?.preset.id == first.id)
    }

    @Test func editedBuiltInTakesItsSlot() {
        let second = Preset.builtIn[1]
        let edited = saved(id: second.id, name: "Deeper Work")
        let result = order([edited])
        #expect(result.count == Preset.builtIn.count)
        #expect(result[1].preset.name == "Deeper Work")
        #expect(result[1].saved?.id == second.id)
    }

    @Test func userScenesFollowBuiltIns() {
        let mine = saved(name: "Mine")
        let result = order([mine])
        #expect(result.count == Preset.builtIn.count + 1)
        #expect(result.last?.preset.id == mine.id)
    }

    @Test func duplicateStableIDsDoNotTrap() {
        let builtInID = Preset.builtIn[0].id
        let userID = UUID()
        let result = order([
            saved(id: builtInID, name: "Newest edit"),
            saved(id: builtInID, name: "Older edit"),
            saved(id: userID, name: "Mine"),
            saved(id: userID, name: "Mine again"),
        ])
        // First wins (the newest, given the @Query sort), and each id once.
        #expect(result.first?.preset.name == "Newest edit")
        #expect(result.filter { $0.preset.id == userID }.map(\.preset.name) == ["Mine"])
        #expect(Set(result.map(\.preset.id)).count == result.count)
    }
}

// MARK: - Built-in scene store

@MainActor
struct BuiltInSceneStoreTests {
    private func makeDefaults() -> (UserDefaults, String) {
        let suite = "hush-tests-\(UUID().uuidString)"
        return (UserDefaults(suiteName: suite)!, suite)
    }

    @Test func codecRoundTrips() {
        let ids: Set<UUID> = [UUID(), UUID()]
        #expect(BuiltInSceneStore.decodeHidden(BuiltInSceneStore.encode(ids)) == ids)

        let renamed = [UUID(): "Morning"]
        #expect(BuiltInSceneStore.decodeRenamed(BuiltInSceneStore.encode(renamed)) == renamed)

        #expect(BuiltInSceneStore.decodeHidden(Data()).isEmpty)
        #expect(BuiltInSceneStore.decodeRenamed(Data("junk".utf8)).isEmpty)
    }

    @Test func unhideRemovesOnlyThatScene() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let kept = UUID()
        let undone = UUID()
        defaults.set(BuiltInSceneStore.encode(Set([kept, undone])), forKey: PrefsKey.hiddenBuiltInPresets)

        BuiltInSceneStore.unhide(undone, in: defaults)

        #expect(BuiltInSceneStore.hidden(in: defaults) == [kept])
    }

    @Test func unhideLeavesRenamesAlone() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let id = UUID()
        defaults.set(BuiltInSceneStore.encode(Set([id])), forKey: PrefsKey.hiddenBuiltInPresets)
        defaults.set(BuiltInSceneStore.encode([id: "Morning"]), forKey: PrefsKey.renamedBuiltInPresets)

        BuiltInSceneStore.unhide(id, in: defaults)

        #expect(BuiltInSceneStore.hidden(in: defaults).isEmpty)
        #expect(BuiltInSceneStore.renamed(in: defaults) == [id: "Morning"])
    }
}

// MARK: - Edit-save path

@MainActor
struct ScenePersistenceTests {
    private func makeContext() throws -> ModelContext {
        let schema = Schema([SavedPreset.self, UserSoundAsset.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        return ModelContext(container)
    }

    private let newSources = [SoundSource(type: .whiteNoise, volume: 0.3)]

    @Test func editingABuiltInStoresASavedVersionUnderItsID() throws {
        let context = try makeContext()
        let builtIn = Preset.builtIn[0]

        ScenePersistence.saveEdited(builtIn, sources: newSources,
                                    renamedBuiltIns: [builtIn.id: "Morning"], context: context)

        let all = try context.fetch(FetchDescriptor<SavedPreset>())
        #expect(all.count == 1)
        #expect(all.first?.stableID == builtIn.id)
        #expect(all.first?.name == "Morning")
        #expect(all.first?.sources == newSources)
    }

    @Test func editingASavedSceneUpdatesItInPlace() throws {
        let context = try makeContext()
        let existing = SavedPreset(name: "Mine", icon: "star.fill",
                                   sources: [SoundSource(type: .brownNoise, volume: 0.5)])
        context.insert(existing)

        let wrote = ScenePersistence.saveEdited(existing.toPreset(), sources: newSources,
                                                renamedBuiltIns: [:], context: context)

        let all = try context.fetch(FetchDescriptor<SavedPreset>())
        #expect(wrote)
        #expect(all.count == 1)
        #expect(all.first?.sources == newSources)
        #expect(all.first?.name == "Mine")
    }

    @Test func aDeletedSavedSceneIsNotRecreated() throws {
        let context = try makeContext()
        let gone = Preset(id: UUID(), name: "Gone", icon: "star.fill", sources: [], isBuiltIn: false)

        let wrote = ScenePersistence.saveEdited(gone, sources: newSources,
                                                renamedBuiltIns: [:], context: context)

        #expect(!wrote)
        #expect(try context.fetch(FetchDescriptor<SavedPreset>()).isEmpty)
    }
}

// MARK: - Sound picker

@MainActor
struct SoundSearchTests {
    @Test func legacyTypedSourcesCountAsTheirDefaultAsset() {
        let ids = SoundSearch.activeAssetIDs(in: [
            SoundSource(type: .rain, volume: 0.4),
            SoundSource(type: .sampleAsset, volume: 0.5, assetID: "moodist.rain.heavy"),
            SoundSource(type: .brownNoise, volume: 0.6),
        ])
        #expect(ids == ["sample.rain.calming", "moodist.rain.heavy"])
    }

    @Test func matchingIgnoresCaseDiacriticsAndPadding() {
        #expect(SoundSearch.matches("Heavy Rain", query: "rain"))
        #expect(SoundSearch.matches("Heavy Rain", query: "  HEAVY "))
        #expect(SoundSearch.matches("Café", query: "cafe"))
        #expect(!SoundSearch.matches("Heavy Rain", query: "ocean"))
    }

    @Test func emptyQueryMatchesEverything() {
        #expect(SoundSearch.matches("Anything", query: ""))
        #expect(SoundSearch.matches("Anything", query: "   "))
        #expect(SoundSearch.filter(SoundAssetRegistry.bundled, query: " ").count == SoundAssetRegistry.bundled.count)
    }

    @Test func filterSearchesAcrossCategories() {
        let results = SoundSearch.filter(SoundAssetRegistry.bundled, query: "rain")
        #expect(!results.isEmpty)
        #expect(results.allSatisfy { $0.displayName.localizedStandardContains("rain") })
    }
}

// MARK: - Timer speech

@MainActor
struct TimerSpeechTests {
    private let english = Locale(identifier: "en_US")

    @Test func readsMinutesAndSeconds() {
        #expect(TimerSpeech.remaining(1499, locale: english) == "24 minutes, 59 seconds remaining")
    }

    @Test func floorsLikeTheOnScreenCountdown() {
        #expect(TimerSpeech.duration(1499.8, locale: english) == "24 minutes, 59 seconds")
    }

    @Test func dropsZeroUnits() {
        #expect(TimerSpeech.duration(3600, locale: english) == "1 hour")
        #expect(TimerSpeech.duration(90, locale: english) == "1 minute, 30 seconds")
    }

    @Test func neverGoesNegative() {
        let spoken = TimerSpeech.duration(-5, locale: english)
        #expect(spoken.contains("0"))
        #expect(!spoken.contains("-"))
    }
}

// MARK: - Onboarding handoff

@MainActor
struct OnboardingHandoffTests {
    @Test func requestIsConsumedOnce() {
        _ = OnboardingHandoff.consumeStartFirstScene()
        #expect(OnboardingHandoff.consumeStartFirstScene() == false)

        OnboardingHandoff.requestStartFirstScene()
        #expect(OnboardingHandoff.consumeStartFirstScene())
        #expect(OnboardingHandoff.consumeStartFirstScene() == false)
    }
}
