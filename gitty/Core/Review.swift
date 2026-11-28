import Foundation

/// How a comment starts in the review text. Chosen in Settings; it applies to comments added
/// after the change (the review itself is plain text you can edit freely).
nonisolated enum ReviewFormat: String, CaseIterable, Identifiable, Sendable {
    /// `alc/main.c:12-14: ` then your comment, like a compiler message. Short; the reader needs
    /// the code at hand.
    case compact
    /// A heading with the file and its line, that line in a fenced block (with its language),
    /// then your comment.
    case markdown

    var id: Self { self }
}

/// What was selected for a comment.
nonisolated struct ReviewSelection: Equatable, Sendable {
    /// The file, as the reader of the review knows it: the path in the repository for project
    /// files, otherwise the URL.
    var location: String
    /// 1-based, inclusive.
    var startLine: Int
    var endLine: Int
    var code: String
    /// For the code fence (`c`, `swift`…), from the file extension.
    var language: String?
    /// The commit the file is at (a cloned project's), so the lines still mean something once
    /// the code has moved on.
    var commit: String? = nil

    var lineLabel: String {
        startLine == endLine ? "\(startLine)" : "\(startLine)-\(endLine)"
    }

    /// `alc/main.c@3f2a9c1:12-14`.
    var label: String {
        location + (commit.map { "@" + ReviewText.shortHash($0) } ?? "") + ":" + lineLabel
    }
}

/// Lines selected in a commit's diff, for a comment: what an LLM (or a person) needs to find
/// them without asking: the commit, the file, the lines before and after, and the change.
nonisolated struct ReviewDiffSelection: Equatable, Sendable {
    /// The file's path in the repository after the commit.
    var path: String
    /// Before it, when the commit renamed it.
    var oldPath: String?
    /// The full hash.
    var commit: String
    /// The commit message's first line.
    var summary: String
    /// The selected lines' numbers in the file before the commit (removed and unchanged lines)
    /// and after it (added and unchanged ones). `nil` for a side with none.
    var oldLines: ClosedRange<Int>?
    var newLines: ClosedRange<Int>?
    /// The selected lines as a unified diff: `+`, `-` or a space first.
    var diff: String

    /// `src/parse.c@3f2a9c1 (before 40-42, after 40-44)`.
    var label: String {
        func lines(_ range: ClosedRange<Int>) -> String {
            range.count == 1 ? "\(range.lowerBound)" : "\(range.lowerBound)-\(range.upperBound)"
        }
        let sides = [oldLines.map { "before " + lines($0) }, newLines.map { "after " + lines($0) }].compactMap { $0 }
        return path + "@" + ReviewText.shortHash(commit) + (sides.isEmpty ? "" : " (" + sides.joined(separator: ", ") + ")")
    }
}

/// Building the review text.
nonisolated enum ReviewText {
    /// What a new comment adds. The cursor goes at its end, ready for typing.
    static func block(for selection: ReviewSelection, format: ReviewFormat) -> String {
        switch format {
        case .compact:
            return "\(selection.label): "
        case .markdown:
            // The selection's first line with something on it, and its number.
            let lines = selection.code.components(separatedBy: "\n")
            let index = lines.firstIndex { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? 0
            let line = lines.indices.contains(index) ? trimmingTrailingWhitespace(lines[index]) : ""
            return markdownBlock(location: selection.location, line: selection.startLine + index,
                                 preview: line, language: selection.language)
        }
    }

    /// `### path:line`, then the line in a fenced block, then room for the comment.
    private static func markdownBlock(location: String, line: Int, preview: String, language: String?) -> String {
        guard !preview.isEmpty else { return "### \(location):\(line)\n\n" }
        return "### \(location):\(line)\n```\(language ?? "")\n\(preview)\n```\n\n"
    }

    private static func trimmingTrailingWhitespace(_ text: String) -> String {
        var text = text
        while let last = text.last, last.isWhitespace { text.removeLast() }
        return text
    }

    /// A comment on a whole file or folder: just its path (a folder's ends with `/`), no code.
    static func block(forPath path: String, format: ReviewFormat) -> String {
        switch format {
        case .compact: return "\(path): "
        case .markdown: return "### \(path)\n\n"
        }
    }

    /// A comment on lines of a diff: compact, the label alone; Markdown, the file and the line
    /// of its first change (after the commit; before it, for a removed line), and that line,
    /// `+` or `-` first, in a `diff` fence.
    static func block(for selection: ReviewDiffSelection, format: ReviewFormat) -> String {
        switch format {
        case .compact:
            return "\(selection.label): "
        case .markdown:
            let lines = selection.diff.components(separatedBy: "\n").filter { !$0.isEmpty }
            let index = lines.firstIndex { $0.hasPrefix("+") || $0.hasPrefix("-") } ?? 0
            guard lines.indices.contains(index) else {
                return "### \(selection.path):\(selection.newLines?.lowerBound ?? selection.oldLines?.lowerBound ?? 1)\n\n"
            }
            let before = lines[..<index]
            let line: Int
            if lines[index].hasPrefix("-") {
                // Its number before the commit: the lines before it there (all but added ones).
                line = (selection.oldLines?.lowerBound ?? 1) + before.filter { !$0.hasPrefix("+") }.count
            } else {
                line = (selection.newLines?.lowerBound ?? 1) + before.filter { !$0.hasPrefix("-") }.count
            }
            return markdownBlock(location: selection.path, line: line,
                                 preview: trimmingTrailingWhitespace(lines[index]), language: "diff")
        }
    }

    /// The review with a new comment added at the end: on its own line (compact) or after a
    /// blank line (Markdown). Trailing blank lines of the draft are dropped first. Each comment
    /// names its file.
    static func appending(_ block: String, to draft: String, format: ReviewFormat) -> String {
        var trimmed = draft
        while let last = trimmed.last, last.isWhitespace { trimmed.removeLast() }
        guard !trimmed.isEmpty else { return block }
        return trimmed + (format == .compact ? "\n" : "\n\n") + block
    }

    /// The first 7 characters, as Git abbreviates a commit.
    static func shortHash(_ commit: String) -> String {
        String(commit.prefix(7))
    }

    /// The 1-based lines a selection covers, from its first character to its last. A selection
    /// that ends with a line break (a whole line selected) ends on that line, not the next.
    static func lines(of range: NSRange, in text: NSString) -> (start: Int, end: Int) {
        let start = lineNumber(at: range.location, in: text)
        let last = max(NSMaxRange(range) - 1, range.location)
        return (start, max(start, lineNumber(at: last, in: text)))
    }

    /// The 1-based line of the character at `location`.
    static func lineNumber(at location: Int, in text: NSString) -> Int {
        let end = min(max(location, 0), text.length)
        var line = 1
        var search = NSRange(location: 0, length: end)
        while true {
            let found = text.range(of: "\n", options: .literal, range: search)
            guard found.location != NSNotFound else { return line }
            line += 1
            let next = NSMaxRange(found)
            search = NSRange(location: next, length: end - next)
        }
    }

    /// How the review names a file: its path in the repository when it belongs to a project,
    /// otherwise its URL.
    static func location(for url: URL, projects: [ProjectInfo]) -> String {
        let address = url.absoluteString
        for project in projects {
            guard let prefix = project.rawURL(for: "")?.absoluteString, address.hasPrefix(prefix) else { continue }
            let path = String(address.dropFirst(prefix.count))
            return path.removingPercentEncoding ?? path
        }
        return address
    }

    /// The code fence language for a file.
    static func language(for url: URL) -> String? {
        let ext = url.pathExtension.lowercased()
        return ext.isEmpty ? nil : ext
    }
}
