import Foundation
import SwiftUI
import Testing
@testable import hush

// Scene swaps: the mix generation the layer lists key on, and the scroll
// compensation that keeps the scene list still while the panels above it
// resize. Nothing here starts the audio engine.

private func layers(_ count: Int) -> [SoundSource] {
    let types: [SoundType] = [.whiteNoise, .pinkNoise, .brownNoise, .grayNoise, .pureTone, .drone]
    return (0..<count).map { SoundSource(type: types[$0 % types.count], volume: 0.5) }
}

// MARK: - Mix generation

@MainActor
struct MixGenerationTests {

    @Test func everyWholeMixSwapBumpsTheGeneration() {
        let vm = PlayerViewModel()
        let start = vm.mixGeneration
        vm.replaceActiveSources(with: layers(2), preset: nil)
        #expect(vm.mixGeneration == start + 1)
        vm.replaceActiveSources(with: layers(4), preset: nil, animated: false)
        #expect(vm.mixGeneration == start + 2)
    }

    @Test func swappingToTheSameLayerCountStillBumps() {
        // Two Random Mixes of the same size are still two different mixes:
        // the rows must be replaced, not reused.
        let vm = PlayerViewModel()
        vm.replaceActiveSources(with: layers(3), preset: nil)
        let before = vm.mixGeneration
        vm.replaceActiveSources(with: layers(3), preset: nil)
        #expect(vm.mixGeneration == before + 1)
    }

    @Test func addingOrRemovingALayerKeepsTheGeneration() {
        // Edits within a mix animate row by row; only swaps re-key the list.
        let vm = PlayerViewModel()
        vm.replaceActiveSources(with: layers(2), preset: nil)
        let before = vm.mixGeneration
        vm.addSource(.brownNoise)
        #expect(vm.mixGeneration == before)
        vm.removeSource(vm.activeSources[0])
        #expect(vm.mixGeneration == before)
    }
}

// MARK: - Scene list anchor

@MainActor
struct SceneListAnchorTests {

    /// A phone-sized scroll view: 1400pt of content in a 700pt viewport,
    /// 140pt of top inset (large title), 100pt of bottom inset (transport).
    private func geometry(offsetY: CGFloat, contentHeight: CGFloat = 1400) -> ScrollGeometry {
        ScrollGeometry(
            contentOffset: CGPoint(x: 0, y: offsetY),
            contentSize: CGSize(width: 390, height: contentHeight),
            contentInsets: EdgeInsets(top: 140, leading: 0, bottom: 100, trailing: 0),
            containerSize: CGSize(width: 390, height: 700)
        )
    }

    @Test func unarmedGrowthMovesNothing() {
        let anchor = SceneListAnchor()
        anchor.geometry = geometry(offsetY: 300)
        #expect(anchor.compensatedOffset(forGrowth: 88) == nil)
    }

    @Test func armedGrowthScrollsByTheSameAmount() {
        let anchor = SceneListAnchor()
        anchor.geometry = geometry(offsetY: 300)
        anchor.armForSceneSwap()
        #expect(anchor.compensatedOffset(forGrowth: 88) == 388)
        #expect(anchor.compensatedOffset(forGrowth: -44) == 256)
    }

    @Test func armingExpires() {
        let anchor = SceneListAnchor()
        anchor.geometry = geometry(offsetY: 300)
        let tap = Date()
        anchor.armForSceneSwap(now: tap)
        let late = tap.addingTimeInterval(SceneListAnchor.window + 0.01)
        #expect(anchor.compensatedOffset(forGrowth: 88, now: late) == nil)
    }

    @Test func subpixelChangesAreIgnored() {
        let anchor = SceneListAnchor()
        anchor.geometry = geometry(offsetY: 300)
        anchor.armForSceneSwap()
        #expect(anchor.compensatedOffset(forGrowth: 0.2) == nil)
    }

    @Test func shrinkingAtTheTopStopsAtTheTop() {
        // Already at the top (offset == -inset): nothing above to give back.
        let anchor = SceneListAnchor()
        anchor.geometry = geometry(offsetY: -140)
        anchor.armForSceneSwap()
        #expect(anchor.compensatedOffset(forGrowth: -88) == -140)
    }

    @Test func neverScrollsPastTheEndOfTheResizedContent() {
        // Max offset after shrinking 100pt: 1300 + 100 - 700 = 700.
        let anchor = SceneListAnchor()
        anchor.geometry = geometry(offsetY: 790)
        anchor.armForSceneSwap()
        #expect(anchor.compensatedOffset(forGrowth: -100) == 690)
        anchor.geometry = geometry(offsetY: 800)
        #expect(anchor.compensatedOffset(forGrowth: -50) == 750)
    }

    @Test func noGeometryYetMeansNoScroll() {
        let anchor = SceneListAnchor()
        anchor.armForSceneSwap()
        #expect(anchor.compensatedOffset(forGrowth: 88) == nil)
    }
}
