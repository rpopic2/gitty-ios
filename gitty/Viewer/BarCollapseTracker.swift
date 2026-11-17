import CoreGraphics

/// Decides when the bottom bar collapses and expands while scrolling, like Safari.
///
/// - Scrolling down about 10pt collapses it, and scrolling up about 10pt expands it.
/// - It is always expanded at the top and at the end of the content.
/// - After the reader taps it open, it stays open until the next drag, even while a fling goes on.
///
/// Shared by the file text view and the Symbols list so both behave the same.
nonisolated struct BarCollapseTracker {
    var threshold: CGFloat = 10
    /// The bar's current state. Keep it in sync when something else changes it.
    var isCollapsed = false

    private var lastOffset: CGFloat = 0
    private var accumulated: CGFloat = 0
    private var holdsOpen = false

    mutating func beginDrag(at offset: CGFloat) {
        lastOffset = offset
        accumulated = 0
        holdsOpen = false
    }

    mutating func holdOpen() {
        holdsOpen = true
        accumulated = 0
    }

    /// Feeds a new scroll offset. Returns the new collapsed state when it changes, otherwise `nil`.
    /// - Parameters:
    ///   - top: the offset at the very top of the content.
    ///   - bottom: the offset at the very end of the content.
    ///   - isUserScrolling: dragging or decelerating, as opposed to a programmatic scroll.
    mutating func scrolled(to offset: CGFloat, top: CGFloat, bottom: CGFloat, isUserScrolling: Bool) -> Bool? {
        let delta = offset - lastOffset
        lastOffset = offset

        var wanted = isCollapsed
        if offset <= top + 1 || offset >= bottom - 1 {
            wanted = false
        } else if !holdsOpen, isUserScrolling, delta != 0 {
            if (delta > 0) != (accumulated > 0) { accumulated = 0 }  // direction changed
            accumulated += delta
            if accumulated > threshold {
                wanted = true
            } else if accumulated < -threshold {
                wanted = false
            }
        }
        guard wanted != isCollapsed else { return nil }
        isCollapsed = wanted
        return wanted
    }
}
