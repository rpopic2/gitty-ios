import Foundation

/// How a comment starts in the review text. Chosen in Settings; it applies to comments added
/// after the change (the review itself is plain text you can edit freely).
nonisolated enum ReviewFormat: String, CaseIterable, Identifiable, Sendable {
    /// `alc/main.c:12-14: ` then your comment, like a compiler message. Short; the reader needs
    /// the code at hand.
    case compact
    /// A heading with the file and lines, the selected code in a fenced block, then your comment.
    case markdown

    var id: Self { self }
}

/// The repository a comment is about, named once at the top of the review (its first comment
/// on it adds the heading), so each comment needs only what's its own.
nonisolated struct ReviewRepository: Equatable, Sendable {
    /// `owner/repo`.
    let name: String
    /// The branch or tag the project is on.
    var ref: String?
    /// The commit it's at, when it's cloned.
    var commit: String?

    /// `Review of owner/repo (branch main, at 3f2a9c1)`.
    var heading: String {
        let details = [ref.map { "branch \($0)" }, commit.map { "at \(ReviewText.shortHash($0))" }].compactMap { $0 }
        return Self.headingPrefix(name) + (details.isEmpty ? "" : " (" + details.joined(separator: ", ") + ")")
    }

    static func headingPrefix(_ name: String) -> String {
        "Review of \(name)"
    }
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
            let code = selection.code.trimmingCharacters(in: .newlines)
            return "### \(selection.label)\n\n"
                + "```\(selection.language ?? "")\n\(code)\n```\n\n"
        }
    }

    /// A comment on lines of a diff: compact, the label alone; Markdown, the label, the commit
    /// (full hash and message), and the selected change in a `diff` fence.
    static func block(for selection: ReviewDiffSelection, format: ReviewFormat) -> String {
        switch format {
        case .compact:
            return "\(selection.label): "
        case .markdown:
            let renamed = selection.oldPath.map { " (renamed from \($0))" } ?? ""
            let diff = selection.diff.trimmingCharacters(in: .newlines)
            return "### \(selection.label)\n\n"
                + "Commit \(selection.commit)\(renamed): \(selection.summary)\n\n"
                + "```diff\n\(diff)\n```\n\n"
        }
    }

    /// The review with a new comment added at the end: on its own line (compact) or after a
    /// blank line (Markdown). Trailing blank lines of the draft are dropped first. The first
    /// comment on a repository brings its heading (`ReviewRepository.heading`).
    static func appending(_ block: String, to draft: String, format: ReviewFormat,
                          repository: ReviewRepository? = nil) -> String {
        var trimmed = draft
        while let last = trimmed.last, last.isWhitespace { trimmed.removeLast() }
        var block = block
        if let repository, !trimmed.contains(ReviewRepository.headingPrefix(repository.name)) {
            block = (format == .compact ? repository.heading + "\n" : "## " + repository.heading + "\n\n") + block
        }
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
