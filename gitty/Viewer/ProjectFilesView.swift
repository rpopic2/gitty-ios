import SwiftUI
import UIKit

/// The open project in the Project tab: every file, grouped under a header per directory, code
/// files first in each. Tap a file to open it in File mode. Pull to refresh the file list;
/// Download All saves every file for offline reading. The filter under the header (`*.cs *.md`,
/// see `FileFilter`) narrows the list, Download All, and the project's symbols.
struct ProjectFilesView: View {
    let projectID: String
    /// The file on screen, marked in the list.
    let currentURL: URL?
    let onOpen: @MainActor (URL) -> Void

    @State private var state: LoadState = .loading
    /// Files with a saved copy (they open offline).
    @State private var saved: Set<URL> = []
    @State private var download: DownloadProgress?
    @State private var isSignedIn = false
    @State private var isSigningIn = false
    /// The filter as typed. It's applied (and saved) when editing ends.
    @State private var filterText = ""
    @State private var filter = FileFilter.none
    @FocusState private var isEditingFilter: Bool
    @State private var hasLoadedFilter = false
    /// The project's files before filtering.
    @State private var fileCount = 0
    @Environment(\.openURL) private var openURL

    private enum LoadState {
        case loading
        case loaded(ProjectInfo, ProjectTree, [ProjectTree.Directory])
        case failed(any Error)
    }

    private struct DownloadProgress {
        var done: Int
        let total: Int
    }

    /// What Download All would fetch now: the files the filter lets through that aren't saved
    /// (and aren't too big), and their size. Worked out when the list, the filter or the saved
    /// files change, not on every redraw.
    @State private var pending = PendingDownload()

    private struct PendingDownload {
        var urls: [URL] = []
        var bytes: Int64 = 0
    }

    /// Files bigger than this are left out of Download All (they still open one by one).
    private static let downloadAllSizeLimit = 5_000_000

    // An explicit init (not the memberwise one) so passing in an existing `@MainActor` closure
    // doesn't warn about converting it to `@Sendable`.
    init(projectID: String, currentURL: URL?, onOpen: @escaping @MainActor (URL) -> Void) {
        self.projectID = projectID
        self.currentURL = currentURL
        self.onOpen = onOpen
    }

    var body: some View {
        content
            .task { await load(refresh: false) }
            .sheet(isPresented: $isSigningIn) {
                GitHubSignInView {
                    isSigningIn = false
                    Task { await load(refresh: true) }
                }
            }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        switch state {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(uiColor: .systemGroupedBackground))
        case .failed(let error):
            ContentUnavailableView {
                Label("Couldn’t Load Project", systemImage: "exclamationmark.triangle")
            } description: {
                Text(failureMessage(for: error))
            } actions: {
                failureActions(for: error)
            }
            .background(Color(uiColor: .systemGroupedBackground))
        case .loaded(let project, let tree, let directories):
            list(project: project, tree: tree, directories: directories)
        }
    }

    private func list(project: ProjectInfo, tree: ProjectTree, directories: [ProjectTree.Directory]) -> some View {
        List {
            Section {
                header(project: project, tree: tree)
                filterRow
            } footer: {
                headerFooter(tree: tree, directories: directories)
            }
            if directories.isEmpty && !filter.isEmpty {
                Section {
                    Text("No files match this filter.")
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(directories) { directory in
                Section {
                    ForEach(directory.files, id: \.path) { entry in
                        row(for: entry, in: project)
                    }
                } header: {
                    Text(directory.path.isEmpty ? project.title : directory.path)
                        .textCase(nil)  // paths keep their case
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
        }
        .listStyle(.insetGrouped)
        .contentMargins(.bottom, FileBarMetrics.expandedHeight, for: .scrollContent)
        .scrollDismissesKeyboard(.immediately)  // any swipe hides the keyboard
        .overlay {
            if directories.isEmpty && filter.isEmpty {
                ContentUnavailableView("No Files", systemImage: "folder")
                    .allowsHitTesting(false)
            }
        }
        .refreshable { await load(refresh: true) }
    }

    /// The project's name, owner · branch, and Download All.
    private func header(project: ProjectInfo, tree: ProjectTree) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "shippingbox")
                .font(.title2)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(project.title)
                    .font(.headline)
                    .lineLimit(1)
                Text([project.link.owner, project.ref].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            downloadButton
        }
    }

    /// Tap to edit; applied when you press Done or leave the field.
    private var filterRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .foregroundStyle(filter.isEmpty ? Color.secondary : Color.accentColor)
                .accessibilityHidden(true)
            TextField("Filter, like *.cs *.md", text: $filterText)
                .font(.body.monospaced())
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .focused($isEditingFilter)
                .onSubmit { applyFilter() }
                .accessibilityLabel("Filter")
                .accessibilityHint("Space-separated patterns such as *.cs. Start one with ! to leave files out.")
            if !filterText.isEmpty {
                Button("Clear Filter", systemImage: "xmark.circle.fill") {
                    filterText = ""
                    applyFilter()
                }
                .labelStyle(.iconOnly)
                .foregroundStyle(.secondary)
                .buttonStyle(.borderless)  // only the button, not the whole row
            }
        }
        .onChange(of: isEditingFilter) { _, isEditing in
            if !isEditing { applyFilter() }
        }
    }

    @ViewBuilder
    private func headerFooter(tree: ProjectTree, directories: [ProjectTree.Directory]) -> some View {
        let lines = [
            filter.isEmpty ? nil
                : "Showing \(directories.reduce(0) { $0 + $1.files.count }) of \(fileCount) files.",
            tree.truncated ? "This repository is very large, so GitHub listed only some of its files." : nil,
        ].compactMap { $0 }
        if !lines.isEmpty {
            Text(lines.joined(separator: " "))
        }
    }

    /// Saves the filter and lists again with it, if it changed.
    private func applyFilter() {
        ProjectFilterStore.standard.save(filterText, for: projectID)
        let new = FileFilter(filterText.trimmingCharacters(in: .whitespaces))
        guard new != filter else { return }
        filter = new
        guard case .loaded(let project, let tree, _) = state else { return }
        state = .loaded(project, tree, tree.directories(under: project.folder ?? "", matching: new))
        updatePending()
    }

    /// Swiping a saved file: deletes its saved copy. It stays in the list and downloads again
    /// when opened; its reading position is kept. A file that's open stays on screen.
    private func deleteDownload(_ url: URL) {
        saved.remove(url)
        updatePending()
        Task { await DocumentStore.shared.delete(url) }
    }

    @ViewBuilder
    private func row(for entry: ProjectTree.Entry, in project: ProjectInfo) -> some View {
        if let url = project.rawURL(for: entry.path) {
            let isCurrent = url == currentURL
            let isSaved = saved.contains(url)
            Button { onOpen(url) } label: {
                FileEntryRow(entry: entry, isSaved: isSaved)
            }
            .swipeActions {
                if isSaved {
                    // Not `.destructive`: the row stays, only its saved copy goes.
                    Button { deleteDownload(url) } label: {
                        Label("Delete Download", systemImage: "trash")
                    }
                    .tint(.red)
                }
            }
            // The open file looks selected, as in Files.
            .listRowBackground(isCurrent
                ? Color(uiColor: .systemGray4)
                : Color(uiColor: .secondarySystemGroupedBackground))
            .accessibilityAddTraits(isCurrent ? .isSelected : [])
        }
    }

    // MARK: Failure

    /// A repository GitHub can't find may be private: say how to get in.
    private func failureMessage(for error: any Error) -> String {
        let message = error.localizedDescription
        guard error as? ProjectError == .notFound else { return message }
        return message + (isSignedIn
            ? " If it’s private, check that gitty’s GitHub app can read it."
            : " If it’s a private repository, sign in to GitHub.")
    }

    @ViewBuilder
    private func failureActions(for error: any Error) -> some View {
        if error as? ProjectError == .notFound {
            if isSignedIn {
                Button("Choose Repositories") { openURL(GitHubAppConfig.installURL) }
                    .buttonStyle(.borderedProminent)
            } else {
                Button("Sign In to GitHub") { isSigningIn = true }
                    .buttonStyle(.borderedProminent)
            }
        }
        Button("Try Again") { Task { await load(refresh: true) } }
    }

    // MARK: Loading

    private func load(refresh: Bool) async {
        do {
            let (project, tree) = try await ProjectStore.shared.tree(for: projectID, refresh: refresh)
            saved = Set(await DocumentStore.shared.savedDocuments().map(\.url))
            if !hasLoadedFilter {  // the saved filter, once
                filterText = ProjectFilterStore.standard.text(for: projectID)
                filter = FileFilter(filterText)
                hasLoadedFilter = true
            }
            // Grouping a big repository takes a moment: do it once here, not on every redraw.
            let directories = tree.directories(under: project.folder ?? "", matching: filter)
            fileCount = tree.files(under: project.folder ?? "").count
            state = .loaded(project, tree, directories)
            updatePending()
        } catch {
            if case .loaded = state, refresh { return }  // keep the list; the pull just ends
            isSignedIn = await GitHubAuth.shared.isSignedIn
            state = .failed(error)
        }
    }

    // MARK: Download All

    @ViewBuilder
    private var downloadButton: some View {
        if let download {
            HStack(spacing: 6) {
                ProgressView()
                Text("\(download.done)/\(download.total)")
                    .monospacedDigit()
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Downloading \(download.done) of \(download.total)")
        } else if pending.urls.isEmpty {
            Image(systemName: "arrow.down.circle.fill")
                .font(.title2)
                .foregroundStyle(.secondary)
                .accessibilityLabel(filter.isEmpty ? "All files saved" : "All matching files saved")
        } else {
            Button { downloadAll(pending.urls) } label: {
                HStack(spacing: 6) {
                    Text(pending.bytes, format: .byteCount(style: .file))
                        .font(.footnote)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Image(systemName: "arrow.down.circle")
                        .font(.title2)
                }
            }
            .buttonStyle(.borderless)  // only the button, not the whole row
            .accessibilityLabel("Download All")
            .accessibilityValue(Text("\(pending.urls.count) files, ") + Text(pending.bytes, format: .byteCount(style: .file)))
        }
    }

    /// Works out what Download All would fetch: the files the filter lets through that aren't
    /// saved yet and aren't too big.
    private func updatePending() {
        guard case .loaded(let project, let tree, _) = state else {
            pending = PendingDownload()
            return
        }
        var result = PendingDownload()
        for entry in tree.files(under: project.folder ?? "", matching: filter)
        where (entry.size ?? 0) <= Self.downloadAllSizeLimit {
            guard let url = project.rawURL(for: entry.path), !saved.contains(url) else { continue }
            result.urls.append(url)
            result.bytes += Int64(entry.size ?? 0)
        }
        pending = result
    }

    /// Downloads a few files at a time. Each lands in the saved copies, like opening it would.
    private func downloadAll(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        download = DownloadProgress(done: 0, total: urls.count)
        Task {
            await withTaskGroup(of: URL?.self) { group in
                var pending = urls.makeIterator()
                func startNext() {
                    guard let url = pending.next() else { return }
                    group.addTask {
                        (try? await DocumentStore.shared.fetch(url)) == nil ? nil : url
                    }
                }
                for _ in 0..<4 { startNext() }
                while let finished = await group.next() {
                    if let finished { saved.insert(finished) }
                    download?.done += 1
                    startNext()
                }
            }
            download = nil
            updatePending()  // what failed is still to do
        }
    }
}

/// A file in a project: a code icon for files with symbols, the name, its size, and the
/// offline icon once it's saved.
private struct FileEntryRow: View {
    let entry: ProjectTree.Entry
    let isSaved: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: ProjectTree.isCode(entry) ? "chevron.left.forwardslash.chevron.right" : "doc")
                .foregroundStyle(ProjectTree.isCode(entry) ? Color.accentColor : Color.secondary)
                .frame(width: 24)
                .accessibilityHidden(true)
            Text(entry.name)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            if let size = entry.size {
                Text(Int64(size), format: .byteCount(style: .file))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if isSaved {
                Image(systemName: "arrow.down.circle.fill")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Saved on this device")
            }
        }
    }
}
