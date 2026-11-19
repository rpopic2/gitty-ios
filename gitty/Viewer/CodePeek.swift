import SwiftUI

/// The Code level's line-number peek: swipe in from the left edge and hold, and every block
/// slides right with the line numbers beside it, as on a page. Observed only by the blocks on
/// screen, so a peek redraws just those.
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

    @ObservationIgnored private var endTask: Task<Void, Never>?

    func follow(_ translation: CGFloat) {
        endTask?.cancel()
        isActive = true
        offset = min(max(translation, 0), width)
    }

    /// Let go: slides back, then the blocks draw plainly again.
    func end() {
        withAnimation(.smooth(duration: 0.2)) { offset = 0 }
        endTask = Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            isActive = false
        }
    }
}

/// Which line of its file a line of code is, on the line's text (see `LineNumberRenderer`).
struct LineNumberAttribute: TextAttribute {
    let number: Int
}

/// Draws a code block slid right by `offset`, each line's number beside its first row. The
/// layout doesn't change, so sliding only redraws.
struct LineNumberRenderer: TextRenderer, Animatable {
    var offset: CGFloat
    let width: CGFloat
    let fontSize: CGFloat

    var animatableData: CGFloat {
        get { offset }
        set { offset = newValue }
    }

    /// Room to draw the numbers left of the text, and the slid text past its right.
    var displayPadding: EdgeInsets {
        EdgeInsets(top: 0, leading: width, bottom: 0, trailing: width)
    }

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        var last: Int?
        for line in layout {
            var slid = context
            slid.translateBy(x: offset, y: 0)
            slid.draw(line)
            guard offset > 0, let number = line.first?[LineNumberAttribute.self]?.number, number != last else { continue }
            last = number  // a wrapped line's other rows carry the same number
            let label = context.resolve(
                Text(verbatim: String(number))
                    .font(.system(size: max(9, fontSize - 2), design: .monospaced))
                    .foregroundStyle(.secondary)
            )
            let bounds = line.typographicBounds.rect
            context.draw(label, at: CGPoint(x: offset - 8, y: bounds.midY), anchor: .trailing)
        }
    }
}
