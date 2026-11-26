import Foundation

/// A folder on this device that's a project (Add Local Folder in the sidebar: picked in Files, or
/// in Finder on a Mac). Its files are read where they are, so edits not committed yet show too.
/// A Git repository's history, blame and branches come from its own `.git`.
nonisolated struct LocalFolder: Codable, Hashable, Sendable {
    let id: UUID
    var name: String
    /// Keeps the access the picker gave, across launches.
    var bookmark: Data
}

nonisolated enum LocalFolderError: LocalizedError, Equatable {
    /// The folder can't be reached (moved, deleted, or its drive is gone).
    case unreachable(String)
    case uncommittedChanges
    case noSuchBranch(String)

    var errorDescription: String? {
        switch self {
        case .unreachable(let name):
            "“\(name)” can’t be opened. It may have moved or been deleted: add it again from the sidebar."
        case .uncommittedChanges:
            "Some files have changes that aren’t committed. Commit or stash them, then switch branches."
        case .noSuchBranch(let name):
            "There’s no branch “\(name)” here."
        }
    }
}

/// The folders picked, opened once (with the access their bookmarks keep) and kept open while
/// the app runs. Files in them have `gitty-local://<id>/<path>` addresses: the same wherever the
/// folder is on this device, and whichever branch is checked out.
nonisolated final class LocalFolderAccess: @unchecked Sendable {
    static let shared = LocalFolderAccess()

    static let scheme = "gitty-local"

    private let lock = NSLock()
    private var urls: [UUID: URL] = [:]

    /// What its files' addresses start with: `gitty-local://<id>/`.
    static func prefix(of id: UUID) -> String {
        "\(scheme)://\(id.uuidString.lowercased())/"
    }

    /// A folder just picked (its address from the picker), kept for later launches.
    static func folder(picked url: URL) throws -> LocalFolder {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let bookmark = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        return LocalFolder(id: UUID(), name: url.lastPathComponent, bookmark: bookmark)
    }

    /// Where the folder is now, opened for reading and writing (a checkout writes to it).
    /// `nil` if it can't be found.
    func url(of folder: LocalFolder) -> URL? {
        if let url = lock.withLock({ urls[folder.id] }) { return url }
        var isStale = false
        guard let url = try? URL(resolvingBookmarkData: folder.bookmark, options: [], relativeTo: nil,
                                 bookmarkDataIsStale: &isStale)
        else { return nil }
        _ = url.startAccessingSecurityScopedResource()  // for as long as the app runs
        lock.withLock { urls[folder.id] = url }
        return url
    }
}

/// A local folder's files: everything but `.git` and what Git ignores (in a repository), in
/// path order, each with its size and when it last changed.
nonisolated enum LocalFiles {
    nonisolated struct Item: Sendable, Hashable {
        /// From the folder's top.
        let path: String
        let size: Int
        let modified: Date?
    }

    static func list(at root: URL, repository: GitRepository?) -> [Item] {
        let rootPath = root.standardizedFileURL.path.hasSuffix("/")
            ? root.standardizedFileURL.path : root.standardizedFileURL.path + "/"
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        var items: [Item] = []
        // Packages (`X.xcodeproj`) are folders like any other here.
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys)
        while let file = enumerator?.nextObject() as? URL {
            let path = file.standardizedFileURL.path
            guard path.hasPrefix(rootPath) else { continue }
            let relative = String(path.dropFirst(rootPath.count))
            let values = try? file.resourceValues(forKeys: Set(keys))
            if values?.isDirectory == true {
                if file.lastPathComponent == ".git" || repository?.isIgnored(relative + "/") == true {
                    enumerator?.skipDescendants()
                }
                continue
            }
            guard values?.isRegularFile == true, file.lastPathComponent != ".git",
                  repository?.isIgnored(relative) != true
            else { continue }
            items.append(Item(path: relative, size: values?.fileSize ?? 0, modified: values?.contentModificationDate))
        }
        return items.sorted { $0.path < $1.path }
    }

    /// The same list as a project's file list (folders too, as GitHub's has them).
    static func tree(of items: [Item]) -> ProjectTree {
        var folders: Set<String> = []
        var entries: [ProjectTree.Entry] = []
        for item in items {
            var parts = item.path.split(separator: "/").dropLast()
            while !parts.isEmpty {
                let folder = parts.joined(separator: "/")
                guard folders.insert(folder).inserted else { break }
                entries.append(ProjectTree.Entry(path: folder, kind: .folder, sha: "", size: nil))
                parts = parts.dropLast()
            }
            entries.append(ProjectTree.Entry(path: item.path, kind: .file, sha: stamp(of: item), size: item.size))
        }
        return ProjectTree(entries: entries, truncated: false, etag: nil, fetchedAt: .now)
    }

    /// Changes whenever the file does (its date and size), like a Git hash for a file on disk.
    static func stamp(of item: Item) -> String {
        "\(item.modified?.timeIntervalSince1970 ?? 0)-\(item.size)"
    }

    /// Changes whenever any file is added, removed or changed: whether a refresh found anything.
    static func signature(of items: [Item]) -> String {
        var hasher = Hasher()
        for item in items {
            hasher.combine(item.path)
            hasher.combine(stamp(of: item))
        }
        return "\(items.count)-\(hasher.finalize())"
    }
}
