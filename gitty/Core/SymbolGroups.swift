import Foundation

/// One file's symbols, for Symbols mode zoomed out (grouped by file).
nonisolated struct SymbolFileGroup: Identifiable, Sendable {
    let file: URL
    let symbols: [CodeSymbol]

    var id: URL { file }

    /// Groups symbols by file. Files come in the order of their first symbol in the list: the
    /// open file first, then the project's in path order, or, for search results (best first),
    /// the file with the best match first. Each file's symbols keep their order in the list.
    /// Files' own entries aren't rows: the header stands for the file (a search that only
    /// matches a file's name still lists the file, with no rows).
    /// - Parameter openFile: the file that symbols without a `fileURL` are in.
    static func groups(of symbols: [CodeSymbol], openFile: URL) -> [SymbolFileGroup] {
        var order: [URL] = []
        var byFile: [URL: [CodeSymbol]] = [:]
        for symbol in symbols {
            let file = symbol.fileURL ?? openFile
            if byFile[file] == nil { order.append(file) }
            byFile[file, default: []].append(contentsOf: symbol.kind == .file ? [] : [symbol])
        }
        return order.map { SymbolFileGroup(file: $0, symbols: byFile[$0] ?? []) }
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
