import SwiftUI
import UIKit

/// Project mode, and the start page: the project chosen in the sidebar, or, for Files, every
/// file you've opened or saved that isn't part of a project.
///
/// Equatable, so the screen around it can redraw (while Symbols scrolls, say) without its list
/// of every file in the project redrawing too: use `.equatable()`.
struct ProjectView: View, Equatable {
    /// The open project's id, or "" for Files.
    let projectID: String
    /// The file on screen, marked in the list.
    let currentURL: URL?
    /// False while another mode covers it: it stays alive (and keeps its place) without
    /// loading anything, and catches up on saved files when it shows again.
    let isActive: Bool
    /// The project's order (the sort button beside the mode selector). Files has its own.
    let sorting: ListSorting
    /// The album shown (marked among the project's albums).
    let currentAlbumID: UUID?
    let onOpenAlbum: @MainActor (UUID) -> Void
    let onOpen: @MainActor (URL) -> Void

    // An explicit init (not the memberwise one) so passing in an existing `@MainActor` closure
    // doesn't warn about converting it to `@Sendable`.
    init(projectID: String, currentURL: URL? = nil, isActive: Bool = true,
         sorting: ListSorting = ListSorting(), currentAlbumID: UUID? = nil,
         onOpenAlbum: @escaping @MainActor (UUID) -> Void = { _ in },
         onOpen: @escaping @MainActor (URL) -> Void) {
        self.projectID = projectID
        self.currentURL = currentURL
        self.isActive = isActive
        self.sorting = sorting
        self.currentAlbumID = currentAlbumID
        self.onOpenAlbum = onOpenAlbum
        self.onOpen = onOpen
    }

    /// `onOpen` and `onOpenAlbum` aren't compared: what they do never changes.
    nonisolated static func == (lhs: ProjectView, rhs: ProjectView) -> Bool {
        lhs.projectID == rhs.projectID && lhs.currentURL == rhs.currentURL
            && lhs.isActive == rhs.isActive && lhs.sorting == rhs.sorting
            && lhs.currentAlbumID == rhs.currentAlbumID
    }

    var body: some View {
        if projectID.isEmpty {
            LooseFilesView(currentURL: currentURL, isActive: isActive, onOpen: onOpen)
        } else {
            ProjectFilesView(projectID: projectID, currentURL: currentURL, isActive: isActive,
                             sorting: sorting, currentAlbumID: currentAlbumID, onOpenAlbum: onOpenAlbum,
                             onOpen: onOpen)
                .id(projectID)  // another project starts fresh
        }
    }
}

/// Files: what you've opened or saved that doesn't belong to a project (opened by URL or shared
/// from Safari). Recent files first, then other saved files, newest download first. Tap one to
/// open it, swipe one to delete it and its saved copy.
private struct LooseFilesView: View {
    let currentURL: URL?
    let isActive: Bool
    let onOpen: @MainActor (URL) -> Void

    @State private var projectPrefixes: [String] = []
    @State private var recents: [URL] = []
    @State private var saved: [URL] = []

    init(currentURL: URL?, isActive: Bool, onOpen: @escaping @MainActor (URL) -> Void) {
        self.currentURL = currentURL
        self.isActive = isActive
        self.onOpen = onOpen
    }

    private var files: [FileEntry] {
        let savedSet = Set(saved)
        var seen = Set<URL>()
        return (recents + saved)
            .filter { url in !projectPrefixes.contains { url.absoluteString.hasPrefix($0) } }
            .filter { seen.insert($0).inserted }
            .map { FileEntry(url: $0, isSaved: savedSet.contains($0)) }
    }

    var body: some View {
        let files = files
        List {
            if !files.isEmpty {
                Section("Files") {
                    ForEach(files) { file in
                        let isCurrent = file.url == currentURL
                        FileRow(file: file)
                            .contentShape(Rectangle())
                            .onTapGesture { onOpen(file.url) }
                            // The open file looks selected: a gray highlight, like a row that stays
                            // selected in a list. Text keeps its normal colors.
                            .listRowBackground(isCurrent
                                ? Color(uiColor: .systemGray4)
                                : Color(uiColor: .secondarySystemGroupedBackground))
                            .accessibilityAddTraits(isCurrent ? [.isButton, .isSelected] : .isButton)
                            .swipeActions {
                                Button(role: .destructive) { delete(file.url) } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .contentMargins(.bottom, FileBarMetrics.expandedHeight, for: .scrollContent)
        .scrollDismissesKeyboard(.immediately)  // any swipe hides the keyboard
        .scrollDisabled(!isActive)  // hidden: leaves status-bar taps to the mode on screen
        .overlay {
            if files.isEmpty {
                ContentUnavailableView(
                    "No Files",
                    systemImage: "doc.on.doc",
                    description: Text("Files you open by URL appear here. Projects are in the sidebar: swipe left from the right edge.")
                )
            }
        }
        .task(id: isActive) {  // each time it shows
            if isActive { await reload() }
        }
    }

    private func reload() async {
        recents = RecentFilesStore.standard.urls()
        projectPrefixes = await ProjectStore.shared.projects().compactMap { $0.rawURL(for: "")?.absoluteString }
        saved = await DocumentStore.shared.savedDocuments().map(\.url)
    }

    /// Removes the file from the list and deletes its saved copy and reading position.
    /// A file that's open stays on screen; opening it again downloads it.
    private func delete(_ url: URL) {
        RecentFilesStore.standard.remove(url)
        ReadingPositionStore.standard.remove(for: url)
        recents.removeAll { $0 == url }
        saved.removeAll { $0 == url }
        Task { await DocumentStore.shared.delete(url) }
    }
}

private struct FileEntry: Identifiable {
    let url: URL
    /// Has a saved copy, so it opens offline.
    let isSaved: Bool
    var id: URL { url }
}

/// Name and location, and an icon on files that open offline.
private struct FileRow: View {
    let file: FileEntry

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(file.url.displayFileName)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(file.url.displayLocation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
            if file.isSaved {
                Image(systemName: "arrow.down.circle.fill")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Saved on this device")
            }
        }
    }
}
