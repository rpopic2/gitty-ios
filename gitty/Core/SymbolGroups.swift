import Foundation
import Observation

/// Search by file name: for the Code level's search, matching files come with all their
/// symbols.
nonisolated enum FileNameSearch {
    /// The files whose name matches (fuzzy, like symbol search), the best match first (equal
    /// ones in list order), each with its entry and all its symbols. `symbols` is the whole
    /// list, where each file's entry and symbols come together.
    /// - Parameter maxRank: only matches at least this close (`SymbolSearch.rank`: 5 and under
    ///   is the name containing the query); `nil` for any.
    static func symbols(inFilesNamed query: String, in symbols: [CodeSymbol], maxRank: Int? = nil) -> [CodeSymbol] {
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
            if let rank = SymbolSearch.rank(search, SymbolSearch.Index.Entry(name)), rank <= (maxRank ?? .max) {
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

/// What's collapsed at the Code level, saved in `UserDefaults`:
/// - symbols, whose code is hidden under their titles (tap a title). **Collapse All** makes a
///   list's symbols collapsed by default (its scope, below), so only the ones tapped since are
///   kept: each symbol is kept only while it differs from its list's default, by file, kind and
///   name (so it stays as it is when its file changes);
/// - files, whose symbols are all hidden under the file's title.
///
/// A scope is where a list's files are: a project's raw address prefix, or the open file's
/// address for a file outside projects. Loaded once; each title and block only checks the
/// sets, and a change writes them once.
@MainActor @Observable
final class CollapsedCodeStore {
    static let shared = CollapsedCodeStore(defaults: .standard)

    /// Symbols that differ from their scope's default.
    private(set) var flipped: Set<String>
    /// Files folded to their title.
    private(set) var files: Set<String>
    /// Scopes whose symbols are collapsed by default (Collapse All).
    private(set) var collapsedScopes: Set<String>
    @ObservationIgnored private let defaults: UserDefaults

    private enum Key {
        static let flipped = "collapsedCode.symbols"
        static let files = "collapsedCode.files"
        static let scopes = "collapsedCode.scopes"
        /// Before Collapse All: symbols and `file#` keys together.
        static let old = "collapsedCode"
    }

    init(defaults: UserDefaults) {
        self.defaults = defaults
        var flipped = Set(defaults.stringArray(forKey: Key.flipped) ?? [])
        var files = Set(defaults.stringArray(forKey: Key.files) ?? [])
        if let old = defaults.stringArray(forKey: Key.old) {
            for key in old {
                if key.hasPrefix("file#") { files.insert(key) } else { flipped.insert(key) }
            }
            defaults.removeObject(forKey: Key.old)
        }
        self.flipped = flipped
        self.files = files
        collapsedScopes = Set(defaults.stringArray(forKey: Key.scopes) ?? [])
    }

    /// - Parameter openFile: the file that symbols without a `fileURL` are in.
    nonisolated static func key(for symbol: CodeSymbol, openFile: URL) -> String {
        (symbol.fileURL ?? openFile).absoluteString + "#" + symbol.kind.rawValue + "#" + symbol.name
    }

    nonisolated static func key(forFile file: URL) -> String {
        "file#" + file.absoluteString
    }

    func isCollapsed(_ symbol: CodeSymbol, openFile: URL, scope: String) -> Bool {
        collapsedScopes.contains(scope) != flipped.contains(Self.key(for: symbol, openFile: openFile))
    }

    func isFileCollapsed(_ file: URL) -> Bool {
        files.contains(Self.key(forFile: file))
    }

    /// Not shown at all: in a collapsed file (a file's own title always shows).
    func isHidden(_ symbol: CodeSymbol, openFile: URL) -> Bool {
        symbol.kind != .file && isFileCollapsed(symbol.fileURL ?? openFile)
    }

    /// A file's title folds the file; a symbol's, its code.
    func toggle(_ symbol: CodeSymbol, openFile: URL, scope: String) {
        if symbol.kind == .file {
            let key = Self.key(forFile: symbol.fileURL ?? openFile)
            if files.contains(key) { files.remove(key) } else { files.insert(key) }
        } else {
            let key = Self.key(for: symbol, openFile: openFile)
            if flipped.contains(key) { flipped.remove(key) } else { flipped.insert(key) }
        }
        save()
    }

    /// Collapses or expands these symbols (a file's, from its title's menu), unfolding their
    /// file.
    func setCollapsed(_ isCollapsed: Bool, _ symbols: [CodeSymbol], openFile: URL, scope: String) {
        let byDefault = collapsedScopes.contains(scope)
        for symbol in symbols where symbol.kind != .file {
            let key = Self.key(for: symbol, openFile: openFile)
            if isCollapsed == byDefault { flipped.remove(key) } else { flipped.insert(key) }
            files.remove(Self.key(forFile: symbol.fileURL ?? openFile))
        }
        save()
    }

    /// Collapse All (or Expand All) in a scope: every symbol's code, and no file folded.
    func setAllCollapsed(_ isCollapsed: Bool, scope: String) {
        if isCollapsed { collapsedScopes.insert(scope) } else { collapsedScopes.remove(scope) }
        flipped = flipped.filter { !$0.hasPrefix(scope) }
        files = files.filter { !$0.hasPrefix("file#" + scope) }
        save()
    }

    /// Shows a symbol and its code.
    func reveal(_ symbol: CodeSymbol, openFile: URL, scope: String) {
        let fileKey = Self.key(forFile: symbol.fileURL ?? openFile)
        guard isCollapsed(symbol, openFile: openFile, scope: scope) || files.contains(fileKey) else { return }
        files.remove(fileKey)
        let key = Self.key(for: symbol, openFile: openFile)
        if collapsedScopes.contains(scope) { flipped.insert(key) } else { flipped.remove(key) }
        save()
    }

    private func save() {
        defaults.set(flipped.sorted(), forKey: Key.flipped)
        defaults.set(files.sorted(), forKey: Key.files)
        defaults.set(collapsedScopes.sorted(), forKey: Key.scopes)
    }
}
