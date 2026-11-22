import Foundation

/// A unified diff (`git diff` output for one file), as lines to draw: hunk headers, and added,
/// removed and unchanged lines with their line numbers. The `diff --git`, `index`, `---` and
/// `+++` lines are left out: the page says which file it is.
nonisolated struct UnifiedDiff: Equatable, Sendable {
    nonisolated struct Line: Hashable, Sendable {
        enum Kind: Hashable, Sendable {
            /// `@@ -10,7 +10,8 @@ func draw()`
            case hunk
            case added, removed, context
            /// `\ No newline at end of file`, `Binary files … differ`, mode changes.
            case note
        }

        let kind: Kind
        /// Without its `+`, `-` or space.
        let text: String
        /// The line's number before the change (removed and unchanged lines).
        var oldNumber: Int?
        /// After it (added and unchanged lines).
        var newNumber: Int?
    }

    let lines: [Line]

    var added: Int { lines.filter { $0.kind == .added }.count }
    var removed: Int { lines.filter { $0.kind == .removed }.count }

    init(_ patch: String) {
        var lines: [Line] = []
        var oldLine = 0, newLine = 0
        var inHunk = false
        for raw in patch.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.hasSuffix("\r") ? raw.dropLast() : raw
            if line.hasPrefix("@@") {
                inHunk = true
                (oldLine, newLine) = Self.starts(of: line)
                lines.append(Line(kind: .hunk, text: String(line)))
                continue
            }
            guard inHunk else {
                // Header lines; only the ones worth saying are kept.
                if line.hasPrefix("Binary files") || line.hasPrefix("old mode") || line.hasPrefix("new mode")
                    || line.hasPrefix("rename from") || line.hasPrefix("rename to") {
                    lines.append(Line(kind: .note, text: String(line)))
                }
                continue
            }
            switch line.first {
            case "+":
                lines.append(Line(kind: .added, text: String(line.dropFirst()), newNumber: newLine))
                newLine += 1
            case "-":
                lines.append(Line(kind: .removed, text: String(line.dropFirst()), oldNumber: oldLine))
                oldLine += 1
            case " ":
                lines.append(Line(kind: .context, text: String(line.dropFirst()), oldNumber: oldLine, newNumber: newLine))
                oldLine += 1
                newLine += 1
            case "\\":
                lines.append(Line(kind: .note, text: String(line)))
            case nil:
                continue  // the end of the patch
            default:
                // The next file's header (`diff --git`): back to headers.
                inHunk = false
                if line.hasPrefix("Binary files") { lines.append(Line(kind: .note, text: String(line))) }
            }
        }
        self.lines = lines
    }

    /// Some of the lines (0-based, as in `lines`), for a comment: their numbers before and after
    /// the change, and the lines as a unified diff again (`+`, `-` or a space first; hunk
    /// headers and notes as they are).
    func selection(_ indices: ClosedRange<Int>) -> (old: ClosedRange<Int>?, new: ClosedRange<Int>?, text: String) {
        guard !lines.isEmpty else { return (nil, nil, "") }
        let picked = lines[max(0, indices.lowerBound)...min(lines.count - 1, indices.upperBound)]
        let old = picked.compactMap(\.oldNumber)
        let new = picked.compactMap(\.newNumber)
        let text = picked.map { line -> String in
            switch line.kind {
            case .added: "+" + line.text
            case .removed: "-" + line.text
            case .context: " " + line.text
            case .hunk, .note: line.text
            }
        }.joined(separator: "\n")
        return (old.min().map { $0...(old.max() ?? $0) }, new.min().map { $0...(new.max() ?? $0) }, text)
    }

    /// The first old and new line numbers in `@@ -12,5 +12,7 @@`.
    private static func starts(of header: Substring) -> (Int, Int) {
        func number(after marker: Character) -> Int {
            guard let start = header.firstIndex(of: marker) else { return 1 }
            let digits = header[header.index(after: start)...].prefix { $0.isNumber }
            return Int(digits) ?? 1
        }
        return (number(after: "-"), number(after: "+"))
    }
}
