import Foundation

/// The code token around a character, for long press on a page: `view` in `self.view`, `->` in
/// `a->b`, `0x1F` or `1.5` as a whole, `(` on its own. Word selection would take `self.view`
/// (or `a:b`) as one word.
nonisolated enum CodeToken {
    /// `nil` on white space, so the text view's own selection stays.
    static func range(at index: Int, in text: NSString) -> NSRange? {
        guard index >= 0, index < text.length else { return nil }
        let kind = Kind(text.character(at: index))
        switch kind {
        case .space: return nil
        case .bracket: return NSRange(location: index, length: 1)
        case .word, .symbol: break
        }
        var start = index, end = index + 1
        while start > 0, Kind(text.character(at: start - 1)) == kind { start -= 1 }
        while end < text.length, Kind(text.character(at: end)) == kind { end += 1 }
        // A number goes on over its decimal point, `1.5` (`1e-3` still stops at the `-`)…
        if kind == .word, isDigit(text.character(at: start)) {
            while end + 1 < text.length, text.character(at: end) == dot, isDigit(text.character(at: end + 1)) {
                end += 1
                while end < text.length, Kind(text.character(at: end)) == .word { end += 1 }
            }
        }
        // …and from before it, when the press was after the point.
        if kind == .word, start >= 2, text.character(at: start - 1) == dot,
           isDigit(text.character(at: start)), isDigit(text.character(at: start - 2)) {
            var numberStart = start - 1
            while numberStart > 0, Kind(text.character(at: numberStart - 1)) == .word { numberStart -= 1 }
            if isDigit(text.character(at: numberStart)) { start = numberStart }
        }
        return NSRange(location: start, length: end - start)
    }

    private static let dot = unichar(UInt8(ascii: "."))

    private static func isDigit(_ c: unichar) -> Bool { c >= 48 && c <= 57 }

    private enum Kind {
        /// Letters, digits, `_` and `$`.
        case word
        /// Operators: runs of `+-*/%=<>!&|^~?:.@#\` and the like.
        case symbol
        /// `()[]{},;` and quotes: one at a time.
        case bracket
        case space

        init(_ c: unichar) {
            switch c {
            case 9, 10, 11, 12, 13, 32: self = .space
            case 36, 95: self = .word  // $ _
            case 40, 41, 91, 93, 123, 125, 44, 59, 34, 39, 96: self = .bracket  // ( ) [ ] { } , ; " ' `
            default:
                if c < 128 {
                    let isAlphanumeric = (c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122)
                    self = isAlphanumeric ? .word : .symbol
                } else if let scalar = Unicode.Scalar(c), CharacterSet.whitespacesAndNewlines.contains(scalar) {
                    self = .space
                } else if let scalar = Unicode.Scalar(c), CharacterSet.punctuationCharacters.contains(scalar)
                            || CharacterSet.symbols.contains(scalar) {
                    self = .symbol
                } else {
                    self = .word  // other letters, and surrogate halves (never split a character)
                }
            }
        }
    }
}
