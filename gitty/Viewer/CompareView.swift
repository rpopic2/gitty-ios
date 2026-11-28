import SwiftUI

/// Two refs compared (a branch, a tag, a commit or the checkout on either side), from the
/// clone: by default what the second changed since it split off the first (`main...feature`,
/// like a pull request), or switched to the direct difference (`main..feature`). Above the
/// changed files, the sides (tap one to change it), the commits in between, and how many files
/// changed. Tap a file for its diff, full screen (swipe sideways for the others), as a
/// commit's. Push it in a navigation stack.
struct CompareView: View {
    let projectID: String
    @State private var comparison: GitComparison

    @State private var resolved: ResolvedComparison?
    @State private var changes: [GitChange]?
    @State private var problem: CloneError?
    @State private var errorMessage: String?
    @State private var isWorking = false
    @State private var choosing: Which?
    @State private var diffStart: DiffStart?
    /// For the side picker: the clone's branches and tags, and which it has.
    @State private var refs: ProjectRefs?
    @State private var fetched: Set<String> = []
    @Namespace private var diffNamespace
    @Environment(AlbumNaming.self) private var albumNaming: AlbumNaming?

    private enum Which: String, Identifiable {
        case base, head
        var id: String { rawValue }
    }

    private struct DiffStart: Identifiable {
        let path: String
        var id: String { path }
    }

    /// A commit in between, opened from here (its own type, so it doesn't take the stack's
    /// other commit pages' destination).
    struct ComparedCommit: Hashable {
        let commit: GitCommit
    }

    init(projectID: String, base: GitSide, head: GitSide) {
        self.projectID = projectID
        _comparison = State(initialValue: GitComparison(base: base, head: head))
    }

    var body: some View {
        List {
            sidesSection
            if isWorking {
                HStack {
                    ProgressView()
                    Text("Comparing…").foregroundStyle(.secondary)
                }
            } else if let problem {
                problemSection(problem)
            } else if let errorMessage {
                Text(errorMessage).foregroundStyle(.red)
            } else if let resolved, let changes {
                commitsSection(resolved)
                filesSection(changes)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(comparison.title)
        .navigationBarTitleDisplayMode(.inline)
        // The changes as an album: its branches as the clone has them each time it shows.
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Make Album", systemImage: "rectangle.stack.badge.plus") {
                    let source = AlbumDiff.Source.comparison(base: comparison.base, head: comparison.head,
                                                             mode: comparison.mode)
                    albumNaming?.makeDiffAlbum(named: AlbumDiff.name(for: source), projectID: projectID,
                                               diff: AlbumDiff(source: source))
                }
                .disabled(changes?.isEmpty ?? true)
                .accessibilityHint("Makes an album of these changes")
            }
        }
        .navigationDestination(for: ComparedCommit.self) { item in
            CommitFilesView(projectID: projectID, commit: item.commit)
        }
        .task(id: comparison) { await load() }
        .task { await loadRefs() }
        .sheet(item: $choosing) { which in
            BranchPicker(refs: refs, current: nil, recent: RecentRefsStore.standard.names(for: projectID),
                         downloaded: fetched, onChoose: { _, _ in },
                         onChooseSide: { side in
                             if which == .base { comparison.base = side } else { comparison.head = side }
                         })
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .fullScreenCover(item: $diffStart) { start in
            if let resolved {
                CommitDiffView(projectID: projectID, commit: resolved.afterCommit, startPath: start.path,
                               knownChanges: changes, comparison: resolved)
                    .navigationTransition(.zoom(sourceID: start.path, in: diffNamespace))
            }
        }
    }

    // MARK: Sections

    private var sidesSection: some View {
        Section {
            HStack(spacing: 8) {
                sideButton(comparison.base, .base)
                Image(systemName: "arrow.left")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("compared with")
                sideButton(comparison.head, .head)
                Spacer(minLength: 4)
                Button("Swap", systemImage: "arrow.left.arrow.right") {
                    comparison = GitComparison(base: comparison.head, head: comparison.base, mode: comparison.mode)
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
            }
            Picker("Compare", selection: $comparison.mode) {
                Text("Since They Split").tag(GitComparison.Mode.sinceSplit)
                Text("Direct").tag(GitComparison.Mode.direct)
            }
            .pickerStyle(.segmented)
        } footer: {
            Text(comparison.mode == .sinceSplit
                 ? "What \(comparison.head.label) changed since it split off \(comparison.base.label), like a pull request."
                 : "Everything that differs between them, \(comparison.base.label)’s own changes since they split included.")
        }
    }

    private func sideButton(_ side: GitSide, _ which: Which) -> some View {
        Button { choosing = which } label: {
            Label(side.label, systemImage: side.systemImage)
                .font(.body.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .accessibilityHint(which == .base ? Text("Changes the base") : Text("Changes what’s compared"))
    }

    @ViewBuilder
    private func problemSection(_ problem: CloneError) -> some View {
        Section {
            Text(problem.localizedDescription)
            switch problem {
            case .notFetched, .historyTooShort:
                // One offer for all of it: a side that isn't downloaded, and the history back to
                // where they split.
                Button("Download", systemImage: "arrow.down.circle") { downloadMissing() }
                Text("Downloads what’s missing: the branches’ latest commits, and older history until where they split is found.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            default:
                EmptyView()
            }
        }
    }

    private func commitsSection(_ resolved: ResolvedComparison) -> some View {
        Section {
            if resolved.commits.isEmpty {
                Text("No commits in between.").foregroundStyle(.secondary)
            } else {
                DisclosureGroup {
                    ForEach(resolved.commits) { commit in
                        NavigationLink(value: ComparedCommit(commit: commit)) {
                            CommitRow(commit: commit)
                        }
                    }
                } label: {
                    Text(resolved.hasMoreCommits
                         ? String(localized: "More than \(resolved.commits.count) commits")
                         : resolved.commits.count == 1 ? String(localized: "1 commit")
                         : String(localized: "\(resolved.commits.count) commits"))
                }
            }
        }
    }

    private func filesSection(_ changes: [GitChange]) -> some View {
        Section {
            ForEach(changes) { change in
                Button { diffStart = DiffStart(path: change.path) } label: {
                    ChangeRow(change: change)
                }
                .foregroundStyle(.primary)
                .matchedTransitionSource(id: change.path, in: diffNamespace)
            }
            if changes.isEmpty {
                Text("No differences.").foregroundStyle(.secondary)
            }
        } header: {
            Text(changes.count == 1 ? String(localized: "1 file changed") : String(localized: "\(changes.count) files changed"))
        }
    }

    // MARK: Loading

    private func load() async {
        isWorking = true
        defer { isWorking = false }
        problem = nil
        errorMessage = nil
        do {
            let resolved = try await CloneStore.shared.compare(comparison, projectID: projectID)
            changes = try await CloneStore.shared.changes(projectID: projectID, from: resolved.before, to: resolved.after)
            self.resolved = resolved
        } catch let error as CloneError {
            problem = error
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func loadRefs() async {
        refs = await CloneStore.shared.record(forProject: projectID)?.remoteRefs
        fetched = await CloneStore.shared.fetchedRefs(projectID: projectID)
    }

    /// Download: a side that isn't downloaded is fetched (not checked out), and older history
    /// until where they split, then they're compared.
    private func downloadMissing() {
        Task {
            isWorking = true
            do {
                try await CloneStore.shared.download(for: comparison, projectID: projectID)
            } catch {
                errorMessage = error.localizedDescription
            }
            await loadRefs()
            await load()
        }
    }
}
