import SwiftUI
import UIKit

/// A place in a project to show: the project's own folder (`folder == nil`) or one inside it.
nonisolated struct ProjectRoute: Hashable, Sendable {
    let projectID: String
    let folder: String?
}

/// One folder of a project, like the Files app: folders, then code files, then other files. Tap a
/// folder to go in (back to go out), a file to open it in File mode. Pull to refresh the file
/// list; Download All saves this folder's files for offline reading.
struct ProjectFolderView: View {
    let route: ProjectRoute
    let onOpen: @MainActor (URL) -> Void

    @State private var state: LoadState = .loading
    /// Files with a saved copy (they open offline).
    @State private var saved: Set<URL> = []
    @State private var download: DownloadProgress?

    private enum LoadState {
        case loading
        case loaded(ProjectInfo, ProjectTree)
        case failed(String)
    }

    private struct DownloadProgress {
        var done: Int
        let total: Int
    }

    /// Files bigger than this are left out of Download All (they still open one by one).
    private static let downloadAllSizeLimit = 5_000_000

    init(route: ProjectRoute, onOpen: @escaping @MainActor (URL) -> Void) {
        self.route = route
        self.onOpen = onOpen
    }

    var body: some View {
        content
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { downloadButton }
            }
            .task { await load(refresh: false) }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        switch state {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            ContentUnavailableView {
                Label("Couldn’t Load Project", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") { Task { await load(refresh: true) } }
            }
        case .loaded(let project, let tree):
            list(project: project, tree: tree)
        }
    }

    private func list(project: ProjectInfo, tree: ProjectTree) -> some View {
        let entries = tree.children(of: folder(in: project))
        return List {
            Section {
                ForEach(entries, id: \.path) { entry in
                    row(for: entry, in: project)
                }
            } footer: {
                if tree.truncated {
                    Text("This repository is very large, so GitHub listed only some of its files.")
                }
            }
        }
        .listStyle(.insetGrouped)
        .overlay {
            if entries.isEmpty {
                ContentUnavailableView("Empty Folder", systemImage: "folder")
            }
        }
        .refreshable { await load(refresh: true) }
    }

    @ViewBuilder
    private func row(for entry: ProjectTree.Entry, in project: ProjectInfo) -> some View {
        if entry.kind == .folder {
            NavigationLink(value: ProjectRoute(projectID: project.id, folder: entry.path)) {
                Label(entry.name, systemImage: "folder")
            }
        } else if let url = project.rawURL(for: entry.path) {
            Button { onOpen(url) } label: {
                FileEntryRow(entry: entry, isSaved: saved.contains(url))
            }
        }
    }

    private var title: String {
        guard case .loaded(let project, _) = state else { return "" }
        let folder = folder(in: project)
        if folder == (project.folder ?? "") { return project.title }
        return folder.split(separator: "/").last.map(String.init) ?? project.title
    }

    private func folder(in project: ProjectInfo) -> String {
        route.folder ?? project.folder ?? ""
    }

    // MARK: Loading

    private func load(refresh: Bool) async {
        do {
            let (project, tree) = try await ProjectStore.shared.tree(for: route.projectID, refresh: refresh)
            saved = Set(await DocumentStore.shared.savedDocuments().map(\.url))
            state = .loaded(project, tree)
        } catch {
            if case .loaded = state, refresh { return }  // keep the list; the pull just ends
            state = .failed(error.localizedDescription)
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
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Downloading \(download.done) of \(download.total)")
        } else if case .loaded(let project, let tree) = state {
            let missing = missingFiles(project: project, tree: tree)
            Button("Download All", systemImage: "arrow.down.circle") {
                downloadAll(missing)
            }
            .disabled(missing.isEmpty)
        }
    }

    /// This folder's files (at any depth) that aren't saved yet.
    private func missingFiles(project: ProjectInfo, tree: ProjectTree) -> [URL] {
        tree.files(under: folder(in: project))
            .filter { ($0.size ?? 0) <= Self.downloadAllSizeLimit }
            .compactMap { project.rawURL(for: $0.path) }
            .filter { !saved.contains($0) }
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
        }
    }
}

/// A file in a project folder: a code icon for files with symbols, the name, its size, and the
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
