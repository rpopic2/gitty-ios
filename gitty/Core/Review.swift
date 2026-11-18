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

    var lineLabel: String {
        startLine == endLine ? "\(startLine)" : "\(startLine)-\(endLine)"
    }
}

/// Building the review text.
nonisolated enum ReviewText {
    /// What a new comment adds. The cursor goes at its end, ready for typing.
    static func block(for selection: ReviewSelection, format: ReviewFormat) -> String {
        switch format {
        case .compact:
            return "\(selection.location):\(selection.lineLabel): "
        case .markdown:
            let code = selection.code.trimmingCharacters(in: .newlines)
            return "### \(selection.location):\(selection.lineLabel)\n\n"
                + "```\(selection.language ?? "")\n\(code)\n```\n\n"
        }
    }

    /// The review with a new comment added at the end: on its own line (compact) or after a
    /// blank line (Markdown). Trailing blank lines of the draft are dropped first.
    static func appending(_ block: String, to draft: String, format: ReviewFormat) -> String {
        var trimmed = draft
        while let last = trimmed.last, last.isWhitespace { trimmed.removeLast() }
        guard !trimmed.isEmpty else { return block }
        return trimmed + (format == .compact ? "\n" : "\n\n") + block
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
