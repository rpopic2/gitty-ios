import Foundation

/// One file's symbols, for Symbols mode zoomed out (grouped by file).
nonisolated struct SymbolFileGroup: Identifiable, Sendable {
    let file: URL
    let symbols: [CodeSymbol]
    /// The file's own entry in the list, when it's there (always, without a search).
    var entryID: Int? = nil

    var id: URL { file }

    /// The id that stands for the whole file in the Files level (a scroll target): its entry's,
    /// else its first symbol's.
    var anchorID: Int? { entryID ?? symbols.first?.id }

    /// Groups symbols by file. Files come in the order of their first symbol in the list: the
    /// open file first, then the project's in path order, or, for search results (best first),
    /// the file with the best match first. Each file's symbols keep their order in the list.
    /// Files' own entries aren't rows: the header stands for the file (a search that only
    /// matches a file's name still lists the file, with no rows).
    /// - Parameter openFile: the file that symbols without a `fileURL` are in.
    static func groups(of symbols: [CodeSymbol], openFile: URL) -> [SymbolFileGroup] {
        var order: [URL] = []
        var byFile: [URL: [CodeSymbol]] = [:]
        var entries: [URL: Int] = [:]
        for symbol in symbols {
            let file = symbol.fileURL ?? openFile
            if byFile[file] == nil { order.append(file) }
            if symbol.kind == .file {
                entries[file] = symbol.id
                byFile[file, default: []].append(contentsOf: [])
            } else {
                byFile[file, default: []].append(symbol)
            }
        }
        return order.map { SymbolFileGroup(file: $0, symbols: byFile[$0] ?? [], entryID: entries[$0]) }
    }
}

extension SymbolFileGroup {
    /// The Files level's search: the files whose name matches (fuzzy, like symbol search), the
    /// best match first (equal ones in list order), each with its entry and all its symbols.
    /// `symbols` is the whole list, where each file's entry and symbols come together.
    static func symbols(inFilesNamed query: String, in symbols: [CodeSymbol]) -> [CodeSymbol] {
        let search = SymbolSearch.Query(query)
        guard !search.text.isEmpty else { return symbols }
        // Each file's run of the list, from its entry.
        var matches: [(range: Range<Int>, rank: Int)] = []
        var start = 0
        while start < symbols.count {
            var end = start + 1
            while end < symbols.count, symbols[end].kind != .file, symbols[end].fileURL == symbols[start].fileURL {
                end += 1
            }
            let entry = symbols[start]
            let name = entry.kind == .file ? entry.name : (entry.fileURL?.lastPathComponent ?? entry.name)
            if let rank = SymbolSearch.rank(search, SymbolSearch.Index.Entry(name)) {
                matches.append((start..<end, rank))
            }
            start = end
        }
        // `sorted` isn't stable: break ties by place.
        return matches
            .sorted { $0.rank != $1.rank ? $0.rank < $1.rank : $0.range.lowerBound < $1.range.lowerBound }
            .flatMap { symbols[$0.range] }
    }
}

/// The files folded away in Symbols' grouped view, saved in `UserDefaults`. Files are kept by
/// URL, so each project (and each file opened by URL) keeps its own.
nonisolated struct SymbolFoldStore: @unchecked Sendable {
    static let standard = SymbolFoldStore(defaults: .standard)

    private let defaults: UserDefaults
    private let key = "foldedSymbolFiles"

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    func foldedFiles() -> Set<URL> {
        Set((defaults.stringArray(forKey: key) ?? []).compactMap(URL.init(string:)))
    }

    func setFolded(_ isFolded: Bool, _ file: URL) {
        var files = Set(defaults.stringArray(forKey: key) ?? [])
        if isFolded { files.insert(file.absoluteString) } else { files.remove(file.absoluteString) }
        defaults.set(files.sorted(), forKey: key)
    }
}
