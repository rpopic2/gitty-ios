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
                            DiffPage(projectID: projectID, commit: commit.id, change: change)
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

/// One file's changes in a commit: a unified diff, added lines green and removed lines red,
/// each with its line number, in the code font and syntax colors.
private struct DiffPage: View {
    let projectID: String
    let commit: String
    let change: GitChange

    @State private var diff: UnifiedDiff?
    @State private var errorMessage: String?
    @Environment(\.codeTextStyle) private var codeTextStyle

    var body: some View {
        Group {
            if let diff {
                if diff.lines.isEmpty {
                    ContentUnavailableView(change.kind == .renamed ? "Renamed, Not Changed" : "No Changes to Show",
                                           systemImage: "doc")
                } else {
                    lines(diff)
                }
            } else if let errorMessage {
                ContentUnavailableView("Couldn’t Show This File", systemImage: "exclamationmark.triangle",
                                       description: Text(errorMessage))
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(uiColor: RawTextStyle.backgroundColor))
        .task(id: change.path) {
            do {
                let patch = try await CloneStore.shared.patch(projectID: projectID, commit: commit, path: change.path)
                diff = await Task.detached(priority: .userInitiated) { UnifiedDiff(patch) }.value
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func lines(_ diff: UnifiedDiff) -> some View {
        let fileExtension = (change.path as NSString).pathExtension
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(diff.lines.indices, id: \.self) { index in
                    DiffLineRow(line: diff.lines[index], fileExtension: fileExtension, style: codeTextStyle)
                }
            }
            .padding(.vertical, 8)
        }
    }
}

private struct DiffLineRow: View {
    let line: UnifiedDiff.Line
    let fileExtension: String
    let style: CodeTextStyle

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(number)
                .font(.system(size: max(9, style.size - 3), design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 40, alignment: .trailing)
                .padding(.trailing, 6)
            Text(marker)
                .font(style.swiftUIFont)
                .foregroundStyle(markerColor)
                .frame(width: style.size * 0.75, alignment: .leading)
            content
                .font(style.swiftUIFont)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.trailing, 8)
        .padding(.vertical, line.kind == .hunk ? 6 : 0)
        .background(background)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    @ViewBuilder
    private var content: some View {
        switch line.kind {
        case .hunk, .note:
            Text(verbatim: line.text)
                .foregroundStyle(.secondary)
        case .added, .removed, .context:
            Text(SyntaxColoring.shared.attributed(TabExpansion.expand(line.text), fileExtension: fileExtension,
                                                  theme: style.theme))
                .foregroundStyle(Color(uiColor: RawTextStyle.textColor))
        }
    }

    private var number: String {
        (line.newNumber ?? line.oldNumber).map(String.init) ?? ""
    }

    private var marker: String {
        switch line.kind {
        case .added: "+"
        case .removed: "−"
        default: ""
        }
    }

    private var markerColor: Color {
        line.kind == .added ? .green : .red
    }

    private var background: Color {
        switch line.kind {
        case .added: Color.green.opacity(0.16)
        case .removed: Color.red.opacity(0.16)
        case .hunk: Color.blue.opacity(0.08)
        case .context, .note: .clear
        }
    }

    private var accessibilityText: String {
        switch line.kind {
        case .added: String(localized: "Added: \(line.text)")
        case .removed: String(localized: "Removed: \(line.text)")
        default: line.text
        }
    }
}
