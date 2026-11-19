import SwiftUI

/// The history of the branch (or tag) a project is on, newest first, from its clone: Clone
/// first if there's none. Tap a commit for the files it changed, and a file for its diff.
struct BranchHistoryView: View {
    @State private var model: BranchHistoryModel
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
            .refreshable { await model.pull() }
        }
        .task { await model.load() }
    }

    private var cloneSection: some View {
        Section {
            if let progress = model.cloneProgress {
                HStack {
                    ProgressView(value: progress)
                    Text(progress, format: .percent.precision(.fractionLength(0)))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Cloning")
            } else {
                Button {
                    Task { await model.cloneProject() }
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
    private(set) var cloneProgress: Double?
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
        cloneProgress = 0
        let (fractions, continuation) = AsyncStream.makeStream(of: Double.self, bufferingPolicy: .bufferingNewest(1))
        let listener = Task {
            for await fraction in fractions where cloneProgress != nil { cloneProgress = fraction }
        }
        do {
            try await CloneStore.shared.clone(project) { continuation.yield($0) }
            continuation.finish()
            clone = await CloneStore.shared.record(forProject: projectID)
        } catch {
            continuation.finish()
            errorMessage = error.localizedDescription
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
        }
    }
}

/// A changed file: what happened to it, its name and folder.
private struct ChangeRow: View {
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
