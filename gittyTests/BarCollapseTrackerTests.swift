import CoreGraphics
import Testing
@testable import gitty

struct BarCollapseTrackerTests {
    private func scroll(_ tracker: inout BarCollapseTracker, _ offsets: [CGFloat], coasting: Bool = false) -> Bool? {
        var last: Bool?
        for offset in offsets {
            if let change = tracker.scrolled(to: offset, top: 0, bottom: 10_000, isUserScrolling: true,
                                             isCoasting: coasting) {
                last = change
            }
        }
        return last
    }

    @Test func scrollingDownCollapsesAndUpExpands() {
        var tracker = BarCollapseTracker()
        tracker.beginDrag(at: 100)
        #expect(scroll(&tracker, [105, 112, 120]) == true)
        #expect(scroll(&tracker, [115, 108, 100]) == false)
    }

    @Test func aCoastingFlingIgnoresTheListCorrectingItsOffset() {
        var tracker = BarCollapseTracker()
        tracker.beginDrag(at: 100)
        #expect(scroll(&tracker, [110, 130, 160]) == true)  // flicked down the list: collapsed
        // Coasting on, the list jumps back 40pt (content above grew), then keeps going down.
        #expect(scroll(&tracker, [400, 360, 420, 480], coasting: true) == nil)
        #expect(tracker.isCollapsed)
    }

    @Test func draggingUpIgnoresRowsAboveGrowing() {
        var tracker = BarCollapseTracker()
        tracker.beginDrag(at: 1000)
        // Dragging up the list, the bar expanded.
        for (offset, height) in [(CGFloat(990), CGFloat(5000)), (970, 5000), (950, 5000)] {
            _ = tracker.scrolled(to: offset, top: 0, bottom: 10_000, isUserScrolling: true, contentHeight: height)
        }
        #expect(!tracker.isCollapsed)
        // A row above came in 60pt taller than guessed: the list moved down by as much.
        #expect(tracker.scrolled(to: 1010, top: 0, bottom: 10_000, isUserScrolling: true,
                                 contentHeight: 5060) == nil)
        #expect(tracker.scrolled(to: 990, top: 0, bottom: 10_000, isUserScrolling: true,
                                 contentHeight: 5060) == nil)
        #expect(!tracker.isCollapsed)
    }

    @Test func draggingBackStillExpands() {
        var tracker = BarCollapseTracker()
        tracker.beginDrag(at: 100)
        #expect(scroll(&tracker, [110, 130]) == true)
        #expect(scroll(&tracker, [120, 100, 80]) == false)  // the finger, not a correction
    }

    @Test func theTopAlwaysShowsTheBar() {
        var tracker = BarCollapseTracker()
        tracker.isCollapsed = true
        #expect(tracker.scrolled(to: 0, top: 0, bottom: 10_000, isUserScrolling: true, isCoasting: true) == false)
    }
}
