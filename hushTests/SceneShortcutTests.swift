import Foundation
import SwiftData
import Testing
@testable import hush

// Siri / Shortcuts "Play Scene": scene lookup by ID and by spoken name. Pure
// lookups only; nothing here starts the audio engine.

/// Snapshot and restore the scene-list defaults a test writes, so hides and
/// renames can't leak into other suites.
@MainActor
private func preservingSceneDefaults(_ body: () throws -> Void) rethrows {
    let keys = [PrefsKey.sceneOrder, PrefsKey.hiddenBuiltInPresets, PrefsKey.renamedBuiltInPresets]
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

@MainActor
private func makeContext() throws -> ModelContext {
    let schema = Schema([SavedPreset.self, UserSoundAsset.self])
    let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
    return ModelContext(try ModelContainer(for: schema, configurations: [config]))
}

@MainActor
private func preset(_ name: String, id: UUID = UUID()) -> Preset {
    Preset(id: id, name: name, icon: "star.fill",
           sources: [SoundSource(type: .pinkNoise, volume: 0.5)], isBuiltIn: false)
}

@MainActor
struct SceneLookupTests {
    private let focus = Preset.builtIn[0]

    @Test func findsBuiltInScene() {
        preservingSceneDefaults {
            let vm = PlayerViewModel()
            #expect(vm.scene(withID: focus.id)?.name == focus.name)
        }
    }

    @Test func renamedBuiltInPlaysUnderItsNewName() {
        preservingSceneDefaults {
            UserDefaults.standard.set(
                BuiltInSceneStore.encode([focus.id: "Morning Desk"]),
                forKey: PrefsKey.renamedBuiltInPresets
            )
            let vm = PlayerViewModel()
            #expect(vm.scene(withID: focus.id)?.name == "Morning Desk")
        }
    }

    @Test func hiddenBuiltInIsNotFound() {
        preservingSceneDefaults {
            UserDefaults.standard.set(
                BuiltInSceneStore.encode(Set([focus.id])),
                forKey: PrefsKey.hiddenBuiltInPresets
            )
            let vm = PlayerViewModel()
            #expect(vm.scene(withID: focus.id) == nil)
        }
    }

    @Test func findsSavedSceneThroughBoundContext() throws {
        try preservingSceneDefaults {
            let context = try makeContext()
            let saved = SavedPreset(name: "Night Shift", icon: "moon.fill",
                                    sources: [SoundSource(type: .brownNoise, volume: 0.4)])
            context.insert(saved)
            let vm = PlayerViewModel()
            vm.bindModelContext(context)
            let found = vm.scene(withID: saved.stableID)
            #expect(found?.name == "Night Shift")
            #expect(found?.isBuiltIn == false)
        }
    }

    @Test func deletedSceneLeavesTheMixAlone() {
        preservingSceneDefaults {
            let vm = PlayerViewModel()
            let mix = [SoundSource(type: .whiteNoise, volume: 0.3)]
            vm.replaceActiveSources(with: mix, preset: nil, animated: false)
            #expect(vm.playScene(id: UUID()) == nil)
            #expect(vm.activeSources.map(\.id) == mix.map(\.id))
            #expect(vm.currentPreset == nil)
            #expect(!vm.isPlaying)
        }
    }

    @Test func entityCarriesTheSceneIdentity() {
        let entity = SceneEntity(focus)
        #expect(entity.id == focus.id)
        #expect(entity.name == focus.name)
        #expect(entity.icon == focus.icon)
    }
}

@MainActor
struct SceneNameMatchingTests {
    @Test func exactNameSortsBeforePartialMatches() {
        let scenes = [preset("Gamma Focus"), preset("Focus"), preset("Sleep")]
        let names = SceneQuery.scenes(matching: "focus", in: scenes).map(\.name)
        #expect(names == ["Focus", "Gamma Focus"])
    }

    @Test func ignoresCaseAndDiacritics() {
        let scenes = [preset("Café Corner"), preset("Forest")]
        #expect(SceneQuery.scenes(matching: "CAFE", in: scenes).map(\.name) == ["Café Corner"])
    }

    @Test func blankQueryMatchesNothing() {
        let scenes = [preset("Focus")]
        #expect(SceneQuery.scenes(matching: "  ", in: scenes).isEmpty)
    }

    @Test func noMatchIsEmpty() {
        let scenes = [preset("Focus"), preset("Sleep")]
        #expect(SceneQuery.scenes(matching: "ocean", in: scenes).isEmpty)
    }
}
