import CryptoKit
import Foundation

/// A project cloned with Git (Clone, in the Project tab): which branch or tag, how much history,
/// and where its files are on this device.
nonisolated struct CloneRecord: Codable, Equatable, Sendable {
    let projectID: String
    var ref: GitRef
    /// The commit checked out.
    var commit: String
    /// How many commits were fetched (`nil`: all of them).
    var depth: Int?
    /// The project's raw file address at `ref`, up to the repository's root
    /// (`https://raw.githubusercontent.com/owner/repo/main/`). Files under it are read from the
    /// clone instead of being downloaded.
    var rawPrefix: String
    var checkedOutAt: Date
    /// The clone's folder under `CloneIndex.directory`.
    let folderName: String
}

/// Which projects are cloned, and their files: read by `DocumentStore` (from any thread) so a
/// cloned project's files come from the clone.
nonisolated final class CloneIndex: @unchecked Sendable {
    static let shared = CloneIndex()

    static let defaultDirectory = URL.applicationSupportDirectory.appending(path: "Clones", directoryHint: .isDirectory)

    let directory: URL
    private let lock = NSLock()
    private var records: [String: CloneRecord]?
    /// Each clone's files (raw URLs), listed once per checkout.
    private var fileLists: [String: [DocumentMetadata]] = [:]

    init(directory: URL = CloneIndex.defaultDirectory) {
        self.directory = directory
    }

    private var indexURL: URL { directory.appending(path: "clones.json") }

    func record(forProject projectID: String) -> CloneRecord? {
        lock.withLock { loaded()[projectID] }
    }

    func allRecords() -> [CloneRecord] {
        lock.withLock { Array(loaded().values) }
    }

    func save(_ record: CloneRecord) {
        lock.withLock {
            var all = loaded()
            all[record.projectID] = record
            records = all
            fileLists[record.projectID] = nil
            write(all)
        }
    }

    func remove(projectID: String) {
        lock.withLock {
            var all = loaded()
            all[projectID] = nil
            records = all
            fileLists[projectID] = nil
            write(all)
        }
    }

    /// The clone's folder: its working tree, with `.git` inside.
    func folder(of record: CloneRecord) -> URL {
        directory.appending(path: record.folderName, directoryHint: .isDirectory)
    }

    static func folderName(for projectID: String) -> String {
        SHA256.hash(data: Data(projectID.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    /// The clone a file address is in, and the file's path inside the repository.
    func location(of url: URL) -> (record: CloneRecord, path: String)? {
        let address = url.absoluteString
        let all = lock.withLock { loaded() }
        guard let record = all.values.filter({ address.hasPrefix($0.rawPrefix) })
            .max(by: { $0.rawPrefix.count < $1.rawPrefix.count })
        else { return nil }
        let relative = String(address.dropFirst(record.rawPrefix.count))
        let path = relative.removingPercentEncoding ?? relative
        guard !path.isEmpty, !path.split(separator: "/").contains(where: { $0 == ".." || $0 == ".git" }) else {
            return nil
        }
        return (record, path)
    }

    /// A cloned file, read from the clone, as if it had been downloaded (when it was checked
    /// out). `nil` if the address isn't in a clone, or the clone doesn't have that file.
    func document(for url: URL) -> StoredDocument? {
        guard let (record, path) = location(of: url) else { return nil }
        let file = folder(of: record).appending(path: path)
        guard let data = try? Data(contentsOf: file, options: .mappedIfSafe) else { return nil }
        return StoredDocument(url: url, data: data, metadata: metadata(url, record))
    }

    /// How many projects are cloned and the space their clones take (files and Git's data), for
    /// Settings. Goes through every file: call it off the main thread.
    func storageUsage() -> (count: Int, bytes: Int64) {
        let records = allRecords()
        var bytes: Int64 = 0
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .totalFileAllocatedSizeKey]
        for record in records {
            let enumerator = FileManager.default.enumerator(at: folder(of: record), includingPropertiesForKeys: Array(keys))
            while let file = enumerator?.nextObject() as? URL {
                guard let values = try? file.resourceValues(forKeys: keys), values.isRegularFile == true else { continue }
                bytes += Int64(values.totalFileAllocatedSize ?? 0)
            }
        }
        return (records.count, bytes)
    }

    /// Every file in the clones, as saved documents (for the project's symbols, and the saved
    /// marks in the Project tab).
    func allFiles() -> [DocumentMetadata] {
        allRecords().flatMap { files(of: $0) }
    }

    private func files(of record: CloneRecord) -> [DocumentMetadata] {
        if let list = lock.withLock({ fileLists[record.projectID] }) { return list }
        let root = folder(of: record)
        let rootPath = root.standardizedFileURL.path + "/"
        var list: [DocumentMetadata] = []
        let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsPackageDescendants])
        while let file = enumerator?.nextObject() as? URL {
            if file.lastPathComponent == ".git" {
                enumerator?.skipDescendants()
                continue
            }
            guard (try? file.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            let path = String(file.standardizedFileURL.path.dropFirst(rootPath.count))
            let encoded = path.split(separator: "/")
                .map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }
                .joined(separator: "/")
            guard let url = URL(string: record.rawPrefix + encoded) else { continue }
            list.append(metadata(url, record))
        }
        lock.withLock { fileLists[record.projectID] = list }
        return list
    }

    private func metadata(_ url: URL, _ record: CloneRecord) -> DocumentMetadata {
        DocumentMetadata(url: url, etag: record.commit, lastModified: nil, contentType: nil,
                         fetchedAt: record.checkedOutAt)
    }

    // MARK: Disk (call with the lock held)

    private func loaded() -> [String: CloneRecord] {
        if let records { return records }
        let list = (try? Data(contentsOf: indexURL)).flatMap { try? JSONDecoder().decode([CloneRecord].self, from: $0) } ?? []
        let loaded = Dictionary(list.map { ($0.projectID, $0) }, uniquingKeysWith: { _, last in last })
        records = loaded
        return loaded
    }

    private func write(_ records: [String: CloneRecord]) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var folder = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true  // can be cloned again
        try? folder.setResourceValues(values)
        if let data = try? JSONEncoder().encode(Array(records.values)) {
            try? data.write(to: indexURL, options: .atomic)
        }
    }
}

nonisolated enum CloneError: LocalizedError, Equatable {
    /// The project is at a commit, not a branch or tag.
    case notABranchOrTag(String)
    case notCloned

    var errorDescription: String? {
        switch self {
        case .notABranchOrTag(let ref):
            "“\(ref)” isn’t a branch or tag. Choose a branch or tag to clone."
        case .notCloned:
            "This project isn’t cloned."
        }
    }
}

/// Clones projects (shallow: just the latest commit), switches them between branches and tags,
/// and reads their history. Git work runs off the main thread, one operation per project at a
/// time.
actor CloneStore {
    static let shared = CloneStore()

    /// The first clone: the latest commit only.
    static let initialDepth = 1
    /// How many more commits each "load more" fetches.
    static let deepenStep = 100

    private let index: CloneIndex
    private let documents: DocumentStore
    /// Projects with an operation running (each one's operations wait for the one before).
    private var running: [String: Task<Void, Never>] = [:]

    init(index: CloneIndex = .shared, documents: DocumentStore = .shared) {
        self.index = index
        self.documents = documents
    }

    func record(forProject projectID: String) -> CloneRecord? {
        index.record(forProject: projectID)
    }

    /// Clones the project at its branch or tag, the latest commit only, then reads its files
    /// from the clone: the files downloaded one by one are deleted.
    /// - Parameter progress: the fraction of objects received.
    func clone(_ project: ProjectInfo, progress: @escaping @Sendable (Double) -> Void) async throws {
        guard let refName = project.ref else { throw CloneError.notABranchOrTag("") }
        let refs = try await ProjectStore.shared.refs(for: project.id)
        let ref: GitRef
        if refs.branches.contains(refName) {
            ref = .branch(refName)
        } else if refs.tags.contains(refName) {
            ref = .tag(refName)
        } else {
            throw CloneError.notABranchOrTag(refName)
        }
        guard let remote = URL(string: "https://github.com/\(project.link.owner)/\(project.link.repo).git"),
              let rawPrefix = project.rawURL(for: "")?.absoluteString
        else { throw CloneError.notABranchOrTag(refName) }
        let token = await GitHubAuth.shared.token()
        let folderName = CloneIndex.folderName(for: project.id)
        let folder = index.directory.appending(path: folderName, directoryHint: .isDirectory)
        let depth = Self.initialDepth

        let commit = try await serially(project.id) {
            try? FileManager.default.removeItem(at: folder)  // a clone that didn't finish
            do {
                let repository = try GitRepository.create(at: folder, remote: remote)
                try repository.fetch(ref, depth: depth, token: token, progress: progress,
                                     isCancelled: { Task.isCancelled })
                return try repository.checkout(ref)
            } catch {
                try? FileManager.default.removeItem(at: folder)
                throw error
            }
        }
        await documents.deleteDownloads(under: rawPrefix)
        index.save(CloneRecord(projectID: project.id, ref: ref, commit: commit, depth: Self.initialDepth,
                               rawPrefix: rawPrefix, checkedOutAt: .now, folderName: folderName))
        await documents.clonesChanged()
    }

    /// Deletes the clone. The project's files download one by one again when opened.
    func delete(projectID: String) async {
        guard let record = index.record(forProject: projectID) else { return }
        let folder = index.folder(of: record)
        try? await serially(projectID) { try? FileManager.default.removeItem(at: folder) }
        index.remove(projectID: projectID)
        await documents.clonesChanged()
    }

    /// Switches the clone to another branch or tag: fetches its latest commit and checks it out.
    /// - Parameter rawPrefix: the project's raw file address at the new ref.
    func switchTo(_ ref: GitRef, projectID: String, rawPrefix: String) async throws {
        guard var record = index.record(forProject: projectID) else { throw CloneError.notCloned }
        let folder = index.folder(of: record)
        let token = await GitHubAuth.shared.token()
        let depth = Self.initialDepth
        let commit = try await serially(projectID) {
            let repository = try GitRepository(at: folder)
            try repository.fetch(ref, depth: depth, token: token, isCancelled: { Task.isCancelled })
            return try repository.checkout(ref)
        }
        record.ref = ref
        record.commit = commit
        record.depth = Self.initialDepth
        record.rawPrefix = rawPrefix
        record.checkedOutAt = .now
        index.save(record)
        await documents.clonesChanged()
    }

    /// Pull to refresh on a cloned file: fetches the branch or tag's latest commit (as much
    /// history as before) and checks it out. Returns whether anything changed.
    @discardableResult
    func pull(projectID: String) async throws -> Bool {
        guard var record = index.record(forProject: projectID) else { throw CloneError.notCloned }
        let folder = index.folder(of: record)
        let token = await GitHubAuth.shared.token()
        let ref = record.ref
        let depth = record.depth
        let commit = try await serially(projectID) {
            let repository = try GitRepository(at: folder)
            try repository.fetch(ref, depth: depth, token: token, isCancelled: { Task.isCancelled })
            return try repository.checkout(ref)
        }
        guard commit != record.commit else { return false }
        record.commit = commit
        record.checkedOutAt = .now
        index.save(record)
        await documents.clonesChanged()
        return true
    }

    // MARK: History

    /// The commits that changed a file (its path in the repository), newest first.
    func history(projectID: String, path: String, limit: Int = 500) async throws -> GitFileHistory {
        guard let record = index.record(forProject: projectID) else { throw CloneError.notCloned }
        let folder = index.folder(of: record)
        return try await serially(projectID) {
            try GitRepository(at: folder).history(of: path, limit: limit)
        }
    }

    /// Fetches `deepenStep` more commits of the checked-out branch or tag.
    func loadMoreHistory(projectID: String) async throws {
        guard var record = index.record(forProject: projectID), let depth = record.depth else { return }
        let folder = index.folder(of: record)
        let token = await GitHubAuth.shared.token()
        let deeper = depth + Self.deepenStep
        let ref = record.ref
        try await serially(projectID) {
            try GitRepository(at: folder).fetch(ref, depth: deeper, token: token, isCancelled: { Task.isCancelled })
        }
        record.depth = deeper
        index.save(record)
    }

    func changes(projectID: String, commit: String) async throws -> [GitChange] {
        guard let record = index.record(forProject: projectID) else { throw CloneError.notCloned }
        let folder = index.folder(of: record)
        return try await serially(projectID) { try GitRepository(at: folder).changes(in: commit) }
    }

    func patch(projectID: String, commit: String, path: String) async throws -> String {
        guard let record = index.record(forProject: projectID) else { throw CloneError.notCloned }
        let folder = index.folder(of: record)
        return try await serially(projectID) { try GitRepository(at: folder).patch(in: commit, path: path) }
    }

    // MARK: Running

    /// Runs `work` off the main thread after the project's previous operation has finished.
    private func serially<Result: Sendable>(_ projectID: String,
                                            _ work: @escaping @Sendable () throws -> Result) async throws -> Result {
        let previous = running[projectID]
        let task = Task.detached(priority: .userInitiated) { () -> Swift.Result<Result, any Error> in
            await previous?.value
            return Swift.Result { try work() }
        }
        running[projectID] = Task { _ = await task.value }
        return try await withTaskCancellationHandler {
            try await task.value.get()
        } onCancel: {
            task.cancel()
        }
    }
}
