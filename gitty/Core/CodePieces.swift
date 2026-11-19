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
