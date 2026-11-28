import Foundation
import Observation

/// Search by file name: for the Code level's search, matching files come with all their
/// symbols.
/// A search for a place in a file, as compilers and stack traces print it: `SomeFile.c:980`,
/// `src/net/SomeFile.c:980`, `SomeFile.c:980:12` (the column is left out), or `:980` for the
/// open file. Its results are the files it names; tapping one's title opens it at the line.
nonisolated struct FileLineQuery: Equatable, Sendable {
    /// The file's name or the end of its path, as typed; empty for the open file.
    let file: String
    /// 1-based.
    let line: Int

    init(file: String, line: Int) {
        self.file = file
        self.line = line
    }

    init?(_ text: String) {
        var parts = text.trimmingCharacters(in: .whitespaces).split(separator: ":", omittingEmptySubsequences: false)
        // A column after the line: left out.
        if parts.count >= 3, let last = parts.last, !last.isEmpty, last.allSatisfy(\.isASCII), Int(last) != nil {
            parts.removeLast()
        }
        guard parts.count >= 2, let last = parts.last, last.allSatisfy(\.isASCII), let line = Int(last), line > 0
        else { return nil }
        let file = parts.dropLast().joined(separator: ":")
        guard !file.contains(where: \.isWhitespace) else { return nil }
        self.file = file
        self.line = line
    }

    /// The files it names, each with its entry and symbols (the open file alone for `:980`).
    /// A path's end must match the file's path; a name alone matches as file search does.
    func files(in symbols: [CodeSymbol], openFile: URL) -> [CodeSymbol] {
        guard !file.isEmpty else { return symbols.filter { ($0.fileURL ?? openFile) == openFile } }
        let name = String(file.split(separator: "/").last ?? "")
        guard !name.isEmpty else { return [] }
        let named = FileNameSearch.symbols(inFilesNamed: name, in: symbols, maxRank: 5)
        guard file.contains("/") else { return named }
        let tail = "/" + file.lowercased().drop { $0 == "/" }
        return named.filter { symbol in
            let address = (symbol.fileURL ?? openFile).absoluteString
            return (address.removingPercentEncoding ?? address).lowercased().hasSuffix(tail)
        }
    }
}

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

/// A folder of the list's files, for grouping them under a header (at the Code level, while
/// every file is folded).
nonisolated struct FolderGroup: Identifiable, Sendable {
    /// The folder's path in the project ("" for its top).
    let path: String
    /// Its files' entries and symbols, in list order.
    let symbols: [CodeSymbol]
    let fileCount: Int
    /// Its files, in list order: for its menu's Add to Album (which is made with each row, as
    /// it scrolls in: going through all its symbols for them then made scrolling hitch).
    var files: [URL] = []

    var id: String { path }

    /// Groups the list (path order: each file's entry, then its symbols) by the files'
    /// folders, in the order each folder's first file comes, so a folder's files are together
    /// even when its subfolders' come between them in path order.
    /// - Parameters:
    ///   - openFile: the file that symbols without a `fileURL` are in.
    ///   - scope: where the project's files start (their paths are after it).
    static func groups(of symbols: [CodeSymbol], openFile: URL, scope: String) -> [FolderGroup] {
        var order: [String] = []
        var byFolder: [String: [CodeSymbol]] = [:]
        var files: [String: [URL]] = [:]
        var folder = ""
        var current: URL?
        for symbol in symbols {
            // Each file's folder, worked out once (an album may list a file's symbols without
            // its entry).
            let file = symbol.fileURL ?? openFile
            if file != current {
                current = file
                folder = path(of: file, scope: scope)
            }
            if byFolder[folder] == nil { order.append(folder) }
            byFolder[folder, default: []].append(symbol)
            if symbol.kind == .file { files[folder, default: []].append(file) }
        }
        return order.map {
            FolderGroup(path: $0, symbols: byFolder[$0] ?? [], fileCount: files[$0]?.count ?? 0, files: files[$0] ?? [])
        }
    }

    /// The folder a file is in, inside the project: "" at its top.
    static func path(of file: URL, scope: String) -> String {
        let address = file.absoluteString
        guard address.hasPrefix(scope) else { return "" }
        let relative = String(address.dropFirst(scope.count))
        let decoded = relative.removingPercentEncoding ?? relative
        guard let slash = decoded.lastIndex(of: "/") else { return "" }
        return String(decoded[..<slash])
    }
}

/// The list's folders as a tree, for grouping: a folder (the project too) with more than
/// `threshold` folders under it, at any depth, shows as one header (a group) until it's opened,
/// so a project as big as Linux doesn't list thousands of folders.
nonisolated struct FolderTree: Sendable {
    /// Over this many folders under it, a folder is a group.
    static let threshold = 50

    nonisolated struct Node: Sendable {
        /// Its path in the project ("" for the project).
        let path: String
        /// Its folders, in the list's order.
        var children: [String] = []
        /// Its own files' folder (`nil`: it has only folders).
        var group: FolderGroup?
        /// Every folder with files under it (not itself), in the list's order.
        var below: [FolderGroup] = []
        var fileCount = 0

        var name: String { path.split(separator: "/").last.map(String.init) ?? path }
        var isGroup: Bool { below.count > FolderTree.threshold }
    }

    private(set) var nodes: [String: Node] = [:]

    var root: Node { nodes[""] ?? Node(path: "") }

    init(_ groups: [FolderGroup]) {
        nodes[""] = Node(path: "")
        for group in groups {
            let parts = group.path.split(separator: "/").map(String.init)
            var path = ""
            var ancestors = [""]
            for part in parts {
                let parent = path
                path = path.isEmpty ? part : path + "/" + part
                if nodes[path] == nil {
                    nodes[path] = Node(path: path)
                    nodes[parent]?.children.append(path)
                }
                ancestors.append(path)
            }
            nodes[group.path]?.group = group
            for ancestor in ancestors {
                nodes[ancestor]?.fileCount += group.fileCount
                if ancestor != group.path { nodes[ancestor]?.below.append(group) }
            }
        }
    }

    func node(_ path: String) -> Node? { nodes[path] }
}

/// What's collapsed at the Code level, saved in `UserDefaults`:
/// - symbols, whose code is hidden under their titles (tap a title);
/// - files, whose symbols are all hidden under the file's title (tap a file's title).
///
/// Collapse All makes a list's symbols collapsed by default, and pinching in once more folds
/// its files by default too. Each list has a scope (where its files are: a project's raw
/// address prefix, or the open file's address outside projects) and its defaults, so a symbol
/// or a file is kept only while it differs from its scope's default: by file, kind and name
/// for a symbol (so it stays as it is when its file changes). Loaded once; each title and
/// block only checks the sets, and a change writes them once.
@MainActor @Observable
final class CollapsedCodeStore {
    static let shared = CollapsedCodeStore(defaults: .standard)

    /// One that starts with nothing collapsed and isn't saved: a results page's, so the Code
    /// level's folds don't hide its results, and its own go with it.
    static func temporary() -> CollapsedCodeStore { CollapsedCodeStore(defaults: nil) }

    /// An album's own folds (`nil`: the whole project's, `shared`), so switching albums keeps
    /// each one as it was left. Made when first shown; an album starts with nothing folded.
    static func forAlbum(_ id: UUID?) -> CollapsedCodeStore {
        guard let id else { return shared }
        if let store = albumStores[id] { return store }
        let store = CollapsedCodeStore(defaults: .standard, namespace: "album." + id.uuidString + ".")
        albumStores[id] = store
        return store
    }

    private static var albumStores: [UUID: CollapsedCodeStore] = [:]

    /// A deleted album's folds go with it.
    static func forget(album id: UUID) {
        albumStores[id] = nil
        let namespace = "album." + id.uuidString + "."
        for key in Key.all { UserDefaults.standard.removeObject(forKey: Key.named(key, namespace)) }
    }

    /// Symbols that differ from their scope's default.
    private(set) var flipped: Set<String>
    /// Files that differ from their scope's default (folded, unless the scope's are).
    private(set) var files: Set<String>
    /// Scopes whose symbols are collapsed by default (Collapse All).
    private(set) var collapsedScopes: Set<String>
    /// Scopes whose files are folded by default (pinching in on all titles).
    private(set) var foldedScopes: Set<String>
    /// Folders that differ from their scope's default (folded under their header, unless the
    /// scope's are): `folder#` + scope + the folder's path. While every file is folded, the
    /// files are grouped by folder.
    private(set) var folders: Set<String>
    /// Scopes whose folders are folded by default (pinching in once more on the folders).
    private(set) var foldedFolderScopes: Set<String>
    /// Projects' scopes the Code level has shown (see `startFolded`).
    @ObservationIgnored private var seenScopes: Set<String>
    /// Groups of folders opened (`FolderTree`): `group#` + scope + the folder's path. A group
    /// starts closed.
    private(set) var openGroups: Set<String>
    /// `nil`: not saved (`temporary()`).
    @ObservationIgnored private let defaults: UserDefaults?
    /// Before each saved key's name: "" for the whole project's, an album's own otherwise.
    @ObservationIgnored private let namespace: String

    private enum Key {
        static let flipped = "collapsedCode.symbols"
        static let files = "collapsedCode.files"
        static let scopes = "collapsedCode.scopes"
        static let foldedScopes = "collapsedCode.foldedScopes"
        static let folders = "collapsedCode.folders"
        static let foldedFolderScopes = "collapsedCode.foldedFolderScopes"
        static let seenScopes = "collapsedCode.seenScopes"
        static let openGroups = "collapsedCode.openGroups"
        /// Before Collapse All: symbols and `file#` keys together.
        static let old = "collapsedCode"

        static let all = [flipped, files, scopes, foldedScopes, folders, foldedFolderScopes, seenScopes, openGroups]

        /// `collapsedCode.album.<id>.symbols` for an album's.
        static func named(_ key: String, _ namespace: String) -> String {
            namespace.isEmpty ? key : key.replacingOccurrences(of: "collapsedCode.", with: "collapsedCode." + namespace)
        }
    }

    init(defaults: UserDefaults?, namespace: String = "") {
        self.defaults = defaults
        self.namespace = namespace
        guard let defaults else {
            flipped = []
            files = []
            collapsedScopes = []
            foldedScopes = []
            folders = []
            foldedFolderScopes = []
            seenScopes = []
            openGroups = []
            return
        }
        func saved(_ key: String) -> [String] { defaults.stringArray(forKey: Key.named(key, namespace)) ?? [] }
        var flipped = Set(saved(Key.flipped))
        var files = Set(saved(Key.files))
        if namespace.isEmpty, let old = defaults.stringArray(forKey: Key.old) {
            for key in old {
                if key.hasPrefix("file#") { files.insert(key) } else { flipped.insert(key) }
            }
            defaults.removeObject(forKey: Key.old)
        }
        self.flipped = flipped
        self.files = files
        collapsedScopes = Set(saved(Key.scopes))
        foldedScopes = Set(saved(Key.foldedScopes))
        folders = Set(saved(Key.folders))
        foldedFolderScopes = Set(saved(Key.foldedFolderScopes))
        seenScopes = Set(saved(Key.seenScopes))
        openGroups = Set(saved(Key.openGroups))
    }

    func isGroupOpen(_ path: String, scope: String) -> Bool {
        openGroups.contains("group#" + scope + path)
    }

    func toggleGroup(_ path: String, scope: String) {
        let key = "group#" + scope + path
        if openGroups.contains(key) { openGroups.remove(key) } else { openGroups.insert(key) }
        save()
    }

    /// A project the Code level hasn't shown before starts with every folder folded: just the
    /// folders' headers, whatever its size (a big one has thousands of files). One already
    /// shown, before this was kept, keeps what it has when anything of it was folded.
    func startFolded(scope: String) {
        guard let defaults, !seenScopes.contains(scope) else { return }
        seenScopes.insert(scope)
        let hasFolds = collapsedScopes.contains(scope) || foldedScopes.contains(scope)
            || foldedFolderScopes.contains(scope) || folders.contains { $0.hasPrefix("folder#" + scope) }
        if !hasFolds {
            foldedScopes.insert(scope)
            foldedFolderScopes.insert(scope)
            save()
        } else {
            defaults.set(seenScopes.sorted(), forKey: Key.named(Key.seenScopes, namespace))
        }
    }

    func isFolderFolded(_ path: String, scope: String) -> Bool {
        foldedFolderScopes.contains(scope) != folders.contains("folder#" + scope + path)
    }

    /// Every folder is folded in the scope (unless tapped open since).
    func areAllFoldersFolded(scope: String) -> Bool {
        foldedFolderScopes.contains(scope)
    }

    /// Folds (or unfolds) every folder in a scope, down to the folders' headers.
    func setAllFoldersFolded(_ isFolded: Bool, scope: String) {
        if isFolded { foldedFolderScopes.insert(scope) } else { foldedFolderScopes.remove(scope) }
        folders = folders.filter { !$0.hasPrefix("folder#" + scope) }
        save()
    }

    func toggleFolder(_ path: String, scope: String) {
        let key = "folder#" + scope + path
        if folders.contains(key) { folders.remove(key) } else { folders.insert(key) }
        save()
    }

    /// - Parameter openFile: the file that symbols without a `fileURL` are in.
    nonisolated static func key(for symbol: CodeSymbol, openFile: URL) -> String {
        let key = (symbol.fileURL ?? openFile).absoluteString + "#" + symbol.kind.rawValue + "#" + symbol.name
        switch symbol.kind {
        case .hunk, .lines:
            // A diff's hunks often share their title (the code they're in), as lines can: their
            // line tells them apart.
            return key + "#" + String(symbol.line)
        default:
            // Overloads share their name: their declaration (their parameters) tells them apart.
            // Not their line, so a symbol stays collapsed as code above it changes.
            return key + "#" + signature(of: symbol)
        }
    }

    /// The declaration, up to its body (`{`) or its end (`;`), in its first few lines, its runs
    /// of spaces made one: `void draw(Point p, int size)`.
    nonisolated static func signature(of symbol: CodeSymbol) -> String {
        let head = symbol.preview.split(separator: "\n", omittingEmptySubsequences: false).prefix(4)
            .joined(separator: " ")
        let declaration = head.prefix { $0 != "{" && $0 != ";" }
        return declaration.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    nonisolated static func key(forFile file: URL) -> String {
        "file#" + file.absoluteString
    }

    func isCollapsed(_ symbol: CodeSymbol, openFile: URL, scope: String) -> Bool {
        collapsedScopes.contains(scope) != flipped.contains(Self.key(for: symbol, openFile: openFile))
    }

    func isFileCollapsed(_ file: URL, scope: String) -> Bool {
        foldedScopes.contains(scope) != files.contains(Self.key(forFile: file))
    }

    /// Not shown at all: in a folded file (a file's own title always shows).
    func isHidden(_ symbol: CodeSymbol, openFile: URL, scope: String) -> Bool {
        symbol.kind != .file && isFileCollapsed(symbol.fileURL ?? openFile, scope: scope)
    }

    /// Collapse All is on in the scope (every symbol collapsed, unless tapped open since).
    func areAllCollapsed(scope: String) -> Bool {
        collapsedScopes.contains(scope)
    }

    /// Nothing's code shows in the scope: Collapse All (or every file folded), and nothing
    /// opened since. Expand All is what's offered then, Collapse All otherwise.
    func isEverythingCollapsed(scope: String) -> Bool {
        (collapsedScopes.contains(scope) && !flipped.contains { $0.hasPrefix(scope) })
            || (foldedScopes.contains(scope) && !files.contains { $0.hasPrefix("file#" + scope) })
    }

    /// Every folder is folded in the scope, none opened since: Unfold All Folders is what's
    /// offered then, Fold All Folders otherwise.
    func isEveryFolderFolded(scope: String) -> Bool {
        foldedFolderScopes.contains(scope) && !folders.contains { $0.hasPrefix("folder#" + scope) }
    }

    /// Every file is folded in the scope (unless tapped open since).
    func areAllFilesFolded(scope: String) -> Bool {
        foldedScopes.contains(scope)
    }

    /// A file's title folds the file; a symbol's, its code.
    func toggle(_ symbol: CodeSymbol, openFile: URL, scope: String) {
        let key = symbol.kind == .file ? Self.key(forFile: symbol.fileURL ?? openFile)
            : Self.key(for: symbol, openFile: openFile)
        if symbol.kind == .file {
            if files.contains(key) { files.remove(key) } else { files.insert(key) }
        } else {
            if flipped.contains(key) { flipped.remove(key) } else { flipped.insert(key) }
        }
        save()
    }

    /// Collapses or expands these symbols (a file's), unfolding their
    /// file.
    func setCollapsed(_ isCollapsed: Bool, _ symbols: [CodeSymbol], openFile: URL, scope: String) {
        let byDefault = collapsedScopes.contains(scope)
        for symbol in symbols where symbol.kind != .file {
            let key = Self.key(for: symbol, openFile: openFile)
            if isCollapsed == byDefault { flipped.remove(key) } else { flipped.insert(key) }
            setFolded(false, symbol.fileURL ?? openFile, scope: scope)
        }
        save()
    }

    /// Expand All in a file (its title's menu): the file unfolded (a file without symbols shows
    /// its text), and every one of its symbols showing its code.
    func expandAll(in file: URL, _ symbols: [CodeSymbol], openFile: URL, scope: String) {
        setFolded(false, file, scope: scope)
        setCollapsed(false, symbols, openFile: openFile, scope: scope)  // saves
    }

    /// Expand All in a folder (its header's menu, while it's folded): the folder unfolded, its
    /// files unfolded, and every one of their symbols showing its code.
    func expandAll(inFolder path: String, files: [URL], _ symbols: [CodeSymbol], openFile: URL, scope: String) {
        let key = "folder#" + scope + path
        if foldedFolderScopes.contains(scope) { folders.insert(key) } else { folders.remove(key) }
        for file in files { setFolded(false, file, scope: scope) }
        setCollapsed(false, symbols, openFile: openFile, scope: scope)  // saves
    }

    /// Collapse All (or Expand All) in a scope: every symbol's code, and no file folded.
    func setAllCollapsed(_ isCollapsed: Bool, scope: String) {
        if isCollapsed { collapsedScopes.insert(scope) } else { collapsedScopes.remove(scope) }
        foldedScopes.remove(scope)
        foldedFolderScopes.remove(scope)
        folders = folders.filter { !$0.hasPrefix("folder#" + scope) }
        flipped = flipped.filter { !$0.hasPrefix(scope) }
        files = files.filter { !$0.hasPrefix("file#" + scope) }
        save()
    }

    /// Folds (or unfolds) every file in a scope, down to the files' titles; symbols stay as
    /// they are under them.
    func setAllFilesFolded(_ isFolded: Bool, scope: String) {
        if isFolded { foldedScopes.insert(scope) } else { foldedScopes.remove(scope) }
        files = files.filter { !$0.hasPrefix("file#" + scope) }
        save()
    }

    /// Shows a symbol and its code (Show in Code Level): the groups of folders it's in opened,
    /// its folder and file unfolded, and its code expanded (a file's: just unfolded). Nothing
    /// else changes.
    func reveal(_ symbol: CodeSymbol, openFile: URL, scope: String) {
        let file = symbol.fileURL ?? openFile
        let folder = FolderGroup.path(of: file, scope: scope)
        // Any folder down to it may be a group (`FolderTree`): open each one.
        var path = ""
        for part in folder.split(separator: "/") {
            path = path.isEmpty ? String(part) : path + "/" + part
            openGroups.insert("group#" + scope + path)
        }
        let folderKey = "folder#" + scope + folder
        if foldedFolderScopes.contains(scope) { folders.insert(folderKey) } else { folders.remove(folderKey) }
        setFolded(false, file, scope: scope)
        if symbol.kind != .file {
            let key = Self.key(for: symbol, openFile: openFile)
            if collapsedScopes.contains(scope) { flipped.insert(key) } else { flipped.remove(key) }
        }
        save()
    }

    private func setFolded(_ isFolded: Bool, _ file: URL, scope: String) {
        let key = Self.key(forFile: file)
        if isFolded == foldedScopes.contains(scope) { files.remove(key) } else { files.insert(key) }
    }

    private func save() {
        guard let defaults else { return }
        let namespace = namespace
        func set(_ values: Set<String>, _ key: String) { defaults.set(values.sorted(), forKey: Key.named(key, namespace)) }
        set(flipped, Key.flipped)
        set(files, Key.files)
        set(collapsedScopes, Key.scopes)
        set(foldedScopes, Key.foldedScopes)
        set(folders, Key.folders)
        set(foldedFolderScopes, Key.foldedFolderScopes)
        set(seenScopes, Key.seenScopes)
        set(openGroups, Key.openGroups)
    }
}
