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
    /// Its text, for marking a word in it.
    private let string: NSString
    /// The last word marked and where it is (drawing happens on the main thread only).
    private var markCache: (word: String, rects: [CGRect])?

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
        string = utf16
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

    /// The line of the code at `y` (counted from the block's first, as `firstLine` is), and
    /// where that line's first row starts in this piece. For opening its page at that line.
    func line(atY y: CGFloat) -> (line: Int, top: CGFloat)? {
        guard !lines.isEmpty else { return nil }
        func top(of row: Int) -> CGFloat {
            var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
            CTLineGetTypographicBounds(lines[row], &ascent, &descent, &leading)
            return height - origins[row].y - ascent
        }
        var row = 0
        while row + 1 < lines.count, top(of: row + 1) <= y { row += 1 }
        guard let start = lineStarts.last(where: { $0.row <= row }) ?? lineStarts.first else { return nil }
        return (firstLine + start.line, top(of: start.row))
    }

    /// Each line's rows: its line (counted from the block's first, as `firstLine` is), and where
    /// its first row starts and its last ends. For the blame beside it.
    func lineRows() -> [(line: Int, top: CGFloat, bottom: CGFloat)] {
        func top(of row: Int) -> CGFloat {
            var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
            CTLineGetTypographicBounds(lines[row], &ascent, &descent, &leading)
            return height - origins[row].y - ascent
        }
        var rows: [(line: Int, top: CGFloat, bottom: CGFloat)] = []
        for (index, start) in lineStarts.enumerated() where start.row < origins.count {
            let next = index + 1 < lineStarts.count ? lineStarts[index + 1].row : lines.count
            rows.append((firstLine + start.line, top(of: start.row), next < lines.count ? top(of: next) : height))
        }
        return rows
    }

    /// Where a word is in the piece, as a whole word with its exact case: a rectangle per
    /// row it's on. Worked out once per word.
    func rects(of word: String) -> [CGRect] {
        if let markCache, markCache.word == word { return markCache.rects }
        var rects: [CGRect] = []
        let ranges = Occurrences.ranges(of: word, in: string)
        if !ranges.isEmpty {
            for (row, line) in lines.enumerated() {
                let lineRange = CTLineGetStringRange(line)
                for range in ranges {
                    let start = max(range.location, lineRange.location)
                    let end = min(NSMaxRange(range), lineRange.location + lineRange.length)
                    guard start < end else { continue }
                    var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
                    CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
                    let x0 = CTLineGetOffsetForStringIndex(line, start, nil)
                    let x1 = CTLineGetOffsetForStringIndex(line, end, nil)
                    let top = height - origins[row].y - ascent
                    rects.append(CGRect(x: origins[row].x + x0 - 1, y: top - 1,
                                        width: x1 - x0 + 2, height: ascent + descent + 2))
                }
            }
        }
        markCache = (word, rects)
        return rects
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
    /// Who last changed the file's lines, while the blame shows.
    var blame: BlameStore.FileBlame? = nil
    /// A word to mark wherever it is (`CodePieceLayout.rects(of:)`).
    var mark: String? = nil

    func makeUIView(context: Context) -> CodePieceUIView {
        CodePieceUIView()
    }

    func updateUIView(_ view: CodePieceUIView, context: Context) {
        view.update(layout: layout, firstFileLine: firstFileLine, isPeeking: isPeeking)
        view.update(blame: blame)
        view.mark = mark
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: CodePieceUIView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? layout.key.width, height: layout.height)
    }
}

final class CodePieceUIView: UIView {
    private var layout: CodePieceLayout?
    private var firstFileLine = 1
    private let numbers = CodeLineNumbersView()
    private let blameView = CodeBlameView()
    /// Who last changed the file's lines, while the blame shows (`nil` otherwise).
    private(set) var blame: BlameStore.FileBlame?
    /// A word marked wherever it is in the piece, behind the text.
    var mark: String? {
        didSet { if mark != oldValue { setNeedsDisplay() } }
    }

    /// Room left of the code for the numbers: the peek's slide and the block's margin.
    static let gutterWidth = CodePeek.width + RawTextStyle.insets.left

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        isUserInteractionEnabled = false  // taps go to SwiftUI (see `SymbolCodeText`)
        contentMode = .redraw
        clipsToBounds = false  // the numbers sit left of the code
        numbers.isHidden = true
        addSubview(numbers)
        blameView.isHidden = true
        addSubview(blameView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Shows (or hides) the blame left of the numbers. After `update(layout:…)`.
    func update(blame: BlameStore.FileBlame?) {
        guard blame != self.blame || (blame != nil && blameView.layout !== layout) else { return }
        self.blame = blame
        blameView.layout = layout
        blameView.firstFileLine = firstFileLine
        blameView.hunks = blame?.hunks ?? []
        blameView.isHidden = blame == nil
        blameView.setNeedsDisplay()
    }

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
        blameView.frame = CGRect(x: -width - CodePeek.blameWidth, y: 0, width: CodePeek.blameWidth,
                                 height: bounds.height)
    }

    override func draw(_ rect: CGRect) {
        guard let layout, let context = UIGraphicsGetCurrentContext() else { return }
        if let mark, !mark.isEmpty {
            tintColor.withAlphaComponent(0.3).setFill()
            for rect in layout.rects(of: mark) {
                UIBezierPath(roundedRect: rect, cornerRadius: 3).fill()
            }
        }
        layout.draw(in: context)
    }

    /// The piece with blame across a height of the window (a tap in the blame, left of the
    /// code): found when asked, so nothing keeps track of the pieces while scrolling.
    static func piece(atWindowY y: CGFloat, in window: UIWindow) -> CodePieceUIView? {
        var views: [UIView] = [window]
        while let view = views.popLast() {
            if let piece = view as? CodePieceUIView, piece.blame != nil {
                let frame = piece.convert(piece.bounds, to: nil)
                if frame.minY <= y, y < frame.maxY { return piece }
            }
            views.append(contentsOf: view.subviews.filter { !$0.isHidden && $0.alpha > 0 })
        }
        return nil
    }

    /// Who last changed the line at a height of the window, and the project.
    func blameHunk(atWindowY y: CGFloat) -> (hunk: GitBlameHunk, projectID: String)? {
        guard let blame, let found = layout?.line(atY: convert(CGPoint(x: 0, y: y), from: nil).y) else { return nil }
        let line = firstFileLine + found.line
        guard let hunk = blame.hunks.first(where: { $0.lines.contains(line) }) else { return nil }
        return (hunk, blame.projectID)
    }
}

/// Where to open a page: its `line` (0-based, from the page's first) goes where it was on
/// screen, its top at `screenY` (window coordinates), so opening it barely moves anything.
nonisolated struct PageAnchor: Equatable, Sendable {
    let line: Int
    let screenY: CGFloat
}

/// Who last changed a piece's lines, left of its numbers: for each run of lines from the same
/// commit, the author and how long ago ("Kim · 3y") at its first line, and a bar beside the
/// run, stronger the more recent the change.
final class CodeBlameView: UIView {
    var layout: CodePieceLayout?
    var firstFileLine = 1
    /// In line order.
    var hunks: [GitBlameHunk] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        isUserInteractionEnabled = false
        contentMode = .redraw
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func draw(_ rect: CGRect) {
        guard let layout, !hunks.isEmpty else { return }
        let size = max(9, layout.key.style.size - 3)
        let font = UIFont.monospacedDigitSystemFont(ofSize: size, weight: .regular)
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: UIColor.secondaryLabel, .paragraphStyle: style,
        ]
        let now = Date()
        // Runs of rows from the same hunk: one label, one bar.
        var runs: [(hunk: GitBlameHunk, top: CGFloat, bottom: CGFloat)] = []
        for row in layout.lineRows() {
            let line = firstFileLine + row.line
            guard let hunk = hunks.first(where: { $0.lines.contains(line) }) else { continue }
            if let last = runs.last, last.hunk == hunk {
                runs[runs.count - 1].bottom = row.bottom
            } else {
                runs.append((hunk, row.top, row.bottom))
            }
        }
        for run in runs {
            let days = max(0, now.timeIntervalSince(run.hunk.date) / 86_400)
            let strength = run.hunk.isBoundary ? 0.1 : max(0.1, 0.7 * exp(-days / 180))
            let bar = CGRect(x: bounds.width - 7, y: run.top + 1, width: 3, height: max(2, run.bottom - run.top - 2))
            tintColor.withAlphaComponent(strength).setFill()
            UIBezierPath(roundedRect: bar, cornerRadius: 1.5).fill()
            let label = Self.label(for: run.hunk, now: now) as NSString
            label.draw(with: CGRect(x: 4, y: run.top, width: bounds.width - 16, height: font.lineHeight),
                       options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attributes, context: nil)
        }
    }

    /// "Kim · 3y": the author's first name and how long ago, or "older" for a change from
    /// before the downloaded history.
    static func label(for hunk: GitBlameHunk, now: Date) -> String {
        let name = hunk.author.split(separator: " ").first.map(String.init) ?? hunk.author
        guard !hunk.isBoundary else { return name + " · " + String(localized: "older") }
        return name + " · " + age(since: hunk.date, now: now)
    }

    /// "now", "5m", "3h", "2d", "4w", "8mo", "3y".
    static func age(since date: Date, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        switch seconds {
        case ..<60: return String(localized: "now")
        case ..<3_600: return "\(Int(seconds / 60))m"
        case ..<86_400: return "\(Int(seconds / 3_600))h"
        case ..<(86_400 * 7): return "\(Int(seconds / 86_400))d"
        case ..<(86_400 * 30): return "\(Int(seconds / (86_400 * 7)))w"
        case ..<(86_400 * 365): return "\(Int(seconds / (86_400 * 30)))mo"
        default: return "\(Int(seconds / (86_400 * 365)))y"
        }
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
