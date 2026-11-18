import Foundation

/// The symbols of a project's downloaded files, for Symbols mode and symbol search across the
/// project. Files are indexed off the main thread the first time they're needed, and again only
/// when their saved copy changes (each result is kept in memory while the app runs).
actor ProjectSymbolIndex {
    static let shared = ProjectSymbolIndex()

    /// One file's entry (see `SymbolIndexer.fileEntry`) and its symbols, ids in file order.
    nonisolated struct FileSymbols: Sendable {
        let url: URL
        let file: CodeSymbol
        let symbols: [CodeSymbol]
    }

    private struct Entry {
        let fetchedAt: Date
        let file: CodeSymbol
        let symbols: [CodeSymbol]
    }

    private let store: DocumentStore
    private var cache: [URL: Entry] = [:]

    init(store: DocumentStore = .shared) {
        self.store = store
    }

    /// Where a project's files start: its raw URL for the project's folder.
    static func prefix(of project: ProjectInfo) -> String? {
        let folder = project.folder ?? ""
        return project.rawURL(for: folder.isEmpty ? "" : folder + "/")?.absoluteString
    }

    /// Text, not an image or another binary file: no NUL bytes in its first few kilobytes, the
    /// way `grep` and Git tell.
    nonisolated static func isText(_ data: Data) -> Bool {
        !data.prefix(8_000).contains(0)
    }

    /// The project a file belongs to, if any: the one with the most specific folder.
    static func project(containing url: URL, in projects: [ProjectInfo]) -> ProjectInfo? {
        let address = url.absoluteString
        return projects
            .compactMap { project in prefix(of: project).map { (project, $0) } }
            .filter { address.hasPrefix($0.1) }
            .max { $0.1.count < $1.1.count }?
            .0
    }

    /// Every downloaded text file in `project` except `excluded`, in path order, with its symbols
    /// (none for a README or a language without symbols), only files the project's filter lets
    /// through. Binary files (images…) are left out. Stops early when the task is cancelled.
    func symbols(in project: ProjectInfo, excluding excluded: URL,
                 matching filter: FileFilter = .none) async -> [FileSymbols] {
        guard let prefix = Self.prefix(of: project) else { return [] }
        let files = await store.savedDocuments()
            .filter { metadata in
                let address = metadata.url.absoluteString
                guard metadata.url != excluded, address.hasPrefix(prefix) else { return false }
                guard !filter.isEmpty else { return true }
                let relative = String(address.dropFirst(prefix.count))
                return filter.matches(relative.removingPercentEncoding ?? relative)
            }
            .sorted { $0.url.absoluteString.localizedStandardCompare($1.url.absoluteString) == .orderedAscending }

        var result: [FileSymbols] = []
        for metadata in files {
            guard !Task.isCancelled else { break }
            if let entry = cache[metadata.url], entry.fetchedAt == metadata.fetchedAt {
                result.append(FileSymbols(url: metadata.url, file: entry.file, symbols: entry.symbols))
                continue
            }
            guard let document = await store.cached(metadata.url),
                  Self.isText(document.data)
            else { continue }
            let text = RawTextDecoder.decode(document.data, contentType: document.metadata.contentType)
            var symbols: [CodeSymbol] = []
            if case .symbols(let found) = SymbolIndexer.index(text, fileExtension: metadata.url.pathExtension) {
                symbols = found
            }
            // Listed even without symbols: the file itself is an entry.
            let file = SymbolIndexer.fileEntry(named: metadata.url.lastPathComponent, text: text)
            cache[metadata.url] = Entry(fetchedAt: metadata.fetchedAt, file: file, symbols: symbols)
            result.append(FileSymbols(url: metadata.url, file: file, symbols: symbols))
        }
        return result
    }
}
