import SwiftUI

/// The Code level's line-number peek: swipe in from the left edge and hold, and every block
/// slides right with the line numbers beside it, as on a page (`CodePieceLayout` draws them).
/// Observed only by the blocks on screen, so a peek redraws just those.
@MainActor @Observable
final class CodePeek {
    /// How far the code has slid right (0 to `width`).
    var offset: CGFloat = 0
    /// Peeking: the blocks draw with their numbers (each line numbered from its file).
    private(set) var isActive = false
    /// Room for the numbers.
    let width: CGFloat = 56

    /// Touches starting this close to the screen's left edge can peek.
    static let edgeWidth: CGFloat = 28

    func follow(_ translation: CGFloat) {
        isActive = true
        offset = min(max(translation, 0), width)
    }

    /// Let go: the code goes back.
    func end() {
        offset = 0
        isActive = false
    }
}
