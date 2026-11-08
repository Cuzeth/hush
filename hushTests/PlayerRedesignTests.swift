import Foundation
import Testing
@testable import hush

// Player redesign: undo for a removed layer and the timer chip's remembered
// length. Like StateFixTests, nothing here starts the audio engine — the
// resume path is checked through `reinsertRemovedLayer`, the state half of
// `undoRemoveLayer`.

private let lastTimerDurationKey = "lastTimerDuration"
private let timerKeys = [lastTimerDurationKey, "timerEndDate", "timerDuration", "timerPlayChimeOnEnd"]
private let sessionKey = "lastSessionSources"

/// Snapshot, clear, and afterwards restore UserDefaults keys a test touches.
@MainActor
private func withCleanDefaults(_ keys: [String], _ body: () throws -> Void) rethrows {
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

private func layers(_ count: Int) -> [SoundSource] {
    let types: [SoundType] = [.whiteNoise, .pinkNoise, .brownNoise, .grayNoise, .pureTone, .drone]
    return (0..<count).map { SoundSource(type: types[$0 % types.count], volume: 0.5) }
}

// MARK: - Undo remove layer

@MainActor
struct UndoRemoveLayerTests {

    @Test func removeRecordsTheLayerAndItsIndex() throws {
        let vm = PlayerViewModel()
        let mix = layers(3)
        vm.activeSources = mix
        vm.updateVolume(for: mix[1], volume: 0.8)

        vm.removeSource(mix[1])

        let record = try #require(vm.lastRemovedLayer)
        #expect(record.source.id == mix[1].id)
        #expect(record.index == 1)
        #expect(record.source.volume == 0.8, "Undo restores the level the layer had at removal")
        #expect(record.stoppedPlayback == false)
    }

    @Test func eachRemovalGetsAFreshToastIdentity() throws {
        let vm = PlayerViewModel()
        let mix = layers(3)
        vm.activeSources = mix

        vm.removeSource(mix[0])
        let first = try #require(vm.lastRemovedLayer)
        vm.removeSource(mix[1])
        let second = try #require(vm.lastRemovedLayer)

        #expect(first.id != second.id)
        #expect(second.source.id == mix[1].id, "Only the newest removal is undoable")
    }

    @Test func undoReinsertsAtTheOriginalIndex() {
        let vm = PlayerViewModel()
        let mix = layers(4)
        vm.activeSources = mix

        vm.removeSource(mix[1])
        #expect(vm.activeSources.map(\.id) == [mix[0], mix[2], mix[3]].map(\.id))

        #expect(vm.undoRemoveLayer())
        #expect(vm.activeSources.map(\.id) == mix.map(\.id))
        #expect(vm.lastRemovedLayer == nil)
    }

    @Test func undoClampsTheIndexWhenTheMixShrank() {
        let vm = PlayerViewModel()
        let mix = layers(3)
        vm.activeSources = mix

        vm.removeSource(mix[2])
        // Something else shortened the mix meanwhile.
        vm.activeSources = [mix[0]]

        #expect(vm.undoRemoveLayer())
        #expect(vm.activeSources.map(\.id) == [mix[0].id, mix[2].id])
    }

    @Test func undoRespectsTheSourceCap() {
        let vm = PlayerViewModel()
        let mix = layers(AudioConstants.maxSimultaneousSources)
        vm.activeSources = mix

        vm.removeSource(mix[0])
        vm.addSource(.speechMasking)
        #expect(vm.activeSources.count == AudioConstants.maxSimultaneousSources)

        #expect(vm.undoRemoveLayer() == false)
        #expect(vm.activeSources.count == AudioConstants.maxSimultaneousSources)
        #expect(!vm.activeSources.contains { $0.id == mix[0].id })
        #expect(vm.lastRemovedLayer == nil, "A failed undo still clears the record")
    }

    @Test func undoResumesWhenRemovingTheLastLayerStoppedPlayback() throws {
        let vm = PlayerViewModel()
        let only = SoundSource(type: .brownNoise, volume: 0.5)
        vm.activeSources = [only]
        vm.isPlaying = true

        vm.removeSource(only)
        #expect(vm.isPlaying == false)
        #expect(try #require(vm.lastRemovedLayer).stoppedPlayback)

        #expect(vm.reinsertRemovedLayer() == .reinsertedResumingPlayback)
        #expect(vm.activeSources.map(\.id) == [only.id])
        #expect(vm.lastRemovedLayer == nil)
    }

    @Test func undoAfterAPausedRemovalDoesNotStartPlayback() {
        let vm = PlayerViewModel()
        let only = SoundSource(type: .brownNoise, volume: 0.5)
        vm.activeSources = [only]

        vm.removeSource(only)

        #expect(vm.lastRemovedLayer?.stoppedPlayback == false)
        #expect(vm.reinsertRemovedLayer() == .reinserted)
        #expect(vm.isPlaying == false)
    }

    @Test func undoWithNothingRemovedIsANoOp() {
        let vm = PlayerViewModel()
        let mix = layers(2)
        vm.activeSources = mix

        #expect(vm.undoRemoveLayer() == false)
        #expect(vm.activeSources.map(\.id) == mix.map(\.id))
    }

    @Test func loadPresetClearsTheRecord() {
        let vm = PlayerViewModel()
        let mix = layers(2)
        vm.activeSources = mix
        vm.removeSource(mix[0])
        #expect(vm.lastRemovedLayer != nil)

        // An empty scene keeps play() a no-op, so the engine stays off.
        vm.loadPreset(Preset(name: "Empty", icon: "star", sources: [], isBuiltIn: false))

        #expect(vm.lastRemovedLayer == nil)
        #expect(vm.undoRemoveLayer() == false)
    }

    @Test func clearSessionClearsTheRecord() {
        let vm = PlayerViewModel()
        let mix = layers(2)
        vm.activeSources = mix
        vm.removeSource(mix[0])

        vm.clearSession()

        #expect(vm.lastRemovedLayer == nil)
    }

    @Test func restoreLastSessionClearsTheRecord() {
        withCleanDefaults([sessionKey]) {
            let writer = PlayerViewModel()
            writer.activeSources = layers(2)
            writer.saveLastSession()

            let vm = PlayerViewModel()
            let mix = layers(2)
            vm.activeSources = mix
            vm.removeSource(mix[0])

            #expect(vm.restoreLastSession())
            #expect(vm.lastRemovedLayer == nil)
        }
    }

    @Test func discardDropsTheRecordWithoutRestoring() {
        let vm = PlayerViewModel()
        let mix = layers(2)
        vm.activeSources = mix
        vm.removeSource(mix[0])

        vm.discardRemovedLayer()

        #expect(vm.lastRemovedLayer == nil)
        #expect(vm.activeSources.map(\.id) == [mix[1].id])
    }
}

// MARK: - Last timer duration

@MainActor
struct LastTimerDurationTests {

    @Test func defaultsToTwentyFiveMinutes() {
        withCleanDefaults(timerKeys) {
            #expect(PlayerViewModel().lastTimerDuration == TimerDuration.twentyFive.seconds)
        }
    }

    @Test func startTimerRemembersAndPersistsTheLength() {
        withCleanDefaults(timerKeys) {
            let vm = PlayerViewModel()
            vm.startTimer(duration: 45 * 60)
            #expect(vm.lastTimerDuration == 45 * 60)

            vm.stopTimer()
            #expect(vm.lastTimerDuration == 45 * 60, "Cancelling keeps the remembered length")

            #expect(PlayerViewModel().lastTimerDuration == 45 * 60, "Survives relaunch")
        }
    }

    @Test func chipLabelIsWholeMinutes() {
        #expect(TimerChip.shortLabel(for: 25 * 60) == "25m")
        #expect(TimerChip.shortLabel(for: 90 * 60) == "90m")
        #expect(TimerChip.shortLabel(for: 20) == "1m", "Never reads 0m")
    }
}
