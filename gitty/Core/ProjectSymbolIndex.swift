import Foundation

/// The symbols of a project's downloaded files, for Symbols mode and symbol search across the
/// project. Files are indexed off the main thread the first time they're needed, and again only
/// when their saved copy changes (each result is kept in memory while the app runs).
actor ProjectSymbolIndex {
    static let shared = ProjectSymbolIndex()

    /// One file's symbols, ids in file order.
    nonisolated struct FileSymbols: Sendable {
        let url: URL
        let symbols: [CodeSymbol]
    }

    private struct Entry {
        let fetchedAt: Date
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

    /// The project a file belongs to, if any: the one with the most specific folder.
    static func project(containing url: URL, in projects: [ProjectInfo]) -> ProjectInfo? {
        let address = url.absoluteString
        return projects
            .compactMap { project in prefix(of: project).map { (project, $0) } }
            .filter { address.hasPrefix($0.1) }
            .max { $0.1.count < $1.1.count }?
            .0
    }

    /// The symbols of every downloaded file in `project` except `excluded`, files in path order.
    /// Files in languages without symbols are skipped. Stops early when the task is cancelled.
    func symbols(in project: ProjectInfo, excluding excluded: URL) async -> [FileSymbols] {
        guard let prefix = Self.prefix(of: project) else { return [] }
        let files = await store.savedDocuments()
            .filter { metadata in
                metadata.url != excluded
                    && metadata.url.absoluteString.hasPrefix(prefix)
                    && SymbolLanguage.extensionHasSymbols(metadata.url.pathExtension)
            }
            .sorted { $0.url.absoluteString.localizedStandardCompare($1.url.absoluteString) == .orderedAscending }

        var result: [FileSymbols] = []
        for metadata in files {
            guard !Task.isCancelled else { break }
            if let entry = cache[metadata.url], entry.fetchedAt == metadata.fetchedAt {
                if !entry.symbols.isEmpty { result.append(FileSymbols(url: metadata.url, symbols: entry.symbols)) }
                continue
            }
            guard let document = await store.cached(metadata.url) else { continue }
            let text = RawTextDecoder.decode(document.data, contentType: document.metadata.contentType)
            guard case .symbols(let symbols) = SymbolIndexer.index(text, fileExtension: metadata.url.pathExtension)
            else { continue }
            cache[metadata.url] = Entry(fetchedAt: metadata.fetchedAt, symbols: symbols)
            if !symbols.isEmpty { result.append(FileSymbols(url: metadata.url, symbols: symbols)) }
        }
        return result
    }
}
