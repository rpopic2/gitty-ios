import SwiftUI

/// What a commit changed, one file per page: it opens on the file whose history it came from;
/// swipe sideways for the commit's other changed files, like paging between symbols.
struct CommitDiffView: View {
    let projectID: String
    let commit: GitCommit
    /// The file to open on (its path in the repository).
    let startPath: String

    @State private var changes: [GitChange]?
    @State private var errorMessage: String?
    @State private var currentPath: String?

    var body: some View {
        Group {
            if let changes {
                pager(changes)
            } else if let errorMessage {
                ContentUnavailableView("Couldn’t Show the Changes", systemImage: "exclamationmark.triangle",
                                       description: Text(errorMessage))
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(commit.summary.isEmpty ? commit.shortID : commit.summary)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            do {
                changes = try await CloneStore.shared.changes(projectID: projectID, commit: commit.id)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func pager(_ changes: [GitChange]) -> some View {
        // The file this came from first if the commit changed it under another name.
        let start = changes.first { $0.path == startPath || $0.oldPath == startPath }?.path ?? changes.first?.path
        return VStack(spacing: 0) {
            commitHeader(changes)
            ScrollViewReader { reader in
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 0) {
                        ForEach(changes) { change in
                            DiffPage(projectID: projectID, commit: commit, change: change,
                                     isCurrent: change.path == currentPath)
                                .containerRelativeFrame([.horizontal, .vertical])
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollTargetBehavior(.paging)
                .scrollPosition(id: $currentPath)
                .scrollIndicators(.hidden)
                .onAppear {
                    // `scrollPosition(id:)` ignores a starting value during the first layout.
                    if let start { reader.scrollTo(start, anchor: .leading) }
                    currentPath = start
                }
            }
        }
    }

    /// The commit's author and date, and which changed file this is.
    private func commitHeader(_ changes: [GitChange]) -> some View {
        let index = changes.firstIndex { $0.path == currentPath } ?? 0
        let change = changes.indices.contains(index) ? changes[index] : nil
        return VStack(alignment: .leading, spacing: 2) {
            if let change {
                Text(change.oldPath.map { "\($0) → \(change.path)" } ?? change.path)
                    .font(.footnote.monospaced())
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            HStack(spacing: 4) {
                Text(commit.author)
                Text("·")
                Text(commit.date, format: .dateTime.day().month().year().hour().minute())
                Spacer(minLength: 8)
                if changes.count > 1 {
                    Text("\(index + 1) of \(changes.count)")
                        .monospacedDigit()
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
        .accessibilityElement(children: .combine)
    }
}

/// One file's changes in a commit, as a unified diff on the same text view as a file's page:
/// added lines on green and removed lines on red, across the whole width, hunk headers
/// dimmed, in the code font and syntax colors. The text selects and copies like a page's (no
/// `+` or `-` in it); swipe in from the left edge and hold for the lines' numbers in the file.
private struct DiffPage: View {
    let projectID: String
    let commit: GitCommit
    let change: GitChange
    let isCurrent: Bool

    @State private var text: NSAttributedString?
    /// The diff `text` shows, line for line, for comments.
    @State private var diff: UnifiedDiff?
    @Environment(ReviewDraft.self) private var review: ReviewDraft?
    @AppStorage("reviewFormat") private var reviewFormat: ReviewFormat = .compact
    @State private var isEmpty = false
    @State private var errorMessage: String?
    @Environment(\.codeTextStyle) private var codeTextStyle
    @Environment(HighlightState.self) private var highlights: HighlightState?

    var body: some View {
        Group {
            if isEmpty {
                ContentUnavailableView(change.kind == .renamed ? "Renamed, Not Changed" : "No Changes to Show",
                                       systemImage: "doc")
            } else if let text {
                ReadOnlyTextView(
                    text: text,
                    textID: ObjectIdentifier(text).hashValue,
                    insets: EdgeInsets(),
                    isCurrent: isCurrent,
                    onComment: commentAction,
                    fileExtension: (change.path as NSString).pathExtension,
                    highlight: highlights?.current,
                    onHighlight: { highlights?.current = $0 },
                    lineNumbering: .marked
                )
            } else if let errorMessage {
                ContentUnavailableView("Couldn’t Show This File", systemImage: "exclamationmark.triangle",
                                       description: Text(errorMessage))
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(uiColor: RawTextStyle.backgroundColor))
        // Again for another font or colors.
        .task(id: codeTextStyle) {
            do {
                let patch = try await CloneStore.shared.patch(projectID: projectID, commit: commit.id, path: change.path)
                let style = codeTextStyle
                let fileExtension = (change.path as NSString).pathExtension
                let (parsed, rendered) = await Task.detached(priority: .userInitiated) {
                    let diff = UnifiedDiff(patch)
                    return (diff, DiffText.render(diff, fileExtension: fileExtension, style: style))
                }.value
                isEmpty = rendered == nil
                diff = parsed
                text = rendered?.attributedString
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

extension DiffPage {
    /// Comment in the text menu (when there's a review to add to).
    private var commentAction: (@MainActor (NSRange) -> Void)? {
        guard review != nil else { return nil }
        return { comment(on: $0) }
    }

    /// Comment on the selected lines: the commit, the file, their numbers before and after,
    /// and the selected change as a diff (see `ReviewDiffSelection`). The page's text has one
    /// line per diff line, so the selection's lines are the diff's.
    private func comment(on range: NSRange) {
        guard let diff, let text, let review, range.length > 0, NSMaxRange(range) <= text.length else { return }
        let lines = ReviewText.lines(of: range, in: text.string as NSString)
        let picked = diff.selection((lines.start - 1)...(lines.end - 1))
        let selection = ReviewDiffSelection(path: change.path, oldPath: change.oldPath, commit: commit.id,
                                            summary: commit.summary, oldLines: picked.old, newLines: picked.new,
                                            diff: picked.text)
        let format = reviewFormat
        let projectID = projectID
        Task {
            let repository = await ProjectStore.shared.project(id: projectID).map { project in
                ReviewRepository(name: project.link.owner + "/" + project.link.repo, ref: project.ref,
                                 commit: CloneIndex.shared.record(forProject: projectID)?.commit)
            }
            review.add(selection, format: format, repository: repository)
        }
    }
}

/// A unified diff styled like a raw-text page. Safe off the main thread.
nonisolated enum DiffText {
    /// `nil` when there are no lines to show.
    static func render(_ diff: UnifiedDiff, fileExtension: String, style: CodeTextStyle) -> RenderedText? {
        guard !diff.lines.isEmpty else { return nil }
        let font = style.uiFont
        let text = NSMutableAttributedString(string: diff.lines.map(\.text).joined(separator: "\n"), attributes: [
            .font: font,
            .foregroundColor: RawTextStyle.textColor,
            .paragraphStyle: RawTextStyle.paragraphStyle(for: font),
        ])
        // Code colors over the code lines; the headers are blanked out of what's parsed (same
        // length, so the ranges line up), then dimmed.
        var code = ""
        var location = 0
        var headers: [NSRange] = []
        for (index, line) in diff.lines.enumerated() {
            let length = (line.text as NSString).length
            let range = NSRange(location: location, length: length)
            switch line.kind {
            case .hunk, .note:
                headers.append(range)
                code += String(repeating: " ", count: length)
            case .added, .removed, .context:
                code += line.text
            }
            let decorated = NSRange(location: location, length: length + (index < diff.lines.count - 1 ? 1 : 0))
            if let number = line.newNumber ?? line.oldNumber, line.kind != .hunk {
                text.addAttribute(.lineNumber, value: number, range: decorated)
            }
            if let background = background(for: line.kind) {
                text.addAttribute(.lineBackground, value: background, range: decorated)
            }
            if index < diff.lines.count - 1 { code += "\n" }
            location += length + 1
        }
        if style.theme != .none, let runs = SyntaxHighlighter.runs(in: code, fileExtension: fileExtension) {
            for run in runs {
                guard let category = run.category, let color = style.theme.color(for: category) else { continue }
                text.addAttribute(.foregroundColor, value: color, range: run.range)
            }
        }
        for header in headers {
            text.addAttribute(.foregroundColor, value: UIColor.secondaryLabel, range: header)
        }
        return RenderedText(attributedString: text)
    }

    private static func background(for kind: UnifiedDiff.Line.Kind) -> UIColor? {
        switch kind {
        case .added: UIColor.systemGreen.withAlphaComponent(0.16)
        case .removed: UIColor.systemRed.withAlphaComponent(0.16)
        case .hunk: UIColor.systemBlue.withAlphaComponent(0.08)
        case .context, .note: nil
        }
    }
}
