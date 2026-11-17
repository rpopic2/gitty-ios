import SwiftUI
import UIKit

/// Project mode, and the start page: every file you've opened or saved. Recent files come first,
/// then every other saved file, newest download first. Tap one to open it; swipe to delete it from
/// the list and the device.
struct ProjectView: View {
    /// The file on screen, marked in the list.
    var currentURL: URL?
    let onOpen: @MainActor (URL) -> Void

    @State private var recents: [URL] = []
    @State private var saved: [URL] = []

    private var files: [FileEntry] {
        let savedSet = Set(saved)
        var seen = Set<URL>()
        return (recents + saved)
            .filter { seen.insert($0).inserted }
            .map { FileEntry(url: $0, isSaved: savedSet.contains($0)) }
    }

    var body: some View {
        List {
            if !files.isEmpty {
                Section("Files") {
                    ForEach(files) { file in
                        FileRow(file: file, isCurrent: file.url == currentURL)
                            .contentShape(Rectangle())
                            .onTapGesture { onOpen(file.url) }
                            .accessibilityAddTraits(.isButton)
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
        .scrollDismissesKeyboard(.interactively)
        .task { await reload() }  // every time the list appears
    }

    private func reload() async {
        recents = RecentFilesStore.standard.urls()
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

/// Name and location, a mark on the open file, and an icon on files that open offline.
private struct FileRow: View {
    let file: FileEntry
    let isCurrent: Bool

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(file.url.displayFileName)
                    .fontWeight(isCurrent ? .semibold : .regular)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(file.url.displayLocation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
            if isCurrent {
                Image(systemName: "eye")
                    .foregroundStyle(.tint)
                    .accessibilityLabel("Open now")
            }
            if file.isSaved {
                Image(systemName: "arrow.down.circle.fill")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Saved on this device")
            }
        }
    }
}
