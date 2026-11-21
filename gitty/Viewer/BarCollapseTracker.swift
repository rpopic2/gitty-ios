import CoreGraphics

/// Decides when the bottom bar collapses and expands while scrolling, like Safari.
///
/// - Scrolling down about 10pt collapses it, and scrolling up about 10pt expands it.
/// - It is always expanded at the top and at the end of the content.
/// - After the reader taps it open, it stays open until the next drag, even while a fling goes on.
/// - While a fling coasts, it only follows the fling's direction: the list moving the other way
///   then is the list correcting its offset (content above changing size), not the reader. While
///   dragging too, when the content's height changed at the same time (rows above coming in at
///   another height than the list guessed, scrolling up).
///
/// Shared by the file text view and the Symbols list so both behave the same.
nonisolated struct BarCollapseTracker {
    var threshold: CGFloat = 10
    /// The bar's current state. Keep it in sync when something else changes it.
    var isCollapsed = false

    private var lastOffset: CGFloat = 0
    private var lastContentHeight: CGFloat?
    private var accumulated: CGFloat = 0
    private var holdsOpen = false
    /// The way the finger last moved the content (positive: down the list), for coasting.
    private var dragDirection: CGFloat = 0

    mutating func beginDrag(at offset: CGFloat) {
        lastOffset = offset
        accumulated = 0
        holdsOpen = false
        dragDirection = 0
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
    ///   - isCoasting: decelerating after a fling (the finger is off the screen).
    ///   - contentHeight: the content's height, to tell the list's own corrections (see the type).
    mutating func scrolled(to offset: CGFloat, top: CGFloat, bottom: CGFloat, isUserScrolling: Bool,
                           isCoasting: Bool = false, contentHeight: CGFloat? = nil) -> Bool? {
        let delta = offset - lastOffset
        lastOffset = offset
        let resized = contentHeight != nil && lastContentHeight != nil
            && abs(contentHeight! - lastContentHeight!) > 0.5
        lastContentHeight = contentHeight
        let against = dragDirection != 0 && delta != 0 && (delta > 0) != (dragDirection > 0)
        let isCorrection = against && (isCoasting || resized)
        if isUserScrolling, !isCoasting, delta != 0, !isCorrection { dragDirection = delta }

        var wanted = isCollapsed
        if offset <= top + 1 || offset >= bottom - 1 {
            wanted = false
        } else if !holdsOpen, isUserScrolling, delta != 0, !isCorrection {
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
