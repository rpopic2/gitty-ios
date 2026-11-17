import Foundation

/// A C-only pass that runs before parsing (see `SymbolLanguage.c`).
nonisolated enum CMacroBlanking {
    /// tree-sitter can't expand macros. A top-level macro call without a semicolon, such as
    /// `OPT_GENERIC(i64)`, reads as a function's return type, and everything after it becomes one
    /// giant function. Like ctags, replace such calls with spaces before parsing. Every other
    /// character stays where it was, so ranges and line numbers don't move.
    ///
    /// A call is a line that starts at column 0 with `NAME(` and, after the matching `)` (which may
    /// be on a later line), has nothing but an optional `;`. It is left alone when `{` follows (an
    /// old-style function definition), or when the line before doesn't end a statement, as in GNU
    /// style `static int` / `foo(int x);`, where it's the second half of a declaration.
    static func blankingTopLevelMacroCalls(in text: NSString) -> String {
        let count = text.length
        var units = [unichar](repeating: 0, count: count)
        text.getCharacters(&units, range: NSRange(location: 0, length: count))

        func isIdentifierStart(_ c: unichar) -> Bool {
            (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95  // A-Z a-z _
        }
        func isIdentifier(_ c: unichar) -> Bool {
            isIdentifierStart(c) || (c >= 48 && c <= 57)
        }
        func isBlank(_ c: unichar) -> Bool { c == 32 || c == 9 || c == 13 }  // space, tab, CR
        let newline: unichar = 10, space: unichar = 32, quote: unichar = 34, apostrophe: unichar = 39,
            backslash: unichar = 92, open: unichar = 40, close: unichar = 41, semicolon: unichar = 59,
            brace: unichar = 123

        func endOfLine(from index: Int) -> Int {
            var i = index
            while i < count, units[i] != newline { i += 1 }
            return i
        }

        /// True when the previous non-blank line ends a statement or is a directive or comment.
        func previousLineEndsStatement(before lineStart: Int) -> Bool {
            var last = lineStart - 1
            while last >= 0, isBlank(units[last]) || units[last] == newline { last -= 1 }
            guard last >= 0 else { return true }  // start of the file
            var first = last
            while first > 0, units[first - 1] != newline { first -= 1 }
            while first < last, isBlank(units[first]) { first += 1 }

            let hash: unichar = 35, slash: unichar = 47, star: unichar = 42, closeBrace: unichar = 125
            if units[first] == hash { return true }  // preprocessor directive
            if units[first] == slash, first + 1 <= last, units[first + 1] == slash { return true }  // // comment
            switch units[last] {
            case semicolon, closeBrace, brace, close: return true
            case slash: return last > first && units[last - 1] == star  // end of /* comment */
            default: return false
            }
        }

        var lineStart = 0
        while lineStart < count {
            let lineEnd = endOfLine(from: lineStart)
            defer { lineStart = lineEnd + 1 }
            guard isIdentifierStart(units[lineStart]) else { continue }

            var i = lineStart
            while i < count, isIdentifier(units[i]) { i += 1 }
            while i < count, isBlank(units[i]) { i += 1 }
            guard i < count, units[i] == open else { continue }

            // Find the matching `)`, skipping string and character literals.
            var depth = 0
            while i < count {
                let c = units[i]
                if c == quote || c == apostrophe {
                    i += 1
                    while i < count, units[i] != c, units[i] != newline {
                        i += units[i] == backslash ? 2 : 1
                    }
                } else if c == open {
                    depth += 1
                } else if c == close {
                    depth -= 1
                    if depth == 0 { break }
                }
                i += 1
            }
            guard depth == 0, i < count else { continue }

            // Only blanks and an optional `;` may follow on that line.
            var rest = i + 1
            while rest < count, isBlank(units[rest]) { rest += 1 }
            if rest < count, units[rest] == semicolon { rest += 1 }
            while rest < count, isBlank(units[rest]) { rest += 1 }
            guard rest == count || units[rest] == newline else { continue }

            // An old-style definition (`main(argc) {`) has a body next: keep it.
            var next = rest
            while next < count, isBlank(units[next]) || units[next] == newline { next += 1 }
            guard next == count || units[next] != brace else { continue }
            guard previousLineEndsStatement(before: lineStart) else { continue }

            // Lines of a multi-line call now start with spaces, so the loop skips them.
            for k in lineStart..<rest where units[k] != newline {
                units[k] = space
            }
        }
        return String(decoding: units, as: UTF16.self)
    }
}
