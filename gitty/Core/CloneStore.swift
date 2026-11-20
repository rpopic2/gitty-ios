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
    /// Cloned with only the project's files checked out (`nil`: every file of the repository).
    var scope: CloneScope? = nil
    /// The remote's branches and tags, listed (not downloaded) when cloning and on each fetch:
    /// the project's branch menu, without GitHub's API.
    var remoteRefs: ProjectRefs? = nil
    /// Fetched (pull down in the project), not checked out yet: how many commits newer than
    /// `commit` the branch is. Pull checks them out.
    var newCommits: Int? = nil
}

/// A clone that keeps only the project's files on disk: those in its folder that its filter
/// lets through (the filter as it was at the last checkout). Git still downloads every file
/// (libgit2 can't leave any out of a fetch), but the others aren't written out.
nonisolated struct CloneScope: Codable, Equatable, Sendable {
    /// The project's folder in the repository ("" for all of it).
    let folder: String
    /// The project's filter (`FileFilter`'s text).
    let filter: String

    /// Whether a file (its path in the repository) is checked out.
    var includes: @Sendable (String) -> Bool {
        let prefix = folder.isEmpty ? "" : folder + "/"
        let filter = FileFilter(filter)
        return { path in
            guard path.hasPrefix(prefix) else { return false }
            return filter.matches(String(path.dropFirst(prefix.count)))
        }
    }

    init(folder: String, filter: String) {
        self.folder = folder
        self.filter = filter
    }

    /// For a project, with its filter now.
    init(project: ProjectInfo, filter: String) {
        self.init(folder: (project.folder ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/")),
                  filter: filter)
    }
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
    /// The clone hasn't downloaded this branch or tag: pull it first.
    case notFetched(String)

    var errorDescription: String? {
        switch self {
        case .notABranchOrTag(let ref):
            "“\(ref)” isn’t a branch or tag. Choose a branch or tag to clone."
        case .notCloned:
            "This project isn’t cloned."
        case .notFetched(let ref):
            "“\(ref)” isn’t downloaded. Pull it to read it."
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
    /// - Parameters:
    ///   - filtered: check out only the project's files (see `CloneScope`), following its
    ///     filter from then on.
    ///   - progress: the fraction of objects received.
    func clone(_ project: ProjectInfo, filtered: Bool = false,
               progress: @escaping @Sendable (Double) -> Void) async throws {
        guard let refName = project.ref else { throw CloneError.notABranchOrTag("") }
        guard let remote = URL(string: "https://github.com/\(project.link.owner)/\(project.link.repo).git"),
              let rawPrefix = project.rawURL(for: "")?.absoluteString
        else { throw CloneError.notABranchOrTag(refName) }
        let token = await GitHubAuth.shared.token()
        let folderName = CloneIndex.folderName(for: project.id)
        let folder = index.directory.appending(path: folderName, directoryHint: .isDirectory)
        let depth = Self.initialDepth
        let scope = filtered ? CloneScope(project: project, filter: ProjectFilterStore.standard.text(for: project.id)) : nil
        let includes = scope?.includes

        // The remote's branches and tags, from Git itself: whether the project's is a branch
        // or a tag, and the branch menu from now on.
        let (ref, refs, commit) = try await serially(project.id) { () throws -> (GitRef, ProjectRefs, String) in
            try? FileManager.default.removeItem(at: folder)  // a clone that didn't finish
            do {
                let repository = try GitRepository.create(at: folder, remote: remote)
                let refs = try repository.remoteRefs(token: token)
                let ref: GitRef
                if refs.branches.contains(refName) {
                    ref = .branch(refName)
                } else if refs.tags.contains(refName) {
                    ref = .tag(refName)
                } else {
                    throw CloneError.notABranchOrTag(refName)
                }
                try repository.fetch(ref, depth: depth, token: token, progress: progress,
                                     isCancelled: { Task.isCancelled })
                return (ref, refs, try repository.checkout(ref, including: includes))
            } catch {
                try? FileManager.default.removeItem(at: folder)
                throw error
            }
        }
        await documents.deleteDownloads(under: rawPrefix)
        index.save(CloneRecord(projectID: project.id, ref: ref, commit: commit, depth: Self.initialDepth,
                               rawPrefix: rawPrefix, checkedOutAt: .now, folderName: folderName, scope: scope,
                               remoteRefs: refs))
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

    /// Switches the clone to another branch or tag, and returns its file list (from the clone).
    /// One it has downloaded before is just checked out, offline, as it was fetched then; one it
    /// hasn't is downloaded (its latest commit) only when `pulling`, otherwise it throws
    /// `CloneError.notFetched`.
    /// - Parameter rawPrefix: the project's raw file address at the new ref.
    @discardableResult
    func switchTo(_ ref: GitRef, projectID: String, rawPrefix: String, pulling: Bool = false) async throws -> ProjectTree {
        guard var record = index.record(forProject: projectID) else { throw CloneError.notCloned }
        let folder = index.folder(of: record)
        let token = pulling ? await GitHubAuth.shared.token() : nil
        let depth = Self.initialDepth
        let includes = record.scope?.includes
        let (commit, tree, fetched) = try await serially(projectID) { () throws -> (String, ProjectTree, Bool) in
            let repository = try GitRepository(at: folder)
            var fetched = false
            if repository.fetchedCommit(of: ref) == nil {
                guard pulling else { throw CloneError.notFetched(ref.name) }
                try repository.fetch(ref, depth: depth, token: token, isCancelled: { Task.isCancelled })
                fetched = true
            }
            let commit = try repository.checkout(ref, including: includes)
            return (commit, try repository.tree(of: ref), fetched)
        }
        record.ref = ref
        record.commit = commit
        if fetched { record.depth = Self.initialDepth }
        record.newCommits = nil
        record.rawPrefix = rawPrefix
        record.checkedOutAt = .now
        index.save(record)
        await documents.clonesChanged()
        return tree
    }

    /// The file list at the clone's branch or tag, from the clone.
    func tree(projectID: String) async throws -> ProjectTree {
        guard let record = index.record(forProject: projectID) else { throw CloneError.notCloned }
        let folder = index.folder(of: record)
        let ref = record.ref
        return try await serially(projectID) { try GitRepository(at: folder).tree(of: ref) }
    }

    /// Whether the clone has downloaded these branches and tags (by name), for the branch menu.
    func fetchedRefs(projectID: String) async -> Set<String> {
        guard let record = index.record(forProject: projectID), let refs = record.remoteRefs else { return [] }
        let folder = index.folder(of: record)
        return (try? await serially(projectID) { () throws -> Set<String> in
            let repository = try GitRepository(at: folder)
            let all = refs.branches.map(GitRef.branch) + refs.tags.map(GitRef.tag)
            return Set(all.filter { repository.fetchedCommit(of: $0) != nil }.map(\.name))
        }) ?? []
    }

    /// Pull down in the project: downloads the branch or tag's latest commits (as much history as
    /// before) without checking them out, and lists the remote's branches and tags again.
    /// Returns how many commits are new (`newCommits`); Pull checks them out.
    @discardableResult
    func fetch(projectID: String) async throws -> Int {
        guard var record = index.record(forProject: projectID) else { throw CloneError.notCloned }
        let folder = index.folder(of: record)
        let token = await GitHubAuth.shared.token()
        let ref = record.ref
        let depth = record.depth
        let checkedOut = record.commit
        let (refs, newCommits) = try await serially(projectID) { () throws -> (ProjectRefs?, Int) in
            let repository = try GitRepository(at: folder)
            try repository.fetch(ref, depth: depth, token: token, isCancelled: { Task.isCancelled })
            let refs = try? repository.remoteRefs(token: token)
            let latest = repository.fetchedCommit(of: ref) ?? checkedOut
            return (refs, latest == checkedOut ? 0 : max(1, repository.commitsAhead(latest, of: checkedOut)))
        }
        if let refs { record.remoteRefs = refs }
        record.newCommits = newCommits
        index.save(record)
        return newCommits
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
        let includes = record.scope?.includes
        let commit = try await serially(projectID) {
            let repository = try GitRepository(at: folder)
            try repository.fetch(ref, depth: depth, token: token, isCancelled: { Task.isCancelled })
            return try repository.checkout(ref, including: includes)
        }
        record.newCommits = nil
        guard commit != record.commit else {
            index.save(record)
            return false
        }
        record.commit = commit
        record.checkedOutAt = .now
        index.save(record)
        await documents.clonesChanged()
        return true
    }

    /// The project's filter changed: a clone of only the project's files checks out the files
    /// it lets through now (from what's already downloaded, no network). Returns whether it did.
    @discardableResult
    func applyFilter(_ filter: String, projectID: String) async throws -> Bool {
        guard var record = index.record(forProject: projectID), let scope = record.scope,
              scope.filter != filter
        else { return false }
        let newScope = CloneScope(folder: scope.folder, filter: filter)
        let folder = index.folder(of: record)
        let ref = record.ref
        let includes = newScope.includes
        _ = try await serially(projectID) {
            try GitRepository(at: folder).checkout(ref, including: includes)
        }
        record.scope = newScope
        record.checkedOutAt = .now  // the files changed: index them again
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

    /// The checked-out branch or tag's commits, newest first.
    func log(projectID: String, limit: Int) async throws -> GitFileHistory {
        guard let record = index.record(forProject: projectID) else { throw CloneError.notCloned }
        let folder = index.folder(of: record)
        return try await serially(projectID) {
            try GitRepository(at: folder).log(limit: limit)
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

    /// Who last changed each run of a file's lines (its path in the repository), at the
    /// checked-out commit.
    func blame(projectID: String, path: String) async throws -> [GitBlameHunk] {
        guard let record = index.record(forProject: projectID) else { throw CloneError.notCloned }
        let folder = index.folder(of: record)
        return try await serially(projectID) { try GitRepository(at: folder).blame(of: path) }
    }

    func commit(projectID: String, id: String) async throws -> GitCommit {
        guard let record = index.record(forProject: projectID) else { throw CloneError.notCloned }
        let folder = index.folder(of: record)
        return try await serially(projectID) { try GitRepository(at: folder).commit(id) }
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
