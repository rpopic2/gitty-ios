import SwiftUI

/// The Code level's line-number peek: swipe in from the left edge and hold, and the whole list
/// slides right with the line numbers beside the code, as on a page (`CodePieceLayout` draws
/// them). The slide is one offset on the list (`PeekShift`), and the blocks on screen only
/// show or hide their numbers when the peek starts and ends.
@MainActor @Observable
final class CodePeek {
    /// How far the code has slid right (0 to `width`).
    var offset: CGFloat = 0
    /// Peeking: the blocks draw with their numbers (each line numbered from its file).
    private(set) var isActive = false
    /// Room for the numbers.
    static let width: CGFloat = 56

    /// Touches starting this close to the screen's left edge can peek.
    static let edgeWidth: CGFloat = 28

    func follow(_ translation: CGFloat) {
        isActive = true
        offset = min(max(translation, 0), Self.width)
    }

    /// Let go: the code slides back, and the numbers go once it's there (unless a new peek
    /// has started meanwhile).
    func end() {
        withAnimation(.smooth(duration: 0.2)) {
            offset = 0
        } completion: { [weak self] in
            guard let self, self.offset == 0 else { return }
            self.isActive = false
        }
    }
}

/// Slides the Code level's list while peeking. Only this redraws as the finger moves.
struct PeekShift: ViewModifier {
    let peek: CodePeek

    func body(content: Content) -> some View {
        content.offset(x: peek.offset)
    }
}
