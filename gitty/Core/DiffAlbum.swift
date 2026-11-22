import Foundation

/// What a diff album shows (`Album.diff`): the changes of a commit, or between two branches,
/// tags or commits. Made from a commit's or a comparison's list of changed files.
nonisolated struct AlbumDiff: Codable, Hashable, Sendable {
    enum Source: Codable, Hashable, Sendable {
        /// A commit's changes, against its first parent: always the same.
        case commit(String)
        /// What's between two sides as the clone has them now: a branch follows its local commit
        /// (a pull down moves it), nothing is fetched to show it.
        case comparison(base: GitSide, head: GitSide, mode: GitComparison.Mode)
    }

    let source: Source

    /// The album's name: the commit's message, or the comparison's "main...feature".
    static func name(for source: Source, commitSummary: String? = nil) -> String {
        switch source {
        case .commit(let id):
            let summary = (commitSummary ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return summary.isEmpty ? String(localized: "Commit \(String(id.prefix(7)))") : String(summary.prefix(60))
        case .comparison(let base, let head, let mode):
            return GitComparison(base: base, head: head, mode: mode).title
        }
    }
}

/// A diff album's card (`CodeSymbol.diff`): a changed file's entry, or one of its hunks.
nonisolated struct DiffPart: Hashable, Sendable {
    let change: GitChange.Kind
    /// The file's path in the repository (after the change; before it, for a deleted file).
    let path: String
    /// Before a rename or copy.
    var oldPath: String? = nil
    /// A hunk's lines, without its `@@` header (none for the file's entry).
    var lines: [UnifiedDiff.Line] = []
    /// How many lines the file's hunks before this one add and remove: where its lines are in
    /// the file's whole diff.
    var addedBefore = 0
    var removedBefore = 0

    /// Where a hunk's line (0-based, in `lines`) is in the file's whole diff (a `wholeFile`
    /// patch: one hunk, every line of the file, its header first). Every change is in both,
    /// only the unchanged lines around them differ, so it's counted from the line's own number
    /// and the changes before it.
    func wholeDiffLine(of index: Int) -> Int {
        guard !lines.isEmpty else { return 0 }
        let index = min(max(index, 0), lines.count - 1)
        var added = addedBefore, removed = removedBefore
        for line in lines[..<index] {
            if line.kind == .added { added += 1 } else if line.kind == .removed { removed += 1 }
        }
        let line = lines[index]
        let before: Int
        if line.kind != .removed, let new = line.newNumber {
            before = (new - 1) + removed  // the new file's lines before it, and what was removed
        } else if let old = line.oldNumber {
            before = (old - 1) + added  // the old file's lines before it, and what was added
        } else {
            before = 0
        }
        return before + 1  // after the hunk's header
    }

    /// A comment on the whole hunk: its lines' numbers before and after, and the lines.
    func reviewSelection(commit: String, summary: String) -> ReviewDiffSelection {
        let old = lines.compactMap(\.oldNumber)
        let new = lines.compactMap(\.newNumber)
        let text = lines.map { line in
            switch line.kind {
            case .added: "+" + line.text
            case .removed: "-" + line.text
            case .context: " " + line.text
            case .hunk, .note: line.text
            }
        }.joined(separator: "\n")
        return ReviewDiffSelection(path: path, oldPath: oldPath, commit: commit, summary: summary,
                                   oldLines: old.min().map { $0...(old.max() ?? $0) },
                                   newLines: new.min().map { $0...(new.max() ?? $0) }, diff: text)
    }

    /// A hunk's first changed line (0-based, in `lines`), where its page opens.
    var firstChange: Int {
        lines.firstIndex { $0.kind == .added || $0.kind == .removed } ?? 0
    }
}

/// The commits a diff album's changes are between, as the clone has them now.
nonisolated struct DiffSides: Hashable, Sendable {
    /// A commit's album: its changes against its first parent (`before` isn't used).
    let commit: String?
    let before: String
    let after: String
}

/// A diff album's cards, from the clone (offline): each changed file's entry, then its hunks
/// (each like a symbol under its file's title: its title is the code it's in, as Git finds it
/// for the hunk's header, or its lines).
nonisolated enum DiffAlbumContents {
    /// - Throws: `CloneError.notFetched` for a side the clone hasn't downloaded,
    ///   `.historyTooShort` when where two branches split isn't downloaded.
    static func load(_ diff: AlbumDiff, project: ProjectInfo) async throws -> (DiffSides, [CodeSymbol]) {
        let store = CloneStore.shared
        let projectID = project.id
        let sides: DiffSides
        let changes: [GitChange]
        switch diff.source {
        case .commit(let id):
            sides = DiffSides(commit: id, before: id, after: id)
            changes = try await store.changes(projectID: projectID, commit: id)
        case .comparison(let base, let head, let mode):
            let resolved = try await store.compare(GitComparison(base: base, head: head, mode: mode), projectID: projectID)
            sides = DiffSides(commit: nil, before: resolved.before, after: resolved.after)
            changes = try await store.changes(projectID: projectID, from: resolved.before, to: resolved.after)
        }
        // A project of a folder shows that folder's changes.
        let folder = project.folder.map { $0.isEmpty ? "" : $0 + "/" } ?? ""
        var cards: [CodeSymbol] = []
        for change in changes where folder.isEmpty || change.path.hasPrefix(folder) {
            let patch = try await self.patch(of: change.path, sides: sides, projectID: projectID)
            cards += self.cards(for: change, patch: patch, project: project)
        }
        return (sides, cards)
    }

    /// A file's patch between the sides: 3 lines around each change, or the whole file.
    static func patch(of path: String, sides: DiffSides, projectID: String, wholeFile: Bool = false) async throws -> String {
        if let commit = sides.commit {
            return try await CloneStore.shared.patch(projectID: projectID, commit: commit, path: path, wholeFile: wholeFile)
        }
        return try await CloneStore.shared.patch(projectID: projectID, from: sides.before, to: sides.after,
                                                 path: path, wholeFile: wholeFile)
    }

    /// A changed file's entry, then a card for each of its hunks.
    static func cards(for change: GitChange, patch: String, project: ProjectInfo) -> [CodeSymbol] {
        let url = project.rawURL(for: change.path)
        let fileHash = CodeSymbol.fileHash("diff:" + change.path)
        let name = (change.path as NSString).lastPathComponent
        var cards = [CodeSymbol(id: CodeSymbol.stableID(fileHash: fileHash, index: 0), name: name, kind: .file,
                                range: NSRange(location: 0, length: 0), line: 1, preview: "", fileURL: url,
                                diff: DiffPart(change: change.kind, path: change.path, oldPath: change.oldPath))]
        var added = 0, removed = 0
        for (index, hunk) in hunks(of: UnifiedDiff(patch)).enumerated() {
            let part = DiffPart(change: change.kind, path: change.path, oldPath: change.oldPath, lines: hunk.lines,
                                addedBefore: added, removedBefore: removed)
            added += hunk.lines.filter { $0.kind == .added }.count
            removed += hunk.lines.filter { $0.kind == .removed }.count
            let first = hunk.lines.first { $0.kind == .added || $0.kind == .removed } ?? hunk.lines.first
            let line = first?.newNumber ?? first?.oldNumber ?? 1
            cards.append(CodeSymbol(id: CodeSymbol.stableID(fileHash: fileHash, index: index + 1),
                                    name: title(of: hunk), kind: .hunk,
                                    range: NSRange(location: 0, length: 0), line: line,
                                    preview: preview(of: hunk.lines), fileURL: url, diff: part))
        }
        return cards
    }

    /// The hunks of a file's diff: each one's header and lines.
    static func hunks(of diff: UnifiedDiff) -> [(header: String, lines: [UnifiedDiff.Line])] {
        var hunks: [(header: String, lines: [UnifiedDiff.Line])] = []
        for line in diff.lines {
            if line.kind == .hunk {
                hunks.append((line.text, []))
            } else if !hunks.isEmpty, line.kind != .note {
                hunks[hunks.count - 1].lines.append(line)
            }
        }
        return hunks.filter { !$0.lines.isEmpty }
    }

    /// A hunk's title: the code it's in, from its header (`@@ -40,7 +40,9 @@ static int parse(…)`,
    /// Git's guess at the enclosing function), or its lines ("Lines 40–48").
    static func title(of hunk: (header: String, lines: [UnifiedDiff.Line])) -> String {
        let header = hunk.header
        if header.hasPrefix("@@"), let close = header.dropFirst(2).range(of: "@@") {
            let context = header[close.upperBound...].trimmingCharacters(in: .whitespaces)
            if !context.isEmpty { return context }
        }
        let numbers = hunk.lines.compactMap { $0.newNumber }
        let lines = numbers.isEmpty ? hunk.lines.compactMap(\.oldNumber) : numbers
        guard let first = lines.min(), let last = lines.max() else { return String(localized: "Change") }
        return CodeSymbol.linesLabel(first, last)
    }

    /// A hunk as a unified diff again: its title, then its lines with `+`, `-` or a space first.
    static func unified(_ lines: [UnifiedDiff.Line], header: String) -> String {
        ([header] + lines.map { line in
            switch line.kind {
            case .added: "+" + line.text
            case .removed: "-" + line.text
            case .context: " " + line.text
            case .hunk, .note: line.text
            }
        }).joined(separator: "\n")
    }

    /// The first few lines, `+`, `-` or a space first: what stands in until its code is laid out.
    static func preview(of lines: [UnifiedDiff.Line]) -> String {
        lines.prefix(SymbolIndexer.previewLineCount).map { line in
            switch line.kind {
            case .added: "+" + line.text
            case .removed: "-" + line.text
            default: " " + line.text
            }
        }.joined(separator: "\n")
    }
}
