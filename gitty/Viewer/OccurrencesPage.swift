import SwiftUI

/// A file to look through for occurrences: its URL, its `fileURL` in the list (`nil` for the
/// open file), its entry and its symbols (for the symbol each occurrence is in).
nonisolated struct OccurrenceFile: Sendable {
    let url: URL
    let fileURL: URL?
    let entry: CodeSymbol
    let symbols: [CodeSymbol]
}

/// Occurrences (a card's text menu): where a word is used in the project's downloaded files
/// that pass its filter, as a whole word with its exact case. Each occurrence is its line (and
/// the two after it) under its file; tap one for its card at that line, paging through the
/// others. Files that aren't downloaded are left out (`skippedFiles`).
@MainActor @Observable
final class OccurrenceSearch {
    let id = UUID()
    /// What it looks for (and, with Same Kind, the identifier's kind).
    let query: OccurrenceTerm
    var term: String { query.text }
    /// What its page zooms out of: the card it was found from.
    let source: AnyHashable
    /// The list: each file with occurrences (its entry), then its occurrences' lines.
    private(set) var entries: [CodeSymbol] = []
    /// Up with each new batch: a fresh list for each (see `StackSearch.version`).
    private(set) var version = 0
    private(set) var count = 0
    private(set) var isSearching = true
    let skippedFiles: Int
    @ObservationIgnored let collapsed = CollapsedCodeStore.temporary()

    /// What an occurrence's line (by its id in `entries`) opens: its page among `pages` (the
    /// symbol it's in, or the lines around it), and its line there (0-based).
    struct Place {
        let page: Int
        let line: Int
    }
    @ObservationIgnored private(set) var places: [Int: Place] = [:]
    /// The cards' pages, one per occurrence, in order, with each one's line.
    @ObservationIgnored private(set) var pages: [CodeSymbol] = []
    @ObservationIgnored private(set) var pageLines: [Int: Int] = [:]

    @ObservationIgnored private var task: Task<Void, Never>?
    /// Ids: the list's from here, the pages' from `pageIDs` (neither is a place in the full list).
    @ObservationIgnored private var nextEntryID = 10_000_000
    @ObservationIgnored private var nextPageID = 20_000_000

    init(query: OccurrenceTerm, source: AnyHashable, files: [OccurrenceFile], skippedFiles: Int) {
        self.query = query
        self.source = source
        self.skippedFiles = skippedFiles
        task = Task { [weak self] in await self?.search(files) }
    }

    /// Its page is gone: stop looking.
    func cancel() {
        task?.cancel()
    }

    /// Files a few at a time, side by side (parsing them, with Same Kind, is the slow part),
    /// their occurrences kept in file order.
    private func search(_ files: [OccurrenceFile]) async {
        var lastPublish = ContinuousClock.now
        var pending: [(OccurrenceFile, [Found])] = []
        let query = query
        let width = max(2, ProcessInfo.processInfo.activeProcessorCount)
        var start = 0
        while start < files.count {
            guard !Task.isCancelled else { return }
            let chunk = Array(files[start..<min(start + width, files.count)])
            start += chunk.count
            let found = await withTaskGroup(of: (Int, [Found]).self) { group in
                for (index, file) in chunk.enumerated() {
                    group.addTask(priority: .userInitiated) {
                        guard let text = await FileTextCache.shared.text(of: file.url) else { return (index, []) }
                        return (index, Self.find(query, in: text, file: file))
                    }
                }
                var found = [[Found]](repeating: [], count: chunk.count)
                for await (index, result) in group { found[index] = result }
                return found
            }
            for (file, result) in zip(chunk, found) where !result.isEmpty { pending.append((file, result)) }
            // A batch at a time, so the list isn't rebuilt for every file.
            if ContinuousClock.now - lastPublish > .milliseconds(250) {
                publish(pending)
                pending = []
                lastPublish = .now
            }
        }
        publish(pending)
        isSearching = false
    }

    private func publish(_ batch: [(OccurrenceFile, [Found])]) {
        guard !batch.isEmpty else { return }
        var entries = entries
        for (file, found) in batch {
            entries.append(file.entry.moved(to: takeEntryID(), file: file.fileURL))
            for occurrence in found {
                let pageID = takePageID()
                pages.append(occurrence.page.moved(to: pageID, file: file.fileURL))
                pageLines[pageID] = occurrence.lineInPage
                let entryID = takeEntryID()
                entries.append(occurrence.line.moved(to: entryID, file: file.fileURL))
                places[entryID] = Place(page: pageID, line: occurrence.lineInPage)
                count += 1
            }
        }
        self.entries = entries
        version += 1
    }

    private func takeEntryID() -> Int {
        defer { nextEntryID += 1 }
        return nextEntryID
    }

    private func takePageID() -> Int {
        defer { nextPageID += 1 }
        return nextPageID
    }

    /// One occurrence: its line (and the two after it), the page it opens (the innermost
    /// symbol it's in, or the lines around it), and its line on that page.
    nonisolated struct Found: Sendable {
        let line: CodeSymbol
        let page: CodeSymbol
        let lineInPage: Int
    }

    nonisolated static func find(_ query: OccurrenceTerm, in string: String, file: OccurrenceFile) -> [Found] {
        let ranges = Occurrences.ranges(of: query, in: string, fileExtension: file.url.pathExtension)
        guard !ranges.isEmpty else { return [] }
        let text = string as NSString
        let starts = AlbumContents.lineStarts(of: text)
        let symbols = file.symbols.filter { $0.kind != .file }
        var found: [Found] = []
        var lastLine = -1
        for range in ranges {
            let line = Occurrences.line(of: range.location, lineStarts: starts)  // 0-based
            guard line != lastLine else { continue }  // one entry per line
            lastLine = line
            guard let entry = AlbumContents.entry(for: AlbumLines(file: file.url, start: line + 1, end: line + 3),
                                                  in: text, lineStarts: starts, id: 0, fileURL: file.fileURL)
            else { continue }
            let inside = symbols
                .filter { NSLocationInRange(range.location, $0.range) && NSMaxRange($0.range) <= text.length }
                .min { $0.range.length < $1.range.length }
            let page = inside ?? AlbumContents.entry(
                for: AlbumLines(file: file.url, start: max(1, line + 1 - 10), end: line + 1 + 10),
                in: text, lineStarts: starts, id: 0, fileURL: file.fileURL) ?? entry
            let pageStart = Occurrences.line(of: page.range.location, lineStarts: starts)
            found.append(Found(line: entry, page: page, lineInPage: line - pageStart))
        }
        return found
    }
}

/// Occurrences' page in the stack: the lines, as code blocks like the Code level's, with what
/// was looked for in a capsule at the bottom. Swipe down to go back to the card.
struct OccurrencesPage<Results: View>: View {
    let search: OccurrenceSearch
    let stackDepth: Int
    let stackActions: StackActions?
    @ViewBuilder let list: (_ entries: [CodeSymbol]) -> Results

    var body: some View {
        ZStack(alignment: .bottom) {
            content
            capsule.padding(.bottom, 8)
        }
        .toolbar(.hidden, for: .navigationBar)
    }

    @ViewBuilder
    private var content: some View {
        if search.entries.isEmpty && search.isSearching {
            placeholder { ProgressView() }
        } else if search.entries.isEmpty {
            placeholder {
                ContentUnavailableView {
                    Label("No Occurrences", systemImage: "text.magnifyingglass")
                } description: {
                    Text(skippedNote ?? String(localized: "“\(search.term)” isn’t used anywhere else."))
                }
            }
        } else {
            list(search.entries)
                .id(search.version)
        }
    }

    /// Files left out because they aren't on the device.
    private var skippedNote: String? {
        search.skippedFiles == 0 ? nil
            : String(localized: "\(search.skippedFiles) files that aren’t downloaded weren’t searched.")
    }

    private var capsule: some View {
        VStack(spacing: 6) {
            if let skippedNote, !search.entries.isEmpty {
                Text(skippedNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            let label = HStack(spacing: 6) {
                if stackDepth > 1 {
                    StackDepthLabel(depth: stackDepth, actions: stackActions)
                }
                Image(systemName: "text.magnifyingglass")
                    .foregroundStyle(.tint)
                Text(search.term)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if search.isSearching {
                    ProgressView().controlSize(.small)
                } else {
                    Text(verbatim: "· \(search.count)")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            .font(.subheadline)
            .padding(.horizontal, 16)
            .frame(height: 36)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text("Occurrences of \(search.term): \(search.count)"))
            Group {
                if #available(iOS 26.0, *) {
                    label.glassEffect(.regular, in: Capsule())
                } else {
                    label.background(.bar, in: Capsule())
                }
            }
            .padding(.horizontal, 24)
        }
    }

    private func placeholder<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(uiColor: .systemGroupedBackground))
    }
}
