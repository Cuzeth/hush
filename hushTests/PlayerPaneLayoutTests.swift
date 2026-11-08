import CoreGraphics
import Testing
@testable import hush

/// The player picks one column or two panes from size class, width and the
/// display's fold (iPhone Duo). Pure geometry, so no device or simulator.
struct PlayerPaneLayoutTests {

    private let minGutter = PlayerPaneLayout.minimumGutter

    @Test func compactWidthIsAlwaysOneColumn() {
        let fold = CGRect(x: 475, y: 0, width: 0, height: 669)
        #expect(PlayerPaneLayout.resolve(isRegularWidth: false, containerWidth: 951, folds: [fold]) == .singleColumn)
        #expect(PlayerPaneLayout.resolve(isRegularWidth: false, containerWidth: 1200, folds: []) == .singleColumn)
    }

    @Test func regularWidthWithoutFoldSplitsDownTheMiddle() {
        let layout = PlayerPaneLayout.resolve(isRegularWidth: true, containerWidth: 1000, folds: [])
        #expect(layout == .split(leading: 500 - minGutter / 2, gutter: minGutter, trailing: 500 - minGutter / 2))
    }

    @Test func tooNarrowForTwoPanesStaysOneColumn() {
        // Two 320pt panes plus the gutter don't fit in 600.
        #expect(PlayerPaneLayout.resolve(isRegularWidth: true, containerWidth: 600, folds: []) == .singleColumn)
    }

    @Test func flatFoldSplitsAtTheFoldWithMinimumGutter() {
        // Inner display opened like a book: a zero-width fold down the middle.
        let fold = CGRect(x: 475, y: 0, width: 0, height: 669)
        let layout = PlayerPaneLayout.resolve(isRegularWidth: true, containerWidth: 951, folds: [fold])
        #expect(layout == .split(leading: 475 - minGutter / 2, gutter: minGutter, trailing: 476 - minGutter / 2))
    }

    @Test func activeFoldWidensTheGutterToItsWidth() {
        // Partly folded: the crease has real width, and the panes clear it.
        let fold = CGRect(x: 455, y: 0, width: 40, height: 669)
        let layout = PlayerPaneLayout.resolve(isRegularWidth: true, containerWidth: 951, folds: [fold])
        #expect(layout == .split(leading: 455, gutter: 40, trailing: 456))
    }

    @Test func offCenterFoldGivesUnequalPanes() {
        // Asymmetric safe areas can shift the fold off the container's center.
        let fold = CGRect(x: 420, y: 0, width: 0, height: 669)
        guard case let .split(leading, gutter, trailing) =
            PlayerPaneLayout.resolve(isRegularWidth: true, containerWidth: 900, folds: [fold]) else {
            Issue.record("expected a split")
            return
        }
        #expect(leading + gutter / 2 == 420, "the gutter is centered on the fold")
        #expect(leading + gutter + trailing == 900, "panes and gutter fill the width")
        #expect(leading < trailing)
    }

    @Test func foldRunningAcrossTheScreenKeepsOneColumn() {
        // Inner display held upright: the fold is horizontal, so side-by-side
        // panes would each straddle it. Scrolling content may cross it.
        let fold = CGRect(x: 0, y: 475, width: 669, height: 0)
        #expect(PlayerPaneLayout.resolve(isRegularWidth: true, containerWidth: 669, folds: [fold]) == .singleColumn)
    }

    @Test func degenerateFoldFrameIsIgnored() {
        let layout = PlayerPaneLayout.resolve(isRegularWidth: true, containerWidth: 1000, folds: [.zero])
        #expect(layout == .split(leading: 500 - minGutter / 2, gutter: minGutter, trailing: 500 - minGutter / 2))
    }

    @Test func foldTooCloseToAnEdgeFallsBackToOneColumn() {
        // A pane on one side would be narrower than a level row needs.
        let fold = CGRect(x: 250, y: 0, width: 0, height: 669)
        #expect(PlayerPaneLayout.resolve(isRegularWidth: true, containerWidth: 951, folds: [fold]) == .singleColumn)
    }

    @Test func unmeasuredGeometryStartsAsOneColumn() {
        // Before the first measurement lands, width is 0.
        let empty = PlayerPaneGeometry()
        #expect(PlayerPaneLayout.resolve(isRegularWidth: true, containerWidth: empty.width, folds: empty.folds) == .singleColumn)
    }
}
