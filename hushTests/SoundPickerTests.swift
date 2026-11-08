import Foundation
import Testing
@testable import hush

// Add Sound picker: the Recent row store and the long-press preview.

// MARK: - Recent sounds

@MainActor
struct RecentSoundsTests {
    private func makeDefaults() -> (UserDefaults, String) {
        let suite = "hush-tests-\(UUID().uuidString)"
        return (UserDefaults(suiteName: suite)!, suite)
    }

    private let rain = SoundAssetRegistry.bundled[0]
    private let thunder = SoundAssetRegistry.bundled[1]

    @Test func newestFirst() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let recents = RecentSounds(defaults: defaults)

        recents.record(.asset(rain))
        recents.record(.generated(.brownNoise))
        recents.record(.asset(thunder))

        #expect(recents.entries == [thunder.id, "Brown Noise", rain.id])
    }

    @Test func storesAssetIDsAndTypeRawValuesAndPersists() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        RecentSounds(defaults: defaults).record(.generated(.pinkNoise))
        RecentSounds(defaults: defaults).record(.asset(rain))

        #expect(defaults.stringArray(forKey: RecentSounds.storageKey) == [rain.id, SoundType.pinkNoise.rawValue])
        #expect(RecentSounds(defaults: defaults).entries == [rain.id, SoundType.pinkNoise.rawValue])
    }

    @Test func reAddingMovesToTheFrontWithoutDuplicating() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let recents = RecentSounds(defaults: defaults)

        recents.record(.asset(rain))
        recents.record(.generated(.whiteNoise))
        recents.record(.asset(rain))

        #expect(recents.entries == [rain.id, "White Noise"])
    }

    @Test func keepsOnlyTheLastEight() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let recents = RecentSounds(defaults: defaults)
        let assets = Array(SoundAssetRegistry.bundled.prefix(10))

        for asset in assets { recents.record(.asset(asset)) }

        #expect(RecentSounds.limit == 8)
        #expect(recents.entries == assets.suffix(8).reversed().map(\.id))
    }

    @Test func insertingIsPure() {
        #expect(RecentSounds.inserting("a", into: []) == ["a"])
        #expect(RecentSounds.inserting("b", into: ["a", "b", "c"]) == ["b", "a", "c"])
        let full = (1...8).map { "s\($0)" }
        #expect(RecentSounds.inserting("new", into: full) == ["new"] + full.prefix(7))
    }

    @Test func skipsEntriesThatNoLongerResolve() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let deletedImport = "user.\(UUID().uuidString)"
        defaults.set([
            deletedImport,                       // import deleted from the library
            "moodist.removed.asset",             // asset dropped from the bundle
            rain.id,
            SoundType.rain.rawValue,             // legacy type, never stored by the picker
            SoundType.sampleAsset.rawValue,
            "Not A Sound",
            SoundType.drone.rawValue,
        ], forKey: RecentSounds.storageKey)
        let recents = RecentSounds(defaults: defaults)

        // Bundled lookup only, so the test doesn't depend on the host app's
        // user-library hook; the deleted import resolves to nothing.
        let visible = recents.visible(excluding: []) { id in
            id.hasPrefix("user.") ? nil : SoundAssetRegistry.asset(withID: id)
        }

        #expect(visible.map(\.id) == [rain.id, SoundType.drone.rawValue])
        // Display-only: storage still holds everything for next time.
        #expect(recents.entries.count == 7)
    }

    @Test func skipsEntriesAlreadyInTheMix() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let recents = RecentSounds(defaults: defaults)
        let calming = SoundAssetRegistry.asset(withID: "sample.rain.calming")!
        recents.record(.asset(thunder))
        recents.record(.generated(.brownNoise))
        recents.record(.asset(calming))
        recents.record(.generated(.pinkNoise))

        let mix = [
            SoundSource(type: .brownNoise, volume: 0.5),
            // Legacy-typed source: plays its default asset, so that asset is in the mix.
            SoundSource(type: .rain, volume: 0.5),
        ]
        let visible = recents.visible(excluding: mix)

        #expect(visible.map(\.id) == [SoundType.pinkNoise.rawValue, thunder.id])
        // Taking a sound out of the mix brings it back to the row.
        #expect(recents.visible(excluding: []).count == 4)
    }

    @Test func resolvesImportsThroughTheInjectedLookup() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let imported = SoundAsset(id: "user.\(UUID().uuidString)", displayName: "My Fan", category: .things,
                                  fileName: "fan.m4a", fileExtension: "", subdirectory: "",
                                  license: .userImported, crossfadeStyle: .stochastic, isMono: false,
                                  absolutePath: "/tmp/fan.m4a")
        let recents = RecentSounds(defaults: defaults)
        recents.record(.asset(imported))

        let found = recents.visible(excluding: []) { $0 == imported.id ? imported : nil }
        let gone = recents.visible(excluding: []) { _ in nil }

        #expect(found == [.asset(imported)])
        #expect(gone.isEmpty)
    }
}

// MARK: - Preview state machine

@MainActor
struct SoundPreviewStateTests {
    @Test func startsFromIdle() {
        let (state, effects) = SoundPreviewState.idle.handling(.toggle(id: "a"))
        #expect(state == .previewing(id: "a"))
        #expect(effects == [.startPlayback(id: "a")])
    }

    @Test func anotherCardSwitches() {
        let (state, effects) = SoundPreviewState.previewing(id: "a").handling(.toggle(id: "b"))
        #expect(state == .previewing(id: "b"))
        #expect(effects == [.stopPlayback, .startPlayback(id: "b")])
    }

    @Test func sameCardTogglesOff() {
        let (state, effects) = SoundPreviewState.previewing(id: "a").handling(.toggle(id: "a"))
        #expect(state == .idle)
        #expect(effects == [.stopPlayback])
    }

    @Test func timeLimitEndsOnlyItsOwnPreview() {
        let ended = SoundPreviewState.previewing(id: "a").handling(.timeLimitReached(id: "a"))
        #expect(ended.state == .idle)
        #expect(ended.effects == [.stopPlayback])

        let stale = SoundPreviewState.previewing(id: "b").handling(.timeLimitReached(id: "a"))
        #expect(stale.state == .previewing(id: "b"))
        #expect(stale.effects.isEmpty)
    }

    @Test func stopAndFailureReturnToIdle() {
        #expect(SoundPreviewState.previewing(id: "a").handling(.stop).state == .idle)
        #expect(SoundPreviewState.previewing(id: "a").handling(.playbackFailed(id: "a")).state == .idle)
        #expect(SoundPreviewState.idle.handling(.stop).state == .idle)
        #expect(SoundPreviewState.idle.handling(.stop).effects.isEmpty)
        #expect(SoundPreviewState.idle.handling(.timeLimitReached(id: "a")).effects.isEmpty)
    }
}

// MARK: - Preview player

@MainActor
private final class FakePlayback: SoundPreviewPlayback {
    let url: URL
    var playResult = true
    private(set) var plays: [(volume: Float, fadeIn: TimeInterval)] = []
    private(set) var stops: [TimeInterval] = []

    init(url: URL) { self.url = url }

    func play(volume: Float, fadeIn: TimeInterval) -> Bool {
        plays.append((volume, fadeIn))
        return playResult
    }

    func stop(fadeOut: TimeInterval) { stops.append(fadeOut) }
}

@MainActor
private final class FakeScheduler {
    struct Timer {
        let delay: TimeInterval
        let action: @MainActor () -> Void
        var isCancelled = false
    }

    private(set) var timers: [Timer] = []

    func schedule(_ delay: TimeInterval, _ action: @escaping @MainActor () -> Void) -> () -> Void {
        timers.append(Timer(delay: delay, action: action))
        let index = timers.count - 1
        return { [weak self] in self?.timers[index].isCancelled = true }
    }

    /// Runs the timer even if it was cancelled, to prove stale fires are harmless.
    func fire(_ index: Int) { timers[index].action() }
}

@MainActor
struct SoundPreviewPlayerTests {
    private let scheduler = FakeScheduler()
    private let urlA = URL(fileURLWithPath: "/sounds/a.mp3")
    private let urlB = URL(fileURLWithPath: "/sounds/b.mp3")

    /// The player, plus every playback it created, in order.
    private func makePlayer(playResult: Bool = true, throwing: Bool = false)
        -> (SoundPreviewPlayer, () -> [FakePlayback]) {
        var created: [FakePlayback] = []
        let scheduler = scheduler
        let player = SoundPreviewPlayer(
            makePlayback: { url in
                struct OpenFailed: Error {}
                if throwing { throw OpenFailed() }
                let playback = FakePlayback(url: url)
                playback.playResult = playResult
                created.append(playback)
                return playback
            },
            schedule: { scheduler.schedule($0, $1) }
        )
        return (player, { created })
    }

    @Test func startPlaysTheFileWithFadesAndATimeLimit() {
        let (player, created) = makePlayer()

        let result = player.toggle(id: "a", url: urlA)

        #expect(result == .started)
        #expect(player.previewingID == "a")
        #expect(created().map(\.url) == [urlA])
        #expect(created()[0].plays.first?.volume == SoundPreviewPlayer.volume)
        #expect(created()[0].plays.first?.fadeIn == 0.3)
        // Fade-out starts early enough to be silent at ~6 s.
        #expect(scheduler.timers.map(\.delay) == [SoundPreviewPlayer.duration - SoundPreviewPlayer.fadeDuration])
        #expect(SoundPreviewPlayer.duration == 6)
    }

    @Test func anotherPreviewReplacesTheFirst() {
        let (player, created) = makePlayer()
        player.toggle(id: "a", url: urlA)

        let result = player.toggle(id: "b", url: urlB)

        #expect(result == .started)
        #expect(player.previewingID == "b")
        #expect(created()[0].stops == [0.3])
        #expect(created()[1].url == urlB)
        #expect(created()[1].stops.isEmpty)
        #expect(scheduler.timers[0].isCancelled)
    }

    @Test func secondLongPressOnTheSameCardStopsIt() {
        let (player, created) = makePlayer()
        player.toggle(id: "a", url: urlA)

        let result = player.toggle(id: "a", url: urlA)

        #expect(result == .stopped)
        #expect(player.state == .idle)
        #expect(created().count == 1)
        #expect(created()[0].stops == [0.3])
        #expect(scheduler.timers[0].isCancelled)
    }

    @Test func timeLimitFadesOutAndReturnsToIdle() {
        let (player, created) = makePlayer()
        player.toggle(id: "a", url: urlA)

        scheduler.fire(0)

        #expect(player.state == .idle)
        #expect(created()[0].stops == [0.3])
    }

    @Test func aStaleTimerCannotEndANewerPreview() {
        let (player, created) = makePlayer()
        player.toggle(id: "a", url: urlA)
        player.toggle(id: "a", url: urlA)   // off
        player.toggle(id: "a", url: urlA)   // on again, new timer

        scheduler.fire(0)                   // the first preview's timer

        #expect(player.previewingID == "a")
        #expect(created()[1].stops.isEmpty)

        scheduler.fire(1)
        #expect(player.state == .idle)
    }

    @Test func addingASoundStopsThePreviewAndRecordsIt() {
        let suite = "hush-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let recents = RecentSounds(defaults: defaults)
        let (player, created) = makePlayer()
        let asset = SoundAssetRegistry.bundled[0]
        player.toggle(id: asset.id, url: urlA)
        #expect(player.previewingID == asset.id)
        var added: [SoundAsset] = []

        SoundPickerGrid.add(.asset(asset), preview: player, recents: recents,
                            onSelect: { _ in Issue.record("generated callback for an asset") },
                            onSelectAsset: { added.append($0) })

        #expect(player.state == .idle)
        #expect(created().first?.stops == [0.3])
        #expect(added == [asset])
        #expect(recents.entries == [asset.id])
    }

    @Test func addingAGeneratedSoundUsesTheTypeCallback() {
        let suite = "hush-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let recents = RecentSounds(defaults: defaults)
        let (player, _) = makePlayer()
        var added: [SoundType] = []

        SoundPickerGrid.add(.generated(.grayNoise), preview: player, recents: recents,
                            onSelect: { added.append($0) },
                            onSelectAsset: { _ in Issue.record("asset callback for a generator") })

        #expect(added == [.grayNoise])
        #expect(recents.entries == [SoundType.grayNoise.rawValue])
    }

    @Test func stopWhenIdleIsHarmless() {
        let (player, created) = makePlayer()
        player.stop()
        #expect(player.state == .idle)
        #expect(created().isEmpty)
    }

    @Test func missingFileHasNoPreview() {
        let (player, created) = makePlayer()

        let result = player.toggle(id: "user.gone", url: nil)

        #expect(result == .unavailable)
        #expect(player.state == .idle)
        #expect(created().isEmpty)
        #expect(scheduler.timers.isEmpty)
    }

    @Test func unreadableOrUnplayableFilesFallBackToIdle() {
        let (throwing, _) = makePlayer(throwing: true)
        #expect(throwing.toggle(id: "a", url: urlA) == .unavailable)
        #expect(throwing.state == .idle)

        let (silent, created) = makePlayer(playResult: false)
        #expect(silent.toggle(id: "a", url: urlA) == .unavailable)
        #expect(silent.state == .idle)
        #expect(created().count == 1)
    }

    @Test func failedSwitchStillStopsTheOldPreview() {
        let (player, created) = makePlayer()
        player.toggle(id: "a", url: urlA)

        #expect(player.toggle(id: "b", url: nil) == .unavailable)
        #expect(player.state == .idle)
        #expect(created()[0].stops == [0.3])
    }

    @Test func urlIsOnlyResolvedWhenStarting() {
        let (player, _) = makePlayer()
        var resolutions = 0
        func resolve() -> URL? { resolutions += 1; return urlA }

        player.toggle(id: "a", url: resolve())
        player.toggle(id: "a", url: resolve())   // stopping

        #expect(resolutions == 1)
    }
}
