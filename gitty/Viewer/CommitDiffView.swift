import SwiftUI

/// What a commit changed, one file per page, full screen like a symbol's card: it opens on
/// one file; swipe sideways for the commit's other changed files. A caption at the bottom says
/// which file, who and when. Pull down past the top of a page, or pinch, to close.
/// Present it with `fullScreenCover`.
struct CommitDiffView: View {
    let projectID: String
    let commit: GitCommit
    /// The file to open on (its path in the repository).
    let startPath: String
    /// The commit's changes, when they're known already (from its list of files).
    var knownChanges: [GitChange]? = nil

    @State private var changes: [GitChange]?
    @State private var errorMessage: String?
    @State private var currentPath: String?
    /// Scrolling down a page hides the caption; scrolling up shows it.
    @State private var isCaptionHidden = false
    @State private var pinchHandled = false
    @Environment(\.dismiss) private var dismiss
    /// Comments on a diff open the review over this screen.
    @Environment(ReviewDraft.self) private var review: ReviewDraft?

    var body: some View {
        GeometryReader { proxy in
            // Pages sit inside a scroll view, where UIKit gives them no safe-area insets: hand
            // each the screen's (as the card does).
            let safeArea = proxy.safeAreaInsets
            let pageInsets = EdgeInsets(top: 0, leading: safeArea.leading,
                                        bottom: safeArea.bottom + DiffCaption.reservedHeight
                                            + (review?.isDocked == true ? ReviewDock.reservedHeight : 0),
                                        trailing: safeArea.trailing)
            ZStack(alignment: .bottom) {
                if let changes {
                    pager(changes, insets: pageInsets, top: safeArea.top)
                } else if let errorMessage {
                    ContentUnavailableView {
                        Label("Couldn’t Show the Changes", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(errorMessage)
                    } actions: {
                        Button("Close") { dismiss() }
                    }
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                // The caption, then a set-aside review under it (its composer opens over this
                // screen): both hide while you scroll down.
                VStack(spacing: 0) {
                    if let changes, let index = currentIndex(in: changes) {
                        DiffCaption(change: changes[index], commit: commit, index: index, count: changes.count)
                            .padding(.bottom, 8)
                    }
                    if let review, review.isDocked {
                        ReviewDock(draft: review, overSheet: true)
                            .padding(.bottom, 8)
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }
                }
                .offset(y: isCaptionHidden
                    ? DiffCaption.reservedHeight + (review?.isDocked == true ? ReviewDock.reservedHeight : 0) + 40
                    : 0)
                .opacity(isCaptionHidden ? 0 : 1)
                .allowsHitTesting(!isCaptionHidden)
                .accessibilityHidden(isCaptionHidden)
                .animation(.smooth(duration: 0.25), value: isCaptionHidden)
                .animation(.smooth(duration: 0.25), value: review?.isDocked)
            }
        }
        .background(Color(uiColor: RawTextStyle.backgroundColor).ignoresSafeArea())
        .simultaneousGesture(
            MagnifyGesture()
                .onChanged { value in
                    guard !pinchHandled, value.magnification < 0.8 else { return }
                    pinchHandled = true
                    dismiss()
                }
                .onEnded { _ in pinchHandled = false }
        )
        .accessibilityAction(.escape) { dismiss() }
        .accessibilityAction(named: "Close") { dismiss() }
        .task {
            if let knownChanges {
                changes = knownChanges
                return
            }
            do {
                changes = try await CloneStore.shared.changes(projectID: projectID, commit: commit.id)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        .sheet(isPresented: composerIsPresented) {
            if let review { ReviewComposer(draft: review) }
        }
        .onDisappear {
            // Closed while the review was up over it: it's set aside, as a swipe down would.
            if review?.isComposingOverSheet == true { review?.isComposingOverSheet = false }
        }
    }

    private var composerIsPresented: Binding<Bool> {
        Binding(get: { review?.isComposingOverSheet ?? false },
                set: { review?.isComposingOverSheet = $0 })
    }

    private func currentIndex(in changes: [GitChange]) -> Int? {
        changes.isEmpty ? nil : changes.firstIndex { $0.path == currentPath } ?? 0
    }

    @ViewBuilder
    private func pager(_ changes: [GitChange], insets: EdgeInsets, top: CGFloat) -> some View {
        if changes.isEmpty {
            ContentUnavailableView {
                Label("No Changes to Show", systemImage: "doc")
            } actions: {
                Button("Close") { dismiss() }
            }
        } else {
            // The file this came from first, also if the commit changed it under another name.
            let start = changes.first { $0.path == startPath || $0.oldPath == startPath }?.path ?? changes.first?.path
            ScrollViewReader { reader in
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 0) {
                        ForEach(changes) { change in
                            DiffPage(projectID: projectID, commit: commit, change: change,
                                     isCurrent: change.path == currentPath, insets: insets,
                                     onScrollDown: { isCaptionHidden = $0 },
                                     onClose: { dismiss() })
                                // The text starts below the status bar, as on a card.
                                .padding(.top, top)
                                .containerRelativeFrame([.horizontal, .vertical])
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollTargetBehavior(.paging)
                .scrollPosition(id: $currentPath)
                .scrollIndicators(.hidden)
                .ignoresSafeArea()
                .onAppear {
                    // `scrollPosition(id:)` ignores a starting value during the first layout.
                    if let start { reader.scrollTo(start, anchor: .leading) }
                    currentPath = start
                }
                .onChange(of: currentPath) { isCaptionHidden = false }  // each page starts with it
            }
        }
    }
}

/// The diff's caption, at the bottom like a card's: the file (and its old name), then the
/// commit's author and date, and which of the commit's files this is.
private struct DiffCaption: View {
    let change: GitChange
    let commit: GitCommit
    let index: Int
    let count: Int

    static let height: CGFloat = 52
    /// Space kept free under the text so its end isn't hidden behind the caption.
    static let reservedHeight: CGFloat = height + 16

    var body: some View {
        let label = VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: change.kind.systemImage)
                    .foregroundStyle(change.kind.tint)
                Text(change.oldPath.map { "\($0) → \(change.path)" } ?? change.path)
                    .font(.subheadline.monospaced())
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            HStack(spacing: 4) {
                Text(commit.author)
                Text("·")
                Text(commit.date, format: .dateTime.day().month().year().hour().minute())
                Spacer(minLength: 8)
                if count > 1 {
                    Text("\(index + 1) of \(count)")
                        .monospacedDigit()
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        .padding(.horizontal, 18)
        .frame(height: Self.height)
        .accessibilityElement(children: .combine)

        let shape = RoundedRectangle(cornerRadius: Self.height / 2, style: .continuous)
        if #available(iOS 26.0, *) {
            label.glassEffect(.regular, in: shape)
                .padding(.horizontal, 16)
        } else {
            label.background(.bar, in: shape)
                .padding(.horizontal, 16)
        }
    }
}

extension GitChange.Kind {
    var title: LocalizedStringKey {
        switch self {
        case .added: "Added"
        case .deleted: "Deleted"
        case .modified: "Modified"
        case .renamed: "Renamed"
        case .copied: "Copied"
        case .typeChanged: "Type Changed"
        }
    }

    var systemImage: String {
        switch self {
        case .added: "plus.circle.fill"
        case .deleted: "minus.circle.fill"
        case .modified: "pencil.circle.fill"
        case .renamed: "arrow.right.circle.fill"
        case .copied: "doc.on.doc.fill"
        case .typeChanged: "arrow.triangle.2.circlepath.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .added: .green
        case .deleted: .red
        case .modified: .orange
        case .renamed, .copied, .typeChanged: .blue
        }
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
    /// The screen's safe area, plus room for the caption at the bottom.
    let insets: EdgeInsets
    let onScrollDown: @MainActor (Bool) -> Void
    /// Pulled down past the top: the diff closes.
    let onClose: @MainActor () -> Void

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
                ContentUnavailableView {
                    Label(change.kind == .renamed ? "Renamed, Not Changed" : "No Changes to Show", systemImage: "doc")
                } actions: {
                    Button("Close") { onClose() }
                }
            } else if let text {
                ReadOnlyTextView(
                    text: text,
                    textID: ObjectIdentifier(text).hashValue,
                    insets: insets,
                    isCurrent: isCurrent,
                    onComment: commentAction,
                    fileExtension: (change.path as NSString).pathExtension,
                    highlight: highlights?.current,
                    onHighlight: { highlights?.current = $0 },
                    lineNumbering: .marked,
                    onScrollDown: onScrollDown,
                    onPullDown: onClose
                )
            } else if let errorMessage {
                ContentUnavailableView {
                    Label("Couldn’t Show This File", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(errorMessage)
                } actions: {
                    Button("Close") { onClose() }
                }
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
