import Foundation

/// Find All Occurrences: where a selected word is used in the project's files, as a whole word
/// with its exact case (`count` matches `count`, not `counter` or `Count`).
nonisolated enum Occurrences {
    /// What a selection searches for: its text without the spaces around it. `nil` for nothing,
    /// more than one line, or something too long to be a name or a short phrase.
    static func term(fromSelection selection: String) -> String? {
        let term = selection.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty, term.count <= 200, !term.contains(where: \.isNewline) else { return nil }
        return term
    }

    /// Where `term` is in `text`, as a whole word: an end of it that's a word character mustn't
    /// have another word character beside it (`a.b` still matches inside `x.a.b.c`).
    static func ranges(of term: String, in text: NSString) -> [NSRange] {
        let needle = term as NSString
        guard needle.length > 0, needle.length <= text.length else { return [] }
        let startsWithWord = isWordCharacter(needle.character(at: 0))
        let endsWithWord = isWordCharacter(needle.character(at: needle.length - 1))
        var found: [NSRange] = []
        var location = 0
        while location < text.length {
            let range = text.range(of: term, options: .literal,
                                   range: NSRange(location: location, length: text.length - location))
            guard range.location != NSNotFound else { break }
            let end = NSMaxRange(range)
            let before = range.location > 0 && isWordCharacter(text.character(at: range.location - 1))
            let after = end < text.length && isWordCharacter(text.character(at: end))
            if !(startsWithWord && before) && !(endsWithWord && after) { found.append(range) }
            location = range.location + 1
        }
        return found
    }

    /// Letters, digits, `_` and `$`, and any character outside ASCII (letters of other scripts).
    static func isWordCharacter(_ c: unichar) -> Bool {
        switch c {
        case 48...57, 65...90, 97...122, 95, 36: true
        case 0..<128: false
        default: true
        }
    }

    /// The 0-based line `location` is on, from `lineStarts` (see `AlbumContents.lineStarts`).
    static func line(of location: Int, lineStarts starts: [Int]) -> Int {
        var low = 0, high = starts.count
        while low < high {
            let middle = (low + high) / 2
            if starts[middle] <= location { low = middle + 1 } else { high = middle }
        }
        return max(low - 1, 0)
    }
}
