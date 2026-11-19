import Foundation

/// The code token around a character, for long press on a page: `view` in `self.view`, `->` in
/// `a->b`, `1.25` as a whole, `(` on its own. Word selection would take `self.view` (or `a:b`)
/// as one word. It reads only the token and one character on each side.
nonisolated enum CodeToken {
    /// `nil` on white space, so the text view's own selection stays.
    /// - Parameter text: pass the text storage's `mutableString`: `string` copies the whole text.
    static func range(at index: Int, in text: NSString) -> NSRange? {
        let length = text.length
        guard index >= 0, index < length else { return nil }
        let kind = Kind(text, index)
        switch kind {
        case .space: return nil
        case .single: return NSRange(location: index, length: 1)
        case .word, .symbol: break
        }
        var start = index, end = index + 1
        while start > 0, Kind(text, start - 1) == kind { start -= 1 }
        while end < length, Kind(text, end) == kind { end += 1 }
        return NSRange(location: start, length: end - start)
    }

    private enum Kind: UInt8 {
        /// Letters, digits, `_`, `$`, and a `.` between digits (`1.25`).
        case word
        /// Operators: runs of `+-*/%=<>!&|^~?:.@#\`.
        case symbol
        /// `()[]{},;` and quotes: one at a time.
        case single
        case space

        init(_ text: NSString, _ index: Int) {
            let c = text.character(at: index)
            guard c < 128 else {
                self = Self.other(c)
                return
            }
            let kind = Self.ascii[Int(c)]
            if kind == .symbol, c == 46, index > 0, index + 1 < text.length,  // "."
               Self.isDigit(text.character(at: index - 1)), Self.isDigit(text.character(at: index + 1)) {
                self = .word
            } else {
                self = kind
            }
        }

        private static func isDigit(_ c: unichar) -> Bool { c >= 48 && c <= 57 }

        /// What each ASCII character is, looked up rather than worked out.
        private static let ascii: [Kind] = (0..<128).map { (c: Int) -> Kind in
            switch c {
            case 9...13, 32: .space
            case 48...57, 65...90, 97...122, 36, 95: .word  // digits, letters, $ _
            case 40, 41, 91, 93, 123, 125, 44, 59, 34, 39, 96: .single  // ( ) [ ] { } , ; " ' `
            case 0..<32, 127: .space  // control characters
            default: .symbol
            }
        }

        private static func other(_ c: unichar) -> Kind {
            switch c {
            case 0x00A0, 0x2000...0x200B, 0x2028, 0x2029, 0x3000, 0xFEFF: .space
            case 0x2010...0x2027, 0x2030...0x205E, 0x3001...0x3003: .symbol  // dashes, quotes, ‰…
            default: .word  // letters of other scripts, and surrogate halves (never split a character)
            }
        }
    }
}
