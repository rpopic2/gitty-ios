import CryptoKit
import Foundation

/// The symbols of a project's downloaded files, for the Code level and symbol search across the
/// project. Nothing is read up front: `listing` gives every file at once (its symbols if they're
/// known, otherwise just its title), and `index` reads and parses files a batch at a time, the
/// ones on screen first (`CodeDocumentModel` drives it). Results are kept in memory while the
/// app runs and saved on the device, a file per folder, so a relaunch or a pull only parses
/// the files that changed.
actor ProjectSymbolIndex {
    static let shared = ProjectSymbolIndex()

    /// One file's entry (see `SymbolIndexer.fileEntry`) and its symbols, ids in file order. Its
    /// entry's `isIndexed` is false while its symbols aren't known yet.
    nonisolated struct FileSymbols: Sendable {
        let url: URL
        let file: CodeSymbol
        let symbols: [CodeSymbol]
    }

    /// What `index` found for a file.
    nonisolated enum Result: Sendable {
        case indexed(FileSymbols)
        /// Not text (an image, say): it isn't listed.
        case notText(URL)
    }

    private struct Entry {
        let fetchedAt: Date
        let result: Result
    }

    private let store: DocumentStore
    private var cache: [URL: Entry] = [:]
    /// The last listing's files, for `index` (which goes through them a batch at a time).
    private var listed: [URL: DocumentMetadata] = [:]

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

    /// Files that are never text, by their extension (images, archives, fonts, media…).
    nonisolated static func isNeverText(_ path: String) -> Bool {
        neverText.contains((path as NSString).pathExtension.lowercased())
    }

    nonisolated private static let neverText: Set<String> = [
        "png", "jpg", "jpeg", "gif", "bmp", "ico", "icns", "webp", "tif", "tiff", "heic", "pdf", "zip", "gz", "tgz",
        "bz2", "xz", "7z", "rar", "tar", "jar", "a", "o", "so", "dylib", "dll", "exe", "bin", "class", "woff", "woff2",
        "ttf", "otf", "mp3", "mp4", "mov", "wav", "m4a", "aac", "psd", "sketch", "car", "pbxuser",
    ]

    /// The project a file belongs to, if any: the one with the most specific folder.
    static func project(containing url: URL, in projects: [ProjectInfo]) -> ProjectInfo? {
        let address = url.absoluteString
        return projects
            .compactMap { project in prefix(of: project).map { (project, $0) } }
            .filter { address.hasPrefix($0.1) }
            .max { $0.1.count < $1.1.count }?
            .0
    }

    // MARK: Listing and indexing

    /// Every downloaded file in `project` except `excluded` that may be text, in path order,
    /// only files the project's filter lets through: with its symbols when they're known,
    /// otherwise just its title (`isIndexed` false). Reads no file.
    /// A cloned project's come in Git's order, as they are (sorting tens of thousands took
    /// seconds); the files downloaded one by one, a few, are sorted.
    /// - Returns: also the files whose saved copy changed since they were indexed (a pull
    ///   changes a clone's): their old symbols show until `index` reads them again; and where
    ///   `excluded` goes among them.
    func listing(in project: ProjectInfo, excluding excluded: URL, matching filter: FileFilter = .none) async
        -> (files: [FileSymbols], stale: Set<URL>, excludedPlace: Int) {
        guard let prefix = Self.prefix(of: project) else { return ([], [], 0) }
        func passes(_ metadata: DocumentMetadata) -> Bool {
            let address = metadata.url.absoluteString
            guard address.hasPrefix(prefix), !Self.isNeverText(address) else { return false }
            guard !filter.isEmpty else { return true }
            let relative = String(address.dropFirst(prefix.count))
            return filter.matches(relative.removingPercentEncoding ?? relative)
        }
        var files: [DocumentMetadata]
        if let clone = CloneIndex.shared.record(forProject: project.id) {
            files = CloneIndex.shared.files(of: clone).filter(passes)
        } else {
            files = await store.savedDocuments().filter(passes)
                .sorted { $0.url.absoluteString.localizedStandardCompare($1.url.absoluteString) == .orderedAscending }
        }
        let excludedPlace = files.firstIndex { $0.url == excluded }
            ?? files.firstIndex { $0.url.absoluteString > excluded.absoluteString }
            ?? files.count
        files.removeAll { $0.url == excluded }
        listed = Dictionary(files.map { ($0.url, $0) }, uniquingKeysWith: { first, _ in first })
        var stale: Set<URL> = []
        let found = files.compactMap { metadata -> FileSymbols? in
            guard let entry = cache[metadata.url] else { return Self.unindexed(metadata.url) }
            if entry.fetchedAt != metadata.fetchedAt { stale.insert(metadata.url) }
            switch entry.result {
            case .indexed(let file): return file
            case .notText: return nil
            }
        }
        // Where the open file goes, counted in what's listed (files that aren't text aren't).
        let place = files.prefix(excludedPlace).reduce(0) { count, metadata in
            if case .notText = cache[metadata.url]?.result { return count }
            return count + 1
        }
        return (found, stale, place)
    }

    /// A file's title before its symbols are known.
    nonisolated static func unindexed(_ url: URL) -> FileSymbols {
        let entry = CodeSymbol(id: 0, name: url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent,
                               kind: .file, range: NSRange(location: 0, length: 0), line: 1, preview: "",
                               isIndexed: false)
        return FileSymbols(url: url, file: entry, symbols: [])
    }

    /// Reads and parses these files (a few side by side), or takes them from the saved index
    /// when they haven't changed since. Stops early when the task is cancelled.
    func index(_ urls: [URL], in project: ProjectInfo) async -> [Result] {
        guard let prefix = Self.prefix(of: project) else { return [] }
        var metadata: [URL: DocumentMetadata] = [:]
        for url in urls { metadata[url] = listed[url] }
        if metadata.count < urls.count {  // listed since (downloaded from its title, say)
            let wanted = Set(urls)
            for document in await store.savedDocuments() where wanted.contains(document.url) {
                metadata[document.url] = document
            }
        }
        var results: [Result] = []
        // A folder's files at a time, with that folder's saved index.
        var byFolder: [String: [URL]] = [:]
        var order: [String] = []
        for url in urls {
            let folder = FolderGroup.path(of: url, scope: prefix)
            if byFolder[folder] == nil { order.append(folder) }
            byFolder[folder, default: []].append(url)
        }
        for folder in order {
            guard !Task.isCancelled else { break }
            let shardURL = Self.shardURL(projectID: project.id, prefix: prefix, folder: folder)
            var shard = openShard(shardURL)
            var changed = 0
            var toParse: [(url: URL, key: String)] = []
            for url in byFolder[folder] ?? [] {
                guard let meta = metadata[url] else { continue }  // deleted meanwhile
                let key = Self.freshnessKey(meta)
                if let cached = shard[url.absoluteString], cached.key == key {
                    let result = cached.result(for: url)
                    cache[url] = Entry(fetchedAt: meta.fetchedAt, result: result)
                    results.append(result)
                } else {
                    toParse.append((url, key))
                }
            }
            let parsed = await parse(toParse.map(\.url))
            for (item, result) in zip(toParse, parsed) {
                guard let result, let meta = metadata[item.url] else { continue }
                cache[item.url] = Entry(fetchedAt: meta.fetchedAt, result: result)
                shard[item.url.absoluteString] = SavedFile(key: item.key, result: result)
                changed += 1
                results.append(result)
            }
            if changed > 0 { keep(shard, at: shardURL, changed: changed) }
        }
        return results
    }

    // A big folder is read in many batches: its saved index stays open between them and is
    // written every few hundred files, not after each batch (it's rewritten whole).
    private var openShards: [URL: [String: SavedFile]] = [:]
    private var shardOrder: [URL] = []
    private var unsavedFiles: [URL: Int] = [:]

    private func openShard(_ url: URL) -> [String: SavedFile] {
        if let shard = openShards[url] { return shard }
        let shard = Self.loadShard(url)
        openShards[url] = shard
        shardOrder.append(url)
        while shardOrder.count > 6 {
            let oldest = shardOrder.removeFirst()
            if unsavedFiles[oldest] != nil, let old = openShards[oldest] { Self.saveShard(old, to: oldest) }
            unsavedFiles[oldest] = nil
            openShards[oldest] = nil
        }
        return shard
    }

    private func keep(_ shard: [String: SavedFile], at url: URL, changed: Int) {
        openShards[url] = shard
        let unsaved = unsavedFiles[url, default: 0] + changed
        if unsaved >= 400 {
            Self.saveShard(shard, to: url)
            unsavedFiles[url] = nil
        } else {
            unsavedFiles[url] = unsaved
        }
    }

    /// Writes what's been read since the last save (indexing stopped, or the app is leaving).
    func saveIndex() {
        for (url, _) in unsavedFiles {
            if let shard = openShards[url] { Self.saveShard(shard, to: url) }
        }
        unsavedFiles = [:]
    }

    /// Reads and parses files side by side, off this actor (parsing is the slow part).
    private func parse(_ urls: [URL]) async -> [Result?] {
        guard !urls.isEmpty else { return [] }
        let width = max(2, ProcessInfo.processInfo.activeProcessorCount)
        var results = [Result?](repeating: nil, count: urls.count)
        var start = 0
        while start < urls.count, !Task.isCancelled {
            let end = min(start + width, urls.count)
            var documents: [(Int, StoredDocument)] = []
            for index in start..<end {
                if let document = await store.cached(urls[index]) { documents.append((index, document)) }
            }
            await withTaskGroup(of: (Int, Result).self) { group in
                for (index, document) in documents {
                    group.addTask(priority: .utility) { (index, Self.parse(document)) }
                }
                for await (index, result) in group { results[index] = result }
            }
            start = end
        }
        return results
    }

    nonisolated private static func parse(_ document: StoredDocument) -> Result {
        let url = document.metadata.url
        guard isText(document.data) else { return .notText(url) }
        let text = RawTextDecoder.decode(document.data, contentType: document.metadata.contentType)
        var symbols: [CodeSymbol] = []
        if case .symbols(let found) = SymbolIndexer.index(text, fileExtension: url.pathExtension) {
            symbols = found
        }
        // Listed even without symbols: the file itself is an entry.
        let file = SymbolIndexer.fileEntry(named: url.lastPathComponent, text: text)
        return .indexed(FileSymbols(url: url, file: file, symbols: symbols))
    }

    /// What tells whether a file changed since it was indexed: a cloned file's date and size
    /// on disk (a checkout rewrites only the files that change), a downloaded one's download.
    nonisolated private static func freshnessKey(_ metadata: DocumentMetadata) -> String {
        if let location = CloneIndex.shared.location(of: metadata.url) {
            let file = CloneIndex.shared.folder(of: location.record).appending(path: location.path)
            let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            return "c\(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)-\(values?.fileSize ?? -1)"
        }
        return "d\(metadata.fetchedAt.timeIntervalSince1970)"
    }

    // MARK: Saved index

    /// Up when what the indexer finds changes, so older saved indexes aren't used.
    private static let version = 1

    nonisolated static let directory = URL.applicationSupportDirectory
        .appending(path: "SymbolIndex/v\(version)", directoryHint: .isDirectory)

    nonisolated private static func hash(_ string: String) -> String {
        SHA256.hash(data: Data(string.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    /// A project's saved index: one file per folder of each branch or tag it was on (their files
    /// are at different addresses).
    nonisolated static func folder(projectID: String) -> URL {
        directory.appending(path: hash(projectID), directoryHint: .isDirectory)
    }

    nonisolated private static func shardURL(projectID: String, prefix: String, folder: String) -> URL {
        Self.folder(projectID: projectID).appending(path: hash(prefix + "\n" + folder) + ".plist")
    }

    /// The space a project's saved index takes (counted in its size, in Project).
    nonisolated static func savedBytes(projectID: String) -> Int64 {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey]
        let files = (try? FileManager.default.contentsOfDirectory(at: folder(projectID: projectID),
                                                                  includingPropertiesForKeys: Array(keys))) ?? []
        return files.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: keys))?.totalFileAllocatedSize ?? 0) }
    }

    /// A project was deleted: its saved index goes too.
    nonisolated static func deleteSaved(projectID: String) {
        try? FileManager.default.removeItem(at: folder(projectID: projectID))
    }

    nonisolated private static func loadShard(_ url: URL) -> [String: SavedFile] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        return (try? PropertyListDecoder().decode([String: SavedFile].self, from: data)) ?? [:]
    }

    nonisolated private static func saveShard(_ shard: [String: SavedFile], to url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        guard let data = try? encoder.encode(shard) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

/// A file in the saved index: what it was indexed at (`freshnessKey`) and what was found.
nonisolated private struct SavedFile: Codable {
    let key: String
    /// `nil`: not text.
    let file: SavedSymbol?
    let symbols: [SavedSymbol]

    init(key: String, result: ProjectSymbolIndex.Result) {
        self.key = key
        switch result {
        case .indexed(let found):
            file = SavedSymbol(found.file)
            symbols = found.symbols.map(SavedSymbol.init)
        case .notText:
            file = nil
            symbols = []
        }
    }

    func result(for url: URL) -> ProjectSymbolIndex.Result {
        guard let file else { return .notText(url) }
        return .indexed(ProjectSymbolIndex.FileSymbols(url: url, file: file.symbol(id: 0),
                                                       symbols: symbols.enumerated().map { $1.symbol(id: $0) }))
    }
}

nonisolated private struct SavedSymbol: Codable {
    let name: String
    let kind: String
    let location: Int
    let length: Int
    let line: Int
    let preview: String

    init(_ symbol: CodeSymbol) {
        name = symbol.name
        kind = symbol.kind.rawValue
        location = symbol.range.location
        length = symbol.range.length
        line = symbol.line
        preview = symbol.preview
    }

    func symbol(id: Int) -> CodeSymbol {
        CodeSymbol(id: id, name: name, kind: CodeSymbol.Kind(rawValue: kind) ?? .global,
                   range: NSRange(location: location, length: length), line: line, preview: preview)
    }
}
