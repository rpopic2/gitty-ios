import Foundation

/// Long code cut into pieces of a few lines, for the Code level: SwiftUI lays out each piece
/// only when it's on screen, so a long symbol costs no more than a short one to scroll past.
nonisolated enum CodePieces {
    static let linesPerPiece = 100

    /// Where each piece is in `text`: `linesPerPiece` lines each (the last one, what's left),
    /// without the newline between two pieces. One piece for short text, even empty text.
    static func ranges(in text: NSString, linesPerPiece: Int = linesPerPiece) -> [NSRange] {
        var ranges: [NSRange] = []
        var start = 0
        var lines = 0
        var index = 0
        while index < text.length {
            let found = text.range(of: "\n", options: .literal, range: NSRange(location: index, length: text.length - index))
            guard found.location != NSNotFound else { break }
            lines += 1
            index = NSMaxRange(found)
            if lines == linesPerPiece, index < text.length {
                ranges.append(NSRange(location: start, length: found.location - start))
                start = index
                lines = 0
            }
        }
        ranges.append(NSRange(location: start, length: text.length - start))
        return ranges
    }

    /// Without the blank lines and spaces at its end (a type cut before its first member).
    static func trimmingTrailingWhitespace(_ text: String) -> String {
        var end = text.endIndex
        while end > text.startIndex, text[text.index(before: end)].isWhitespace { end = text.index(before: end) }
        return String(text[..<end])
    }
}

/// One piece of a symbol's code at the Code level, ready to be laid out: its text, the
/// stretches the grammar colors, and where it starts in the block.
nonisolated struct CodeText: Equatable, Sendable {
    let string: String
    /// The colored stretches (plain text has none), relative to `string`.
    let runs: [SyntaxHighlighter.Run]
    /// Its first line, counted from the block's first (0).
    let firstLine: Int
}

extension CodePieces {
    /// `text` in pieces (see `ranges`), with the grammar's colored stretches when
    /// `highlighted`. The text is parsed once, whole.
    static func texts(_ text: String, fileExtension: String, highlighted: Bool) -> [CodeText] {
        let utf16 = text as NSString
        let colored = highlighted
            ? (SyntaxHighlighter.runs(in: text, fileExtension: fileExtension) ?? []).filter { $0.category != nil }
            : []
        var next = 0
        var firstLine = 0
        return ranges(in: utf16).map { range in
            while next < colored.count, NSMaxRange(colored[next].range) <= range.location { next += 1 }
            var runs: [SyntaxHighlighter.Run] = []
            var index = next
            while index < colored.count, colored[index].range.location < NSMaxRange(range) {
                let part = NSIntersectionRange(colored[index].range, range)
                if part.length > 0 {
                    runs.append(.init(range: NSRange(location: part.location - range.location, length: part.length),
                                      category: colored[index].category))
                }
                index += 1
            }
            let string = utf16.substring(with: range)
            let piece = CodeText(string: string, runs: runs, firstLine: firstLine)
            firstLine += string.utf8.reduce(1) { $0 + ($1 == 0x0A ? 1 : 0) }
            return piece
        }
    }
}
