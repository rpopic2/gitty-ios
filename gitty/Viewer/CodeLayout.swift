import CoreText
import SwiftUI
import UIKit

/// What a piece of code is laid out for: the width it wraps at, the font and colors, and
/// light or dark mode (the colors are resolved into the layout).
nonisolated struct CodeLayoutKey: Hashable, Sendable {
    let width: CGFloat
    let style: CodeTextStyle
    let isDark: Bool
}

/// A piece of code laid out by Core Text, off the main thread, once per key: the main thread
/// only draws it. (SwiftUI `Text` measured and shaped each block on the main thread every time it
/// scrolled in, and again for the lazy list's size estimates, which showed in hang reports as
/// the main thread's time.)
nonisolated final class CodePieceLayout: @unchecked Sendable {
    let key: CodeLayoutKey
    let height: CGFloat
    private let frame: CTFrame
    private let lines: [CTLine]
    private let origins: [CGPoint]
    /// Each row that starts a line of the code, and which line it is (counted in the piece).
    private let lineStarts: [(row: Int, line: Int)]
    /// The piece's first line, counted from its block's first (0).
    let firstLine: Int

    init(_ text: CodeText, key: CodeLayoutKey) {
        self.key = key
        firstLine = text.firstLine
        let traits = UITraitCollection(userInterfaceStyle: key.isDark ? .dark : .light)
        let font = key.style.uiFont
        let string = NSMutableAttributedString(string: text.string, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String):
                RawTextStyle.textColor.resolvedColor(with: traits).cgColor,
        ])
        for run in text.runs {
            guard let category = run.category, let color = key.style.theme.color(for: category) else { continue }
            string.addAttribute(NSAttributedString.Key(kCTForegroundColorAttributeName as String),
                                value: color.resolvedColor(with: traits).cgColor, range: run.range)
        }
        let framesetter = CTFramesetterCreateWithAttributedString(string as CFAttributedString)
        let width = max(1, key.width)
        let suggested = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter, CFRange(location: 0, length: 0), nil,
            CGSize(width: width, height: .greatestFiniteMagnitude), nil)
        let height = max(ceil(suggested.height), ceil(font.lineHeight))
        self.height = height
        frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0),
                                         CGPath(rect: CGRect(x: 0, y: 0, width: width, height: height), transform: nil), nil)
        lines = (CTFrameGetLines(frame) as? [CTLine]) ?? []
        var origins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)
        self.origins = origins

        let utf16 = text.string as NSString
        var starts: [(row: Int, line: Int)] = []
        var line = 0
        var counted = 0  // where newlines have been counted up to
        for (row, ctLine) in lines.enumerated() {
            let location = CTLineGetStringRange(ctLine).location
            guard location == 0 || (location <= utf16.length && utf16.character(at: location - 1) == 0x0A) else { continue }
            if location > counted {
                var index = counted
                while index < location {
                    if utf16.character(at: index) == 0x0A { line += 1 }
                    index += 1
                }
                counted = location
            }
            starts.append((row: row, line: line))
        }
        lineStarts = starts
    }

    /// Draws the code.
    func draw(in context: CGContext) {
        context.saveGState()
        context.textMatrix = .identity
        context.translateBy(x: 0, y: height)
        context.scaleBy(x: 1, y: -1)
        CTFrameDraw(frame, context)
        context.restoreGState()
    }

    /// Draws each line's number (counted from `firstFileLine`, the block's first line in its
    /// file) on its first row, right-aligned at `right`.
    func drawNumbers(in context: CGContext, right: CGFloat, firstFileLine: Int) {
        let font = UIFont.monospacedDigitSystemFont(ofSize: max(9, key.style.size - 2), weight: .regular)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor.secondaryLabel]
        UIGraphicsPushContext(context)
        for (row, line) in lineStarts where row < origins.count {
            let label = String(firstFileLine + firstLine + line) as NSString
            let size = label.size(withAttributes: attributes)
            let baseline = height - origins[row].y
            label.draw(at: CGPoint(x: right - size.width, y: baseline - font.ascender), withAttributes: attributes)
        }
        UIGraphicsPopContext()
    }
}

/// Draws a `CodePieceLayout`. Its height is the layout's, so SwiftUI never measures text.
/// While peeking (the whole list slides right), the line numbers show left of the code, in
/// the strip that uncovers.
struct CodePieceView: UIViewRepresentable {
    let layout: CodePieceLayout
    /// The block's first line in its file, for the line peek.
    let firstFileLine: Int
    let isPeeking: Bool

    func makeUIView(context: Context) -> CodePieceUIView {
        CodePieceUIView()
    }

    func updateUIView(_ view: CodePieceUIView, context: Context) {
        view.update(layout: layout, firstFileLine: firstFileLine, isPeeking: isPeeking)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: CodePieceUIView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? layout.key.width, height: layout.height)
    }
}

final class CodePieceUIView: UIView {
    private var layout: CodePieceLayout?
    private var firstFileLine = 1
    private let numbers = CodeLineNumbersView()

    /// Room left of the code for the numbers: the peek's slide and the block's margin.
    static let gutterWidth = CodePeek.width + RawTextStyle.insets.left

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        isUserInteractionEnabled = false  // taps go to the block (it opens its page)
        contentMode = .redraw
        clipsToBounds = false  // the numbers sit left of the code
        numbers.isHidden = true
        addSubview(numbers)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func update(layout: CodePieceLayout, firstFileLine: Int, isPeeking: Bool) {
        if layout !== self.layout || firstFileLine != self.firstFileLine {
            self.layout = layout
            self.firstFileLine = firstFileLine
            setNeedsDisplay()
            numbers.layout = layout
            numbers.firstFileLine = firstFileLine
            numbers.setNeedsDisplay()
        }
        numbers.isHidden = !isPeeking
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = Self.gutterWidth
        numbers.frame = CGRect(x: -width, y: 0, width: width, height: bounds.height)
    }

    override func draw(_ rect: CGRect) {
        guard let layout, let context = UIGraphicsGetCurrentContext() else { return }
        layout.draw(in: context)
    }
}

/// A piece's line numbers, drawn once per layout and shown only while peeking.
final class CodeLineNumbersView: UIView {
    var layout: CodePieceLayout?
    var firstFileLine = 1

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        isUserInteractionEnabled = false
        contentMode = .redraw
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func draw(_ rect: CGRect) {
        guard let layout, let context = UIGraphicsGetCurrentContext() else { return }
        layout.drawNumbers(in: context, right: bounds.width - 8, firstFileLine: firstFileLine)
    }
}
