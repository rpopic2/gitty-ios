import SwiftUI
import UIKit

/// Project mode, and the start page: every file you've opened or saved. Recent files come first,
/// then every other saved file, newest download first. Tap one to open it; swipe to delete it from
/// the list and the device.
struct ProjectView: View {
    /// The file on screen, marked in the list.
    let currentURL: URL?
    let onOpen: @MainActor (URL) -> Void

    @State private var recents: [URL] = []
    @State private var saved: [URL] = []

    // An explicit init (not the memberwise one) so passing in an existing `@MainActor` closure
    // doesn't warn about converting it to `@Sendable`.
    init(currentURL: URL? = nil, onOpen: @escaping @MainActor (URL) -> Void) {
        self.currentURL = currentURL
        self.onOpen = onOpen
    }

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
                        let isCurrent = file.url == currentURL
                        FileRow(file: file, isCurrent: isCurrent)
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

/// Name and location, and an icon on files that open offline. The open file's row is drawn
/// selected by the list (a gray row background).
private struct FileRow: View {
    let file: FileEntry
    let isCurrent: Bool

    private var primary: Color { .primary }
    private var secondary: Color { .secondary }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(file.url.displayFileName)
                    .foregroundStyle(primary)
                    .lineLimit(1)
                Text(file.url.displayLocation)
                    .font(.caption)
                    .foregroundStyle(secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
            if file.isSaved {
                Image(systemName: "arrow.down.circle.fill")
                    .foregroundStyle(secondary)
                    .accessibilityLabel("Saved on this device")
            }
        }
    }
}
