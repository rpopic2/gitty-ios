import SwiftUI

/// A file's info, like a photo's in Photos: tap a page's caption (or a file in Project) to see it.
/// Its path, size and lines, its last change and its history (from the project's clone: Clone
/// first if there's none), and a link to it on github.com. Tap a commit to see what it changed.
struct FileInfoView: View {
    @State private var model: FileInfoModel
    /// The commit whose diff is open, full screen.
    @State private var diffPage: CommitPage?
    /// Asks before a big download on a mobile network.
    @State private var downloads = DownloadGuard()
    @State private var cloneTask: Task<Void, Never>?
    /// The diff zooms out of its commit's row, and closes like a symbol's card.
    @Namespace private var diffNamespace
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    /// Open, in place of Done: from the Project tab, where a tap on a file shows this first.
    private let onOpen: (@MainActor () -> Void)?
    /// Open Whole File: the file's card, stacked, at the symbol this was opened from.
    private let onOpenWholeFile: (@MainActor () -> Void)?

    /// - Parameters:
    ///   - knownSize: its size from the project's file list, for a file that isn't downloaded.
    ///   - onOpen: shows an Open button that opens the file's code.
    ///   - onOpenWholeFile: shows Open Whole File (from a symbol: its file, stacked).
    init(url: URL, knownSize: Int? = nil, onOpen: (@MainActor () -> Void)? = nil,
         onOpenWholeFile: (@MainActor () -> Void)? = nil) {
        _model = State(initialValue: FileInfoModel(url: url, knownSize: knownSize))
        self.onOpen = onOpen
        self.onOpenWholeFile = onOpenWholeFile
    }

    var body: some View {
        NavigationStack {
            List {
                fileSection
                if let location = model.location {
                    if model.clone == nil {
                        cloneSection(location)
                    } else {
                        lastChangeSection(location)
                        historySection(location)
                    }
                } else if model.hasLoaded {
                    Section {
                        Text("History is shown for files in a project, at the branch the project is on.")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(model.url.displayFileName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    // From Project, Open takes Done's place (a swipe down still closes it).
                    if let onOpen {
                        Button("Open") { onOpen() }
                    } else {
                        Button("Done") { dismiss() }
                    }
                }
            }
        }
        .downloadConfirmation(downloads)
        .task { await model.load() }
        .fullScreenCover(item: $diffPage) { page in
            CommitDiffView(projectID: page.projectID, commit: page.commit, startPath: page.path)
                .navigationTransition(.zoom(sourceID: page.id, in: diffNamespace))
        }
    }

    // MARK: Sections

    private var fileSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Text(model.location?.path ?? model.url.absoluteString)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                if let summary = model.sizeSummary {
                    Text(summary)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 2)
            if let onOpenWholeFile {
                Button {
                    dismiss()
                    onOpenWholeFile()
                } label: {
                    Label("Open Whole File", systemImage: "doc.text")
                }
            }
            if let webURL = model.location?.webURL {
                Button {
                    openURL(webURL)
                } label: {
                    Label("Open on GitHub", systemImage: "arrow.up.right.square")
                }
            }
        }
    }

    private func cloneSection(_ location: ProjectFileLocation) -> some View {
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
                    let projectID = location.project.id
                    Task {
                        await downloads.run(estimate: { await DownloadGuard.cloneEstimate(projectID: projectID) },
                                            isCheap: true) { estimate in
                            cloneTask = Task { await model.clone(estimate: estimate) }
                        }
                    }
                } label: {
                    Label("Clone to See History", systemImage: "arrow.down.circle")
                }
            }
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text("Clone downloads \(location.project.title) with Git, its latest commit only; then as much history as this file needs.")
                if let error = model.errorMessage { Text(error).foregroundStyle(.red) }
            }
        }
    }

    @ViewBuilder
    private func lastChangeSection(_ location: ProjectFileLocation) -> some View {
        if let last = model.history.first {
            Section("Last Change") {
                commitLink(last, location: location)
            }
        }
    }

    private func historySection(_ location: ProjectFileLocation) -> some View {
        Section {
            if model.isLoading && model.history.isEmpty {
                HStack {
                    ProgressView()
                    Text("Loading history…").foregroundStyle(.secondary)
                }
            }
            ForEach(model.history.dropFirst()) { commit in
                commitLink(commit, location: location)
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
        } header: {
            Text("History")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                if model.history.last?.isBoundary == true {
                    Text("The oldest commit here is where the downloaded history starts: the file may have changed in it or before.")
                }
                if let error = model.errorMessage { Text(error).foregroundStyle(.red) }
            }
        }
    }

    /// A commit: tap for its diff, full screen, at this file.
    private func commitLink(_ commit: GitCommit, location: ProjectFileLocation) -> some View {
        let page = CommitPage(projectID: location.project.id, commit: commit, path: location.path)
        return Button {
            diffPage = page
        } label: {
            HStack {
                CommitRow(commit: commit)
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .foregroundStyle(.primary)
        .matchedTransitionSource(id: page.id, in: diffNamespace)
    }
}

/// A commit to show the diff of, from a file's history.
private struct CommitPage: Hashable, Identifiable {
    let projectID: String
    let commit: GitCommit
    let path: String

    var id: String { commit.id + "/" + path }
}

/// The commit's first line, then its author, when and its short hash.
struct CommitRow: View {
    let commit: GitCommit

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(commit.summary.isEmpty ? String(localized: "No message") : commit.summary)
                .lineLimit(2)
            HStack(spacing: 4) {
                Text(commit.author)
                Text("·")
                Text(commit.date, format: .relative(presentation: .named))
                Text("·")
                Text(commit.shortID).monospaced()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }
}

/// What the info panel shows, loaded when it opens.
@MainActor @Observable
final class FileInfoModel {
    let url: URL
    private(set) var location: ProjectFileLocation?
    private(set) var hasLoaded = false
    private(set) var sizeSummary: String?
    private(set) var clone: CloneRecord?
    private(set) var cloneProgress: FetchProgress?
    /// Roughly how much the clone downloads.
    private(set) var cloneEstimate: Int64?
    private(set) var history: [GitCommit] = []
    private(set) var canLoadMore = false
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    /// How many commits the history walk looks at; Load More raises it.
    private var limit = 300

    /// When a fresh shallow clone has no change of this file yet: fetch more this many times.
    private static let automaticDeepening = 3

    /// From the project's file list, until the file is downloaded.
    private let knownSize: Int?

    init(url: URL, knownSize: Int? = nil) {
        self.url = url
        self.knownSize = knownSize
    }

    func load() async {
        let projects = await ProjectStore.shared.projects()
        location = ProjectFileLocation.locate(url, in: projects)
        if let document = await DocumentStore.shared.cached(url) {
            let bytes = document.data.count
            let lines = document.data.reduce(into: 0) { count, byte in if byte == 0x0A { count += 1 } }
                + (document.data.last == 0x0A || document.data.isEmpty ? 0 : 1)
            sizeSummary = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
                + " · " + String(localized: "\(lines) lines")
        } else if let knownSize {
            // Not downloaded: the size GitHub listed; its lines are counted once it's saved.
            sizeSummary = ByteCountFormatter.string(fromByteCount: Int64(knownSize), countStyle: .file)
                + " · " + String(localized: "Not downloaded")
        }
        if let location { clone = await CloneStore.shared.record(forProject: location.project.id) }
        hasLoaded = true
        if clone != nil { await loadHistory(deepeningIfEmpty: true) }
    }

    /// Clones the project, then shows the history.
    func clone(estimate: Int64? = nil) async {
        guard let project = location?.project else { return }
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
            clone = await CloneStore.shared.record(forProject: project.id)
        } catch {
            continuation.finish()
            if !Task.isCancelled { errorMessage = error.localizedDescription }  // Cancel isn't an error
        }
        listener.cancel()
        cloneProgress = nil
        if clone != nil { await loadHistory(deepeningIfEmpty: true) }
    }

    /// More commits: looks further back, fetching more history from GitHub when the clone's
    /// downloaded history is used up.
    func loadMore() async {
        guard let projectID = location?.project.id else { return }
        isLoading = true
        errorMessage = nil
        do {
            if history.last?.isBoundary == true || history.isEmpty {
                try await CloneStore.shared.loadMoreHistory(projectID: projectID)
            }
            limit += 300
        } catch {
            errorMessage = error.localizedDescription
        }
        await loadHistory(deepeningIfEmpty: false)
    }

    private func loadHistory(deepeningIfEmpty: Bool) async {
        guard let location else { return }
        let projectID = location.project.id
        isLoading = true
        defer { isLoading = false }
        do {
            var result = try await CloneStore.shared.history(projectID: projectID, path: location.path, limit: limit)
            var deepened = 0
            // A shallow clone only knows the file is there: fetch until a real change shows up.
            while deepeningIfEmpty, result.canLoadMore, !result.commits.contains(where: { !$0.isBoundary }),
                  deepened < Self.automaticDeepening {
                try await CloneStore.shared.loadMoreHistory(projectID: projectID)
                deepened += 1
                result = try await CloneStore.shared.history(projectID: projectID, path: location.path, limit: limit)
            }
            history = result.commits
            canLoadMore = result.canLoadMore
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
