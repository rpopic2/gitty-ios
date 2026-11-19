import UIKit

extension NSAttributedString.Key {
    /// A `UIColor` filling the whole width of every line it covers, edge to edge (a diff's
    /// added and removed lines). `.backgroundColor` only goes behind the characters.
    nonisolated static let lineBackground = NSAttributedString.Key("gittyLineBackground")
    /// An `Int`: the line number to show for the line starting here, where the text's own line
    /// count isn't it (a diff's lines are numbered as in the file).
    nonisolated static let lineNumber = NSAttributedString.Key("gittyLineNumber")
}

/// How a page's lines are numbered, for the line-number peek.
enum LineNumbering {
    /// Counted from the top of the page's text, starting at this line of its file.
    case counted(firstLine: @MainActor () -> Int)
    /// From each line's `.lineNumber` (none where it has none).
    case marked
}

/// TextKit 1's layout manager, plus `.lineBackground`: drawn under the text, across the
/// whole line, insets included.
final class LineBackgroundLayoutManager: NSLayoutManager {
    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: CGPoint) {
        if let storage = textStorage, let context = UIGraphicsGetCurrentContext() {
            let characters = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
            storage.enumerateAttribute(.lineBackground, in: characters) { value, range, _ in
                guard let color = value as? UIColor else { return }
                let glyphs = glyphRange(forCharacterRange: range, actualCharacterRange: nil)
                color.setFill()
                enumerateLineFragments(forGlyphRange: glyphs) { rect, _, container, _, _ in
                    // The fragment spans the container; reach the insets on either side too.
                    let full = CGRect(x: -origin.x, y: rect.minY + origin.y,
                                      width: container.size.width + 2 * origin.x, height: rect.height)
                    context.fill(full)
                }
            }
        }
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
    }
}

/// The line numbers, peeked at by swiping in from the left edge and holding: a strip beside
/// the page (which slides right to show it) with the number of each line on screen, level with
/// its first row.
final class LineNumberGutter: UIView {
    weak var textView: UITextView?
    var numbering: LineNumbering = .marked {
        didSet { lineStarts = nil }
    }
    /// `counted`'s first line, asked once per peek (`prepare()`).
    private var firstLine = 1
    /// Where each line starts in the text, for counted numbers (worked out on the first peek).
    private var lineStarts: [Int]?
    private var lineStartsLength = -1

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        isUserInteractionEnabled = false
        backgroundColor = .clear
        contentMode = .redraw
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Call as a peek starts: the page's first line number, once.
    func prepare() {
        if case .counted(let first) = numbering { firstLine = first() }
    }

    /// The width for the numbers in this text, its widest one plus margins.
    func preferredWidth(font: UIFont) -> CGFloat {
        let digits = max(3, String(largestNumber()).count)
        let width = (String(repeating: "8", count: digits) as NSString).size(withAttributes: [.font: font]).width
        return ceil(width) + 20
    }

    override func draw(_ rect: CGRect) {
        guard let textView else { return }
        UIColor.secondarySystemBackground.withAlphaComponent(0.94).setFill()
        UIBezierPath(rect: bounds).fill()
        UIColor.separator.setFill()
        UIBezierPath(rect: CGRect(x: bounds.maxX - 1 / max(1, traitCollection.displayScale), y: 0,
                                  width: 1 / max(1, traitCollection.displayScale), height: bounds.height)).fill()

        let layoutManager = textView.layoutManager
        let container = textView.textContainer
        let storage = textView.textStorage
        guard storage.length > 0 else { return }
        let text = storage.string as NSString
        let top = textView.textContainerInset.top
        // The gutter sits over the visible part of the page: what's on screen, in the container.
        // The gutter's top is the text view's: what's at the top of the screen.
        let originY = textView.contentOffset.y
        let visible = CGRect(x: 0, y: originY - top, width: container.size.width, height: bounds.height)
        let glyphs = layoutManager.glyphRange(forBoundingRect: visible, in: container)
        let font = Self.font(for: textView)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor.secondaryLabel]
        layoutManager.enumerateLineFragments(forGlyphRange: glyphs) { fragment, used, _, glyphRange, _ in
            let index = layoutManager.characterIndexForGlyph(at: glyphRange.location)
            // Only a line's first row.
            guard index == 0 || text.character(at: index - 1) == 0x0A else { return }
            guard let number = self.number(at: index, in: storage) else { return }
            let label = String(number) as NSString
            let size = label.size(withAttributes: attributes)
            let y = fragment.minY + top - originY + (used.height - size.height) / 2
            label.draw(at: CGPoint(x: self.bounds.width - 10 - size.width, y: y), withAttributes: attributes)
        }
    }

    static func font(for textView: UITextView) -> UIFont {
        let size = max(9, (textView.textStorage.length > 0
            ? (textView.textStorage.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)?.pointSize : nil)
            ?? RawTextStyle.fontSize) - 2
        return .monospacedDigitSystemFont(ofSize: size, weight: .regular)
    }

    private func number(at index: Int, in storage: NSTextStorage) -> Int? {
        switch numbering {
        case .marked:
            return storage.attribute(.lineNumber, at: index, effectiveRange: nil) as? Int
        case .counted:
            let starts = lineStarts(of: storage)
            // The line whose start is at or before `index`.
            var low = 0, high = starts.count
            while low < high {
                let middle = (low + high) / 2
                if starts[middle] <= index { low = middle + 1 } else { high = middle }
            }
            return firstLine + max(0, low - 1)
        }
    }

    private func largestNumber() -> Int {
        guard let storage = textView?.textStorage, storage.length > 0 else { return 0 }
        switch numbering {
        case .marked:
            var largest = 0
            storage.enumerateAttribute(.lineNumber, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
                largest = max(largest, value as? Int ?? 0)
            }
            return largest
        case .counted:
            return firstLine + lineStarts(of: storage).count - 1
        }
    }

    private func lineStarts(of storage: NSTextStorage) -> [Int] {
        if let lineStarts, lineStartsLength == storage.length { return lineStarts }
        let text = storage.string as NSString
        var starts = [0]
        var index = 0
        while true {
            let found = text.range(of: "\n", options: .literal, range: NSRange(location: index, length: text.length - index))
            guard found.location != NSNotFound else { break }
            index = NSMaxRange(found)
            if index < text.length { starts.append(index) }
        }
        lineStarts = starts
        lineStartsLength = storage.length
        return starts
    }
}
