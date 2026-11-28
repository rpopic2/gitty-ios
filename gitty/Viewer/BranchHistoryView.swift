import SwiftUI

/// The history of the branch (or tag) a project is on, newest first, from its clone: Clone
/// first if there's none. Tap a commit for the files it changed, and a file for its diff.
struct BranchHistoryView: View {
    @State private var model: BranchHistoryModel
    /// A commit held: compared with the checkout.
    @State private var comparedCommit: GitCommit?
    /// Asks before a big download on a mobile network.
    @State private var downloads = DownloadGuard()
    @State private var cloneTask: Task<Void, Never>?
    @Environment(\.dismiss) private var dismiss

    init(projectID: String) {
        _model = State(initialValue: BranchHistoryModel(projectID: projectID))
    }

    var body: some View {
        NavigationStack {
            List {
                if model.clone == nil {
                    if model.hasLoaded { cloneSection }
                } else {
                    historySection
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(model.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .navigationDestination(for: GitCommit.self) { commit in
                CommitFilesView(projectID: model.projectID, commit: commit)
            }
            .navigationDestination(item: $comparedCommit) { commit in
                CompareView(projectID: model.projectID, base: .commit(commit.id), head: .checkedOut)
            }
            .refreshable {
                guard let ref = model.clone?.ref else { return }
                let projectID = model.projectID
                await downloads.run(estimate: { await CloneStore.shared.downloadEstimate(of: ref, projectID: projectID) }) { _ in
                    Task { await model.pull() }
                }
            }
        }
        .downloadConfirmation(downloads)
        .task { await model.load() }
    }

    private var cloneSection: some View {
        Section {
            if let progress = model.cloneProgress {
                HStack {
                    ProgressView(value: progress.fraction)
                    Text(DownloadGuard.progressText(progress, estimate: model.cloneEstimate))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Button("Cancel", systemImage: "xmark.circle.fill") { cloneTask?.cancel() }
                        .labelStyle(.iconOnly)
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .buttonStyle(.borderless)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Cloning")
            } else {
                Button {
                    let projectID = model.projectID
                    Task {
                        await downloads.run(estimate: { await DownloadGuard.cloneEstimate(projectID: projectID) },
                                            isCheap: true) { estimate in
                            cloneTask = Task { await model.cloneProject(estimate: estimate) }
                        }
                    }
                } label: {
                    Label("Clone to See History", systemImage: "arrow.down.circle")
                }
                .disabled(model.project == nil)
            }
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text("The history comes from a clone: Clone downloads the project with Git, its latest commit only. Fetch Older, at the end of the history, downloads older commits when you want them.")
                if let error = model.errorMessage { Text(error).foregroundStyle(.red) }
            }
        }
    }

    private var historySection: some View {
        Section {
            if model.isLoading && model.commits.isEmpty {
                HStack {
                    ProgressView()
                    Text("Loading history…").foregroundStyle(.secondary)
                }
            }
            ForEach(model.commits) { commit in
                NavigationLink(value: commit) {
                    CommitRow(commit: commit)
                }
                // Touch and hold: what's changed since this commit (change either side there).
                .contextMenu {
                    Button("Compare with Checked Out", systemImage: "arrow.left.arrow.right") {
                        comparedCommit = commit
                    }
                }
            }
            if model.hasMoreHere {
                // In the clone already: no download.
                Button("Show More") { Task { await model.showMore() } }
                    .disabled(model.isLoading)
            } else if model.canFetchOlder {
                OlderCommitsRow(fetch: model.olderFetch) { model.fetchOlder() }
            }
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                if model.canFetchOlder, !model.hasMoreHere {
                    Text("The oldest commit here is where the downloaded history starts: Fetch Older downloads \(CloneStore.historyStep) older ones from GitHub.")
                }
                if let error = model.errorMessage ?? model.olderFetch.errorMessage { Text(error).foregroundStyle(.red) }
            }
        }
    }
}

/// What the branch history shows, loaded when it opens.
@MainActor @Observable
final class BranchHistoryModel {
    let projectID: String
    private(set) var project: ProjectInfo?
    private(set) var hasLoaded = false
    private(set) var clone: CloneRecord?
    private(set) var cloneProgress: FetchProgress?
    /// Roughly how much the clone downloads.
    private(set) var cloneEstimate: Int64?
    private(set) var commits: [GitCommit] = []
    /// More commits are in the clone than listed.
    private(set) var hasMoreHere = false
    /// The list reaches where the clone's history starts: older commits are on GitHub.
    private(set) var canFetchOlder = false
    let olderFetch = OlderCommitsFetch()
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    /// How many commits are listed; Show More raises it.
    private var limit = BranchHistoryModel.pageSize

    static let pageSize = 100

    init(projectID: String) {
        self.projectID = projectID
    }

    /// "main", or the project's name before it's known.
    var title: String {
        clone?.ref.name ?? project?.ref ?? String(localized: "History")
    }

    func load() async {
        project = await ProjectStore.shared.project(id: projectID)
        clone = await CloneStore.shared.record(forProject: projectID)
        hasLoaded = true
        if clone != nil { await loadLog() }
    }

    func cloneProject(estimate: Int64? = nil) async {
        guard let project else { return }
        errorMessage = nil
        cloneEstimate = estimate
        cloneProgress = .start
        let (updates, continuation) = AsyncStream.makeStream(of: FetchProgress.self, bufferingPolicy: .bufferingNewest(1))
        let listener = Task {
            for await update in updates where cloneProgress != nil { cloneProgress = update }
        }
        do {
            try await CloneStore.shared.clone(project) { continuation.yield($0) }
            continuation.finish()
            clone = await CloneStore.shared.record(forProject: projectID)
        } catch {
            continuation.finish()
            if !Task.isCancelled { errorMessage = error.localizedDescription }  // Cancel isn't an error
        }
        listener.cancel()
        cloneProgress = nil
        if clone != nil { await loadLog() }
    }

    /// Pull to refresh: the branch's latest commit.
    func pull() async {
        guard clone != nil else { return }
        do {
            try await CloneStore.shared.pull(projectID: projectID)
            clone = await CloneStore.shared.record(forProject: projectID)
        } catch {
            errorMessage = error.localizedDescription
        }
        await loadLog()
    }

    /// More of the commits already in the clone (no download).
    func showMore() async {
        limit += Self.pageSize
        await loadLog()
    }

    /// Fetch Older: older commits from GitHub, then listed.
    func fetchOlder() {
        errorMessage = nil
        olderFetch.start(projectID: projectID) { [weak self] in
            guard let self else { return }
            limit = max(limit, commits.count + CloneStore.historyStep)
            await loadLog()
        }
    }

    /// The commits in the clone, offline: nothing is fetched here (Fetch Older does that).
    private func loadLog() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let result = try await CloneStore.shared.log(projectID: projectID, limit: limit)
            commits = result.commits
            hasMoreHere = result.hasMoreHere
            canFetchOlder = result.reachedDownloadedStart
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// A commit: its message, author, date and hash, then the files it changed. Tap a file for
/// its diff, full screen (swipe sideways for the others).
struct CommitFilesView: View {
    let projectID: String
    let commit: GitCommit
    /// Opened from a line's blame: that file comes first (marked), and its diff opens at the
    /// line's change.
    var focus: BlameFocus? = nil

    @State private var changes: [GitChange]?
    @State private var errorMessage: String?
    @State private var diffStart: DiffStart?
    /// Compare (the toolbar): this commit with the checkout, or anything else.
    @State private var isComparing = false
    /// The diff zooms out of its file's row, and closes like a symbol's card.
    @Namespace private var diffNamespace
    @Environment(AlbumNaming.self) private var albumNaming: AlbumNaming?

    private struct DiffStart: Identifiable {
        let path: String
        /// Where in the file the diff opens (the blamed line), if anywhere.
        var line: Int? = nil
        var id: String { path }
    }

    /// The changes, the blamed file first.
    private func ordered(_ changes: [GitChange]) -> [GitChange] {
        guard let path = focus?.path, let index = changes.firstIndex(where: { $0.path == path }) else { return changes }
        var ordered = changes
        ordered.insert(ordered.remove(at: index), at: 0)
        return ordered
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text(commit.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                         ? String(localized: "No message")
                         : commit.message.trimmingCharacters(in: .whitespacesAndNewlines))
                        .textSelection(.enabled)
                    Text("\(commit.author) · \(commit.date.formatted(date: .abbreviated, time: .shortened))")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text(commit.id)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                .padding(.vertical, 2)
            }
            Section {
                if let changes {
                    ForEach(ordered(changes)) { change in
                        let isFocus = change.path == focus?.path
                        Button {
                            diffStart = DiffStart(path: change.path, line: isFocus ? focus?.line : nil)
                        } label: {
                            HStack {
                                ChangeRow(change: change)
                                if isFocus {
                                    // The file whose blame was tapped.
                                    Image(systemName: "text.line.first.and.arrowtriangle.forward")
                                        .foregroundStyle(.tint)
                                        .accessibilityLabel("The line you tapped")
                                }
                            }
                        }
                        .foregroundStyle(.primary)
                        .matchedTransitionSource(id: change.path, in: diffNamespace)
                    }
                    if changes.isEmpty {
                        Text("This commit didn’t change any files.").foregroundStyle(.secondary)
                    }
                } else if let errorMessage {
                    Text(errorMessage).foregroundStyle(.red)
                } else {
                    HStack {
                        ProgressView()
                        Text("Loading files…").foregroundStyle(.secondary)
                    }
                }
            } header: {
                if let changes { Text("\(changes.count) Files") } else { Text("Files") }
            } footer: {
                if commit.isBoundary {
                    Text("This is where the downloaded history starts, so it shows every file as added.")
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(commit.shortID)
        .navigationBarTitleDisplayMode(.inline)
        // What's changed since this commit, up to the checkout (either side can be changed there).
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Compare", systemImage: "arrow.left.arrow.right") { isComparing = true }
                    .accessibilityHint("Compares this commit with another, or with the checkout")
            }
            // Its changes as an album: a card per file and change, at the Code level.
            ToolbarItem(placement: .primaryAction) {
                Button("Make Album", systemImage: "rectangle.stack.badge.plus") {
                    let source = AlbumDiff.Source.commit(commit.id)
                    albumNaming?.makeDiffAlbum(named: AlbumDiff.name(for: source, commitSummary: commit.summary),
                                               projectID: projectID, diff: AlbumDiff(source: source))
                }
                .disabled(changes?.isEmpty ?? true)
                .accessibilityHint("Makes an album of this commit’s changes")
            }
        }
        .navigationDestination(isPresented: $isComparing) {
            CompareView(projectID: projectID, base: .commit(commit.id), head: .checkedOut)
        }
        .task {
            guard changes == nil else { return }
            do {
                changes = try await CloneStore.shared.changes(projectID: projectID, commit: commit.id)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        .fullScreenCover(item: $diffStart) { start in
            CommitDiffView(projectID: projectID, commit: commit, startPath: start.path, knownChanges: changes,
                           startLine: start.line)
                .navigationTransition(.zoom(sourceID: start.path, in: diffNamespace))
        }
    }
}

/// A changed file: what happened to it, its name and folder.
struct ChangeRow: View {
    let change: GitChange

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: change.kind.systemImage)
                .foregroundStyle(change.kind.tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text((change.path as NSString).lastPathComponent)
                    .lineLimit(1)
                    .truncationMode(.middle)
                let folder = (change.path as NSString).deletingLastPathComponent
                if let oldPath = change.oldPath {
                    Text("from \(oldPath)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                } else if !folder.isEmpty {
                    Text(folder)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityValue(Text(change.kind.title))
    }
}
