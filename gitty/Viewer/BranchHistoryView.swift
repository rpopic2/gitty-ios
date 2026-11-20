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
                await downloads.run(estimate: { await CloneStore.shared.downloadEstimate(of: ref, projectID: projectID) }) {
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
                    Text(Int64(progress.receivedBytes), format: .byteCount(style: .file))
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
                        await downloads.run(estimate: { await DownloadGuard.cloneEstimate(projectID: projectID) }) {
                            cloneTask = Task { await model.cloneProject() }
                        }
                    }
                } label: {
                    Label("Clone to See History", systemImage: "arrow.down.circle")
                }
                .disabled(model.project == nil)
            }
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text("The history comes from a clone: Clone downloads the project with Git, its latest commit first, then more history as you scroll back.")
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
            if model.canLoadMore {
                Button {
                    Task { await model.loadMore() }
                } label: {
                    HStack {
                        Text("Load More History")
                        if model.isLoading {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(model.isLoading)
            }
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                if model.commits.last?.isBoundary == true {
                    Text("The oldest commit here is where the downloaded history starts: Load More History fetches 100 more.")
                }
                if let error = model.errorMessage { Text(error).foregroundStyle(.red) }
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
    private(set) var commits: [GitCommit] = []
    private(set) var canLoadMore = false
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    /// How many commits are listed; Load More raises it.
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
        if clone != nil { await loadLog(deepeningIfShallow: true) }
    }

    func cloneProject() async {
        guard let project else { return }
        errorMessage = nil
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
        if clone != nil { await loadLog(deepeningIfShallow: true) }
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
        await loadLog(deepeningIfShallow: false)
    }

    /// More commits: further back, fetching more history from GitHub when the downloaded
    /// history is used up.
    func loadMore() async {
        isLoading = true
        errorMessage = nil
        do {
            if commits.last?.isBoundary == true {
                try await CloneStore.shared.loadMoreHistory(projectID: projectID)
            }
            limit += Self.pageSize
        } catch {
            errorMessage = error.localizedDescription
        }
        await loadLog(deepeningIfShallow: false)
    }

    /// - Parameter deepeningIfShallow: a fresh clone has just its latest commit: fetch the
    ///   next ones right away.
    private func loadLog(deepeningIfShallow: Bool) async {
        isLoading = true
        defer { isLoading = false }
        do {
            var result = try await CloneStore.shared.log(projectID: projectID, limit: limit)
            if deepeningIfShallow, result.commits.count < 2, result.commits.last?.isBoundary == true {
                try await CloneStore.shared.loadMoreHistory(projectID: projectID)
                result = try await CloneStore.shared.log(projectID: projectID, limit: limit)
            }
            commits = result.commits
            canLoadMore = result.canLoadMore
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

    @State private var changes: [GitChange]?
    @State private var errorMessage: String?
    @State private var diffStart: DiffStart?
    /// Compare (the toolbar): this commit with the checkout, or anything else.
    @State private var isComparing = false
    /// The diff zooms out of its file's row, and closes like a symbol's card.
    @Namespace private var diffNamespace

    private struct DiffStart: Identifiable {
        let path: String
        var id: String { path }
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
                    ForEach(changes) { change in
                        Button {
                            diffStart = DiffStart(path: change.path)
                        } label: {
                            ChangeRow(change: change)
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
            CommitDiffView(projectID: projectID, commit: commit, startPath: start.path, knownChanges: changes)
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
