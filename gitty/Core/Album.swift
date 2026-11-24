import Foundation
import Observation

/// Like an album in Photos: the symbols, whole files and lines of one project you want to see
/// together. Choosing it in the sidebar makes Files, Symbols and Code show only what's in it,
/// in the project's order.
nonisolated struct Album: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var name: String
    /// The project it belongs to (`ProjectInfo.id`).
    var projectID: String
    var items: [AlbumItem]
    var createdAt: Date
    /// A diff album: the changes it shows, a card per file and hunk (`DiffAlbumContents`), and
    /// no items.
    var diff: AlbumDiff?

    init(id: UUID = UUID(), name: String, projectID: String, items: [AlbumItem] = [], createdAt: Date = .now,
         diff: AlbumDiff? = nil) {
        self.id = id
        self.name = name
        self.projectID = projectID
        self.items = items
        self.createdAt = createdAt
        self.diff = diff
    }

    /// Whether `item` is in the album itself (not just through its whole file).
    func contains(_ item: AlbumItem) -> Bool {
        items.contains { $0.isSame(as: item) }
    }

    /// Whether the whole file is in the album.
    func containsFile(_ file: URL) -> Bool {
        items.contains { if case .file(let url) = $0 { url == file } else { false } }
    }
}

/// Something in an album.
nonisolated enum AlbumItem: Codable, Hashable, Sendable {
    /// A whole file: its entry and all its symbols, whatever they become as it changes.
    case file(URL)
    /// One symbol, found again by its file, kind and name (see `AlbumSymbol`).
    case symbol(AlbumSymbol)
    /// Some lines of a file, a selection on a page.
    case lines(AlbumLines)

    var file: URL {
        switch self {
        case .file(let url): url
        case .symbol(let symbol): symbol.file
        case .lines(let lines): lines.file
        }
    }

    /// The same thing: a symbol is the same one wherever it has moved to in its file.
    func isSame(as other: AlbumItem) -> Bool {
        switch (self, other) {
        case (.file(let lhs), .file(let rhs)): lhs == rhs
        case (.symbol(let lhs), .symbol(let rhs)): lhs.file == rhs.file && lhs.kind == rhs.kind && lhs.name == rhs.name
        case (.lines(let lhs), .lines(let rhs)): lhs == rhs
        default: false
        }
    }

    /// The item for an entry in the list: a file's entry is the whole file, lines are lines,
    /// anything else that symbol.
    /// - Parameter openFile: the file that symbols without a `fileURL` are in.
    init(_ symbol: CodeSymbol, openFile: URL) {
        let file = symbol.fileURL ?? openFile
        switch symbol.kind {
        case .file:
            self = .file(file)
        case .lines:
            self = .lines(AlbumLines(file: file, start: symbol.line, end: symbol.endLine ?? symbol.line))
        default:
            self = .symbol(AlbumSymbol(file: file, name: symbol.name, kind: symbol.kind.rawValue,
                                       location: symbol.range.location))
        }
    }
}

/// A symbol in an album. Files change, so it's kept by name: it's the symbol of that kind and
/// name in its file, the one nearest where it was when several share the name (overloads).
nonisolated struct AlbumSymbol: Codable, Hashable, Sendable {
    let file: URL
    let name: String
    /// `CodeSymbol.Kind`'s raw value.
    let kind: String
    /// Where it started in its file (UTF-16) when it was added.
    let location: Int
}

/// Lines of a file in an album, 1-based, both included.
nonisolated struct AlbumLines: Codable, Hashable, Sendable {
    let file: URL
    let start: Int
    let end: Int
}

// MARK: - What an album shows

nonisolated enum AlbumContents {
    /// The album's entries, in the order they were added, from the list `symbols` (each file's
    /// entry, then its symbols; see `CodeDocumentModel`):
    /// - a whole file: its entry and all its symbols, in file order;
    /// - a symbol that's still there, matched by kind and name (the nearest to where it was);
    /// - lines, from `texts` (the files' text; a file that's missing there leaves its lines out
    ///   until it's loaded), as entries of their own, ids from `symbols.count` up.
    ///
    /// Something added twice (a symbol, then its whole file) shows once, where it came first.
    /// Symbols keep their ids (places in the full list), so a place saved in the album is one in
    /// the full list too.
    /// - Parameter openFile: the file that symbols without a `fileURL` are in.
    static func symbols(of album: Album, in symbols: [CodeSymbol], openFile: URL,
                        texts: [URL: NSString]) -> [CodeSymbol] {
        guard !album.items.isEmpty else { return [] }
        // Each file's run of the list: its entry, then its symbols.
        var runs: [URL: Range<Int>] = [:]
        var start = 0
        while start < symbols.count {
            let fileURL = symbols[start].fileURL
            var end = start + 1
            while end < symbols.count, symbols[end].kind != .file, symbols[end].fileURL == fileURL { end += 1 }
            let file = fileURL ?? openFile
            if runs[file] == nil { runs[file] = start..<end }
            start = end
        }

        var result: [CodeSymbol] = []
        var shown: Set<Int> = []
        var lineStartsByFile: [URL: [Int]] = [:]
        for item in album.items {
            switch item {
            case .file(let url):
                guard let run = runs[url] else { continue }
                for symbol in symbols[run] where shown.insert(symbol.id).inserted {
                    result.append(symbol)
                }
            case .symbol(let wanted):
                guard let run = runs[wanted.file] else { continue }
                let match = symbols[run]
                    .filter { $0.kind.rawValue == wanted.kind && $0.name == wanted.name && !shown.contains($0.id) }
                    .min { abs($0.range.location - wanted.location) < abs($1.range.location - wanted.location) }
                if let match {
                    shown.insert(match.id)
                    result.append(match)
                }
            case .lines(let lines):
                guard let run = runs[lines.file], let text = texts[lines.file] else { continue }
                let starts = lineStartsByFile[lines.file] ?? lineStarts(of: text)
                lineStartsByFile[lines.file] = starts
                // From its file and lines, like the list's ids (`CodeSymbol.stableID`): the same in
                // the next list, and not one of the list's.
                let id = CodeSymbol.stableID(fileHash: CodeSymbol.fileHash("lines:" + lines.file.absoluteString),
                                             index: lines.start &* 1_000_003 &+ lines.end)
                guard shown.insert(id).inserted,
                      let entry = entry(for: lines, in: text, lineStarts: starts, id: id,
                                        fileURL: symbols[run.lowerBound].fileURL) else { continue }
                result.append(entry)
            }
        }
        return result
    }

    /// The files whose text `symbols(of:in:openFile:texts:)` needs: those with lines in the album.
    static func filesWithLines(in album: Album) -> Set<URL> {
        Set(album.items.compactMap { if case .lines(let lines) = $0 { lines.file } else { nil } })
    }

    /// An entry for some lines: from the start of the first to the end of the last (without
    /// its line break), named after its first line that isn't blank. `nil` when the file is
    /// shorter now than where the lines start.
    static func entry(for lines: AlbumLines, in text: NSString, lineStarts starts: [Int], id: Int,
                      fileURL: URL?) -> CodeSymbol? {
        let first = max(1, lines.start)
        guard first <= starts.count else { return nil }
        let last = min(max(first, lines.end), starts.count)
        let location = starts[first - 1]
        var endLocation = last < starts.count ? starts[last] : text.length
        if endLocation > location, text.character(at: endLocation - 1) == 0x0A { endLocation -= 1 }
        if endLocation > location, text.character(at: endLocation - 1) == 0x0D { endLocation -= 1 }
        let range = NSRange(location: location, length: endLocation - location)
        let code = text.substring(with: range)
        let rows = code.split(separator: "\n", omittingEmptySubsequences: false)
        let title = rows.lazy.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }
        let preview = rows.prefix(SymbolIndexer.previewLineCount).joined(separator: "\n")
            .replacingOccurrences(of: "\t", with: "    ")
        return CodeSymbol(id: id, name: title ?? String(localized: "Blank Lines"), kind: .lines, range: range,
                          line: first, preview: preview, fileURL: fileURL, endLine: last)
    }

    /// Where each line starts (UTF-16), the first at 0.
    static func lineStarts(of text: NSString) -> [Int] {
        var starts = [0]
        var index = 0
        while index < text.length {
            let found = text.range(of: "\n", options: .literal, range: NSRange(location: index, length: text.length - index))
            guard found.location != NSNotFound else { break }
            index = NSMaxRange(found)
            if index < text.length { starts.append(index) }
        }
        return starts
    }
}

// MARK: - Store

/// The albums, saved in `UserDefaults` (a few bytes per item). Observed: the sidebar, menus and
/// the screen showing an album follow its changes.
@MainActor @Observable
final class AlbumStore {
    static let shared = AlbumStore(defaults: .standard)

    private(set) var albums: [Album] = []
    /// Goes up when a file added to an album has been downloaded: the list showing the album
    /// can index it now.
    private(set) var downloadCount = 0
    @ObservationIgnored private let defaults: UserDefaults
    private static let key = "albums"

    init(defaults: UserDefaults) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.key),
           let saved = try? JSONDecoder().decode([Album].self, from: data) {
            albums = saved
        }
    }

    func album(id: UUID?) -> Album? {
        guard let id else { return nil }
        return albums.first { $0.id == id }
    }

    /// A project's albums, oldest first (like Photos' order of creation).
    func albums(inProject projectID: String) -> [Album] {
        albums.filter { $0.projectID == projectID }
    }

    /// A new album, with `items` in it (or a diff album, showing `diff`).
    @discardableResult
    func create(named name: String, projectID: String, items: [AlbumItem] = [], diff: AlbumDiff? = nil) -> Album {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var album = Album(name: trimmed.isEmpty ? String(localized: "Untitled Album") : trimmed, projectID: projectID,
                          diff: diff)
        album.items = Self.adding(items, to: [])
        albums.append(album)
        save()
        return album
    }

    func fileDownloaded() {
        downloadCount += 1
    }

    func rename(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        update(id) { $0.name = trimmed }
    }

    func delete(_ id: UUID) {
        albums.removeAll { $0.id == id }
        save()
        Self.forgetPlace(of: id)
    }

    /// A project was deleted: its albums go with it.
    func deleteAlbums(inProject projectID: String) {
        let gone = albums.filter { $0.projectID == projectID }.map(\.id)
        albums.removeAll { $0.projectID == projectID }
        save()
        gone.forEach(Self.forgetPlace)
    }

    /// Where its list was left, and what was folded in it.
    private static func forgetPlace(of id: UUID) {
        CollapsedCodeStore.forget(album: id)
        ReadingPositionStore.standard.removeSymbolsPosition(forAlbum: id)
    }

    /// New Album, anywhere (swiping past the last album, a menu's New Album): "New Album"
    /// (numbered when that's taken), without asking for a name (rename it on the albums page).
    @discardableResult
    func createUntitled(projectID: String, items: [AlbumItem] = []) -> Album {
        create(named: untitledName(projectID: projectID), projectID: projectID, items: items)
    }

    /// What `createUntitled` would call it.
    func untitledName(projectID: String) -> String {
        let base = String(localized: "New Album")
        let taken = Set(albums(inProject: projectID).map(\.name))
        var name = base, number = 2
        while taken.contains(name) {
            name = "\(base) \(number)"
            number += 1
        }
        return name
    }

    /// Reordering on the albums page: `id` takes `target`'s place (after it when moving down
    /// the list, before it when moving up), so the bar's swipe follows the new order.
    func move(_ id: UUID, to target: UUID) {
        guard id != target, let from = albums.firstIndex(where: { $0.id == id }),
              let to = albums.firstIndex(where: { $0.id == target })
        else { return }
        let album = albums.remove(at: from)
        albums.insert(album, at: to)
        save()
    }

    /// Adds what isn't in the album yet, at the end.
    func add(_ items: [AlbumItem], to id: UUID) {
        update(id) { $0.items = Self.adding(items, to: $0.items) }
    }

    func remove(_ items: [AlbumItem], from id: UUID) {
        update(id) { album in album.items.removeAll { item in items.contains { $0.isSame(as: item) } } }
    }

    private static func adding(_ items: [AlbumItem], to existing: [AlbumItem]) -> [AlbumItem] {
        var result = existing
        for item in items where !result.contains(where: { $0.isSame(as: item) }) {
            result.append(item)
        }
        return result
    }

    private func update(_ id: UUID, _ change: (inout Album) -> Void) {
        guard let index = albums.firstIndex(where: { $0.id == id }) else { return }
        change(&albums[index])
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(albums) else { return }
        defaults.set(data, forKey: Self.key)
    }
}
