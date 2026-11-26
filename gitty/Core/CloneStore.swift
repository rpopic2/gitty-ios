import CryptoKit
import Foundation
import Observation

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
    /// Set on clones made when a clone could check out only the project's filtered files (an
    /// option since removed): their other files are checked out once, by `restoreAllFiles()`.
    var scope: LegacyCloneScope? = nil
    /// The remote's branches and tags, listed (not downloaded) when cloning and on each fetch:
    /// the project's branch menu, without GitHub's API.
    var remoteRefs: ProjectRefs? = nil
    /// Fetched (pull down in the project), not checked out yet: how many commits newer than
    /// `commit` the branch is. Pull checks them out.
    var newCommits: Int? = nil
    /// A folder on this device (`ProjectSource.local`): not a clone of gitty's, but read the
    /// same way, from where it is. gitty never deletes it, and never fetches into it.
    var localFolder: LocalFolder? = nil
    /// A local folder's files when it was last read (`LocalFiles.signature`): a refresh that
    /// finds the same changes nothing.
    var localSignature: String? = nil

    var isLocal: Bool { localFolder != nil }
}

/// What a filtered clone (an option since removed) recorded: only that it was one.
nonisolated struct LegacyCloneScope: Codable, Equatable, Sendable {}

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

    /// The clone's folder: its working tree, with `.git` inside. A local folder's is where it
    /// is on this device.
    func folder(of record: CloneRecord) -> URL {
        if let local = record.localFolder {
            return LocalFolderAccess.shared.url(of: local)
                ?? directory.appending(path: "unreachable-\(local.id.uuidString)", directoryHint: .isDirectory)
        }
        return directory.appending(path: record.folderName, directoryHint: .isDirectory)
    }

    /// Whether the project has Git's history (a local folder may be a plain folder).
    func isRepository(_ record: CloneRecord) -> Bool {
        guard record.isLocal else { return true }
        return FileManager.default.fileExists(atPath: folder(of: record).appending(path: ".git").path)
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
    /// Settings. Goes through every file: call it off the main thread. (Local folders aren't
    /// gitty's to count.)
    func storageUsage() -> (count: Int, bytes: Int64) {
        let records = allRecords().filter { !$0.isLocal }
        return (records.count, records.reduce(0) { $0 + bytes(of: $1) })
    }

    /// The space one clone takes: its files and Git's data. Off the main thread.
    func bytes(of record: CloneRecord) -> Int64 {
        guard !record.isLocal else { return 0 }
        var bytes: Int64 = 0
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .totalFileAllocatedSizeKey]
        let enumerator = FileManager.default.enumerator(at: folder(of: record), includingPropertiesForKeys: Array(keys))
        while let file = enumerator?.nextObject() as? URL {
            guard let values = try? file.resourceValues(forKeys: keys), values.isRegularFile == true else { continue }
            bytes += Int64(values.totalFileAllocatedSize ?? 0)
        }
        return bytes
    }

    /// Every file in the clones, as saved documents (for the project's symbols, and the saved
    /// marks in the Project tab).
    func allFiles() -> [DocumentMetadata] {
        allRecords().flatMap { files(of: $0) }
    }

    /// A clone's files, in Git's order (`GitRepository.checkedOutFilePaths`): listed once per
    /// checkout.
    func files(of record: CloneRecord) -> [DocumentMetadata] {
        if let list = lock.withLock({ fileLists[record.projectID] }) { return list }
        let root = folder(of: record)
        // A local folder: what's there now (not just what's committed), less what Git ignores.
        let paths = record.isLocal
            ? LocalFiles.list(at: root, repository: try? GitRepository(at: root)).map(\.path)
            : (try? GitRepository(at: root).checkedOutFilePaths()) ?? walk(root)
        var list: [DocumentMetadata] = []
        list.reserveCapacity(paths.count)
        for path in paths {
            let encoded = path.split(separator: "/")
                .map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }
                .joined(separator: "/")
            guard let url = URL(string: record.rawPrefix + encoded) else { continue }
            list.append(metadata(url, record))
        }
        lock.withLock { fileLists[record.projectID] = list }
        return list
    }

    /// The files in a clone's folder, if Git couldn't say (in no particular order).
    private func walk(_ root: URL) -> [String] {
        let rootPath = root.standardizedFileURL.path + "/"
        var paths: [String] = []
        let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsPackageDescendants])
        while let file = enumerator?.nextObject() as? URL {
            if file.lastPathComponent == ".git" {
                enumerator?.skipDescendants()
                continue
            }
            guard (try? file.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            paths.append(String(file.standardizedFileURL.path.dropFirst(rootPath.count)))
        }
        return paths.sorted()
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
    /// The downloaded history doesn't go back far enough (to where two branches split).
    case historyTooShort
    /// The branch or tag checked out isn't on GitHub any more (what was downloaded stays).
    case deletedOnRemote(String)

    var errorDescription: String? {
        switch self {
        case .notABranchOrTag(let ref):
            "“\(ref)” isn’t a branch or tag. Choose a branch or tag to clone."
        case .notCloned:
            "This project isn’t cloned."
        case .notFetched(let ref):
            "“\(ref)” isn’t downloaded. Pull it to read it."
        case .historyTooShort:
            "The downloaded history doesn’t go back to where they split. Load more history to compare them."
        case .deletedOnRemote(let ref):
            "“\(ref)” was deleted on GitHub. You can keep reading it here, or switch to another branch."
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
    /// How many more commits a comparison's Load More History fetches.
    static let deepenStep = 100
    /// How many older commits a history's Fetch Older fetches: few, so it's quick (each one
    /// brings the files it changed).
    static let historyStep = 10

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
    /// - Parameter progress: how far the download has got.
    func clone(_ project: ProjectInfo, progress: @escaping @Sendable (FetchProgress) -> Void) async throws {
        guard let refName = project.ref, let link = project.link else { throw CloneError.notABranchOrTag("") }
        guard let remote = URL(string: "https://github.com/\(link.owner)/\(link.repo).git"),
              let rawPrefix = project.rawURL(for: "")?.absoluteString
        else { throw CloneError.notABranchOrTag(refName) }
        let token = await GitHubAuth.shared.token()
        let folderName = CloneIndex.folderName(for: project.id)
        let folder = index.directory.appending(path: folderName, directoryHint: .isDirectory)
        let depth = Self.initialDepth

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
                return (ref, refs, try repository.checkout(ref, progress: Self.checkingOut(progress)))
            } catch {
                try? FileManager.default.removeItem(at: folder)
                throw error
            }
        }
        await documents.deleteDownloads(under: rawPrefix)
        index.save(CloneRecord(projectID: project.id, ref: ref, commit: commit, depth: Self.initialDepth,
                               rawPrefix: rawPrefix, checkedOutAt: .now, folderName: folderName,
                               remoteRefs: refs))
        await documents.clonesChanged()
    }

    /// Deletes the clone. The project's files download one by one again when opened. A local
    /// folder is only forgotten: it's yours, and stays where it is.
    func delete(projectID: String) async {
        guard let record = index.record(forProject: projectID) else { return }
        if !record.isLocal {
            let folder = index.folder(of: record)
            try? await serially(projectID) { try? FileManager.default.removeItem(at: folder) }
        }
        index.remove(projectID: projectID)
        await documents.clonesChanged()
    }

    // MARK: Local folders

    /// A local folder just added as a project: read from where it is, from now on.
    func addLocal(_ project: ProjectInfo) async throws {
        guard let local = project.localFolder, let rawPrefix = project.rawURL(for: "")?.absoluteString else { return }
        guard let root = LocalFolderAccess.shared.url(of: local) else { throw LocalFolderError.unreachable(local.name) }
        let (branch, commit, refs, signature) = try await serially(project.id) { () -> (String?, String?, ProjectRefs?, String) in
            let repository = try? GitRepository(at: root)
            let head = repository?.head()
            let items = LocalFiles.list(at: root, repository: repository)
            return (head?.branch, head?.commit, repository?.allRefs(), LocalFiles.signature(of: items))
        }
        index.save(CloneRecord(projectID: project.id, ref: .branch(branch ?? ""), commit: commit ?? "", depth: nil,
                               rawPrefix: rawPrefix, checkedOutAt: .now, folderName: "", remoteRefs: refs,
                               localFolder: local, localSignature: signature))
        await documents.clonesChanged()
    }

    /// Reads a local folder again (pull down, Refresh, or coming back to the app): its files, its
    /// branch and its branches. Returns whether anything changed.
    @discardableResult
    func refreshLocal(projectID: String) async throws -> Bool {
        guard var record = index.record(forProject: projectID), let local = record.localFolder else { return false }
        guard let root = LocalFolderAccess.shared.url(of: local) else { throw LocalFolderError.unreachable(local.name) }
        let (branch, commit, refs, signature) = try await serially(projectID) { () -> (String?, String?, ProjectRefs?, String) in
            let repository = try? GitRepository(at: root)
            let head = repository?.head()
            let items = LocalFiles.list(at: root, repository: repository)
            return (head?.branch, head?.commit, repository?.allRefs(), LocalFiles.signature(of: items))
        }
        let ref = GitRef.branch(branch ?? "")
        guard signature != record.localSignature || ref != record.ref || (commit ?? "") != record.commit
                || refs != record.remoteRefs
        else { return false }
        record.ref = ref
        record.commit = commit ?? ""
        record.remoteRefs = refs
        record.localSignature = signature
        record.checkedOutAt = .now
        index.save(record)  // its file list is read again
        await documents.clonesChanged()
        return true
    }

    /// Every local folder read again (coming back to the app): the ones that changed.
    func refreshLocalFolders() async -> [String] {
        var changed: [String] = []
        for record in index.allRecords() where record.isLocal {
            if (try? await refreshLocal(projectID: record.projectID)) == true { changed.append(record.projectID) }
        }
        return changed
    }

    /// A local folder's file list as it is now.
    private func localTree(_ record: CloneRecord) async throws -> ProjectTree {
        let root = index.folder(of: record)
        guard FileManager.default.fileExists(atPath: root.path) else {
            throw LocalFolderError.unreachable(record.localFolder?.name ?? "")
        }
        return try await serially(record.projectID) {
            LocalFiles.tree(of: LocalFiles.list(at: root, repository: try? GitRepository(at: root)))
        }
    }

    /// Switches the clone to another branch or tag, and returns its file list (from the clone).
    /// One it has downloaded before is just checked out, offline, as it was fetched then; one it
    /// hasn't is downloaded (its latest commit) only when `pulling`, otherwise it throws
    /// `CloneError.notFetched`.
    /// - Parameter rawPrefix: the project's raw file address at the new ref.
    @discardableResult
    func switchTo(_ ref: GitRef, projectID: String, rawPrefix: String, pulling: Bool = false,
                  progress: @escaping @Sendable (FetchProgress) -> Void = { _ in }) async throws -> ProjectTree {
        guard var record = index.record(forProject: projectID) else { throw CloneError.notCloned }
        let folder = index.folder(of: record)
        // A local folder: checked out in it, like `git checkout` (refused over uncommitted changes).
        if record.isLocal {
            let (branch, commit) = try await serially(projectID) { try GitRepository(at: folder).switchWorkingTree(to: ref) }
            record.ref = .branch(branch ?? ref.name)
            record.commit = commit
            record.localSignature = nil
            record.checkedOutAt = .now
            index.save(record)
            await documents.clonesChanged()
            return try await localTree(record)
        }
        let token = pulling ? await GitHubAuth.shared.token() : nil
        let depth = Self.initialDepth
        let (commit, tree, fetched) = try await serially(projectID) { () throws -> (String, ProjectTree, Bool) in
            let repository = try GitRepository(at: folder)
            var fetched = false
            if repository.fetchedCommit(of: ref) == nil {
                guard pulling else { throw CloneError.notFetched(ref.name) }
                try repository.fetch(ref, depth: depth, token: token, progress: progress, isCancelled: { Task.isCancelled })
                fetched = true
            }
            let commit = try repository.checkout(ref, progress: fetched ? Self.checkingOut(progress) : nil)
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
        if record.isLocal { return try await localTree(record) }
        let folder = index.folder(of: record)
        let ref = record.ref
        return try await serially(projectID) { try GitRepository(at: folder).tree(of: ref) }
    }

    /// The branches and tags the clone has downloaded (by name), for the branch menu: from the
    /// clone's own refs. (From the remote's list, a clone made before it was kept had none: every
    /// branch asked to be pulled again, even one pulled a minute before.)
    func fetchedRefs(projectID: String) async -> Set<String> {
        guard let record = index.record(forProject: projectID) else { return [] }
        // A local folder has every branch it lists: none to pull.
        if record.isLocal, let refs = record.remoteRefs { return Set(refs.branches + refs.tags) }
        let folder = index.folder(of: record)
        return (try? await serially(projectID) { () throws -> Set<String> in
            try GitRepository(at: folder).fetchedRefNames()
        }) ?? []
    }

    /// Fetch in the branch picker: the remote's branches and tags listed again, and the
    /// downloaded ones it doesn't have any more deleted (except the one checked out). Nothing
    /// is downloaded.
    @discardableResult
    func refreshRefs(projectID: String) async throws -> ProjectRefs {
        guard let record = index.record(forProject: projectID) else { throw CloneError.notCloned }
        // A local folder: its own branches, from its `.git` (nothing from the network).
        if record.isLocal {
            try await refreshLocal(projectID: projectID)
            return index.record(forProject: projectID)?.remoteRefs ?? ProjectRefs(branches: [], tags: [])
        }
        let folder = index.folder(of: record)
        let token = await GitHubAuth.shared.token()
        let ref = record.ref
        let refs = try await serially(projectID) { () throws -> ProjectRefs in
            let repository = try GitRepository(at: folder)
            let refs = try repository.remoteRefs(token: token)
            repository.pruneRefs(notIn: refs, keeping: ref)
            return refs
        }
        if var latest = index.record(forProject: projectID) {
            latest.remoteRefs = refs
            index.save(latest)
        }
        return refs
    }

    /// Pull down in the project: lists the remote's branches and tags again, deletes the
    /// downloaded ones it doesn't have any more (like `git fetch --prune`, except the one checked
    /// out), and downloads the branch or tag's latest commits (as much history as before) without
    /// checking them out. Returns how many commits are new (`newCommits`); Pull checks them out.
    /// - Throws: `CloneError.deletedOnRemote` when the one checked out is gone from GitHub
    ///   (nothing to fetch; the remote's list is saved all the same).
    @discardableResult
    func fetch(projectID: String, progress: @escaping @Sendable (FetchProgress) -> Void = { _ in }) async throws -> Int {
        guard var record = index.record(forProject: projectID) else { throw CloneError.notCloned }
        if record.isLocal {  // read again, from the folder
            try await refreshLocal(projectID: projectID)
            return 0
        }
        let folder = index.folder(of: record)
        let token = await GitHubAuth.shared.token()
        let ref = record.ref
        let depth = record.depth
        let checkedOut = record.commit
        let (refs, newCommits) = try await serially(projectID) { () throws -> (ProjectRefs?, Int?) in
            let repository = try GitRepository(at: folder)
            // Listed first: offline or refused, the fetch below fails as before, and nothing is pruned.
            let refs = try? repository.remoteRefs(token: token)
            if let refs {
                repository.pruneRefs(notIn: refs, keeping: ref)
                let names: [String]
                switch ref {
                case .branch: names = refs.branches
                case .tag: names = refs.tags
                }
                if !names.contains(ref.name) { return (refs, nil) }
            }
            try repository.fetch(ref, depth: depth, token: token, progress: progress, isCancelled: { Task.isCancelled })
            let latest = repository.fetchedCommit(of: ref) ?? checkedOut
            return (refs, latest == checkedOut ? 0 : max(1, repository.commitsAhead(latest, of: checkedOut)))
        }
        if let refs { record.remoteRefs = refs }
        record.newCommits = newCommits ?? 0
        index.save(record)
        guard let newCommits else { throw CloneError.deletedOnRemote(ref.name) }
        return newCommits
    }

    /// Pull to refresh on a cloned file: fetches the branch or tag's latest commit (as much
    /// history as before) and checks it out. Returns whether anything changed.
    @discardableResult
    func pull(projectID: String, progress: @escaping @Sendable (FetchProgress) -> Void = { _ in }) async throws -> Bool {
        guard var record = index.record(forProject: projectID) else { throw CloneError.notCloned }
        // A local folder: read again from the folder, its edits too.
        if record.isLocal { return try await refreshLocal(projectID: projectID) }
        let folder = index.folder(of: record)
        let token = await GitHubAuth.shared.token()
        let ref = record.ref
        let depth = record.depth
        let commit = try await serially(projectID) {
            let repository = try GitRepository(at: folder)
            try repository.fetch(ref, depth: depth, token: token, progress: progress, isCancelled: { Task.isCancelled })
            return try repository.checkout(ref, progress: Self.checkingOut(progress))
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

    /// A checkout's progress, reported as a download's last phase.
    private static func checkingOut(_ progress: @escaping @Sendable (FetchProgress) -> Void) -> @Sendable (Double) -> Void {
        { fraction in progress(FetchProgress(fraction: fraction, receivedBytes: 0, phase: .checkingOut)) }
    }

    /// Roughly what fetching `ref`'s latest commit downloads: the size of its files the clone
    /// doesn't have yet, before Git compresses them. From GitHub's file list for the commit (one
    /// request); `nil` when that fails or is cut short (a very large repository).
    func downloadEstimate(of ref: GitRef, projectID: String) async -> Int64? {
        guard let record = index.record(forProject: projectID), !record.isLocal,
              let tree = try? await ProjectStore.shared.remoteTree(for: projectID, ref: ref.name),
              !tree.truncated
        else { return nil }
        let folder = index.folder(of: record)
        return try? await serially(projectID) { try GitRepository(at: folder).missingBytes(of: tree.entries) }
    }

    /// Clones made with only the filtered files checked out (an option since removed) get the
    /// rest of their files, from what's already downloaded (no network).
    func restoreAllFiles() async {
        var restored = false
        for var record in index.allRecords() where record.scope != nil {
            let folder = index.folder(of: record)
            guard (try? await serially(record.projectID, { try GitRepository(at: folder).checkOutHeadAgain() })) != nil
            else { continue }
            record.scope = nil
            record.checkedOutAt = .now  // the files changed: index them again
            index.save(record)
            restored = true
        }
        if restored { await documents.clonesChanged() }
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

    /// Fetches `historyStep` older commits of the checked-out branch or tag (only when asked:
    /// the history shows what's in the clone, offline). Cancelled with its task.
    func loadMoreHistory(projectID: String,
                         progress: @escaping @Sendable (FetchProgress) -> Void = { _ in }) async throws {
        guard var record = index.record(forProject: projectID), !record.isLocal, let depth = record.depth else { return }
        let folder = index.folder(of: record)
        let token = await GitHubAuth.shared.token()
        let deeper = depth + Self.historyStep
        let ref = record.ref
        try await serially(projectID) {
            try GitRepository(at: folder).fetch(ref, depth: deeper, token: token, progress: progress,
                                                isCancelled: { Task.isCancelled })
        }
        record.depth = deeper
        index.save(record)
    }

    // MARK: Comparing

    /// Works out a comparison in the clone, offline: both sides' commits, where they split
    /// (for `.sinceSplit`) and the commits in between. Throws `CloneError.notFetched` for a side
    /// it doesn't have, and `.historyTooShort` when where they split isn't downloaded.
    func compare(_ comparison: GitComparison, projectID: String) async throws -> ResolvedComparison {
        guard let record = index.record(forProject: projectID) else { throw CloneError.notCloned }
        let folder = index.folder(of: record)
        return try await serially(projectID) { () throws -> ResolvedComparison in
            let repository = try GitRepository(at: folder)
            guard let base = repository.resolve(comparison.base) else {
                throw CloneError.notFetched(comparison.base.label)
            }
            guard let head = repository.resolve(comparison.head) else {
                throw CloneError.notFetched(comparison.head.label)
            }
            let split = repository.mergeBase(base, head)
            let before: String
            switch comparison.mode {
            case .sinceSplit:
                guard let split else { throw CloneError.historyTooShort }
                before = split
            case .direct:
                before = base
            }
            let (commits, hasMore) = try repository.commits(from: split ?? base, to: head, limit: 200)
            return ResolvedComparison(comparison: comparison, before: before, after: head,
                                      afterCommit: try repository.commit(head), commits: commits,
                                      hasMoreCommits: hasMore)
        }
    }

    /// The files that differ from one commit to another.
    func changes(projectID: String, from before: String, to after: String) async throws -> [GitChange] {
        guard let record = index.record(forProject: projectID) else { throw CloneError.notCloned }
        let folder = index.folder(of: record)
        return try await serially(projectID) { try GitRepository(at: folder).changes(from: before, to: after) }
    }

    /// - Parameter wholeFile: every line of the file around the changes, not just 3.
    func patch(projectID: String, from before: String, to after: String, path: String,
               wholeFile: Bool = false) async throws -> String {
        guard let record = index.record(forProject: projectID) else { throw CloneError.notCloned }
        let folder = index.folder(of: record)
        return try await serially(projectID) {
            try GitRepository(at: folder).patch(from: before, to: after, path: path, wholeFile: wholeFile)
        }
    }

    /// Downloads a branch or tag into the clone (its latest commit), without checking it out:
    /// a comparison's side that wasn't there.
    func fetchRef(_ ref: GitRef, projectID: String) async throws {
        guard let record = index.record(forProject: projectID) else { throw CloneError.notCloned }
        if record.isLocal { throw CloneError.notFetched(ref.name) }  // a local folder has what it has
        let folder = index.folder(of: record)
        let token = await GitHubAuth.shared.token()
        let depth = Self.initialDepth
        try await serially(projectID) {
            try GitRepository(at: folder).fetch(ref, depth: depth, token: token, isCancelled: { Task.isCancelled })
        }
    }

    /// More history for a comparison's branches and tags (and the checked-out one), so where
    /// they split can be found.
    func loadMoreHistory(for refs: [GitRef], projectID: String) async throws {
        guard var record = index.record(forProject: projectID), !record.isLocal else { return }
        let folder = index.folder(of: record)
        let token = await GitHubAuth.shared.token()
        // A clone with all its history (no depth) gets all of theirs too.
        let deeper = record.depth.map { $0 + Self.deepenStep }
        let all = Array(Set(refs + [record.ref]))
        try await serially(projectID) {
            let repository = try GitRepository(at: folder)
            for ref in all {
                try repository.fetch(ref, depth: deeper, token: token, isCancelled: { Task.isCancelled })
            }
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

    /// - Parameter wholeFile: every line of the file around the changes, not just 3.
    func patch(projectID: String, commit: String, path: String, wholeFile: Bool = false) async throws -> String {
        guard let record = index.record(forProject: projectID) else { throw CloneError.notCloned }
        let folder = index.folder(of: record)
        return try await serially(projectID) {
            try GitRepository(at: folder).patch(in: commit, path: path, wholeFile: wholeFile)
        }
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

/// Pulls and fetches made in Project, for the Code level showing the project to follow: a pull
/// changes the checked-out files, and a fetch moves the branches a comparison's diff album
/// follows. Counted per project.
@MainActor @Observable
final class CloneChanges {
    static let shared = CloneChanges()

    private(set) var pulls: [String: Int] = [:]
    private(set) var fetches: [String: Int] = [:]

    func didPull(_ projectID: String) {
        pulls[projectID, default: 0] += 1
    }

    func didFetch(_ projectID: String) {
        fetches[projectID, default: 0] += 1
    }
}
