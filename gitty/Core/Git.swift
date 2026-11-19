import Foundation
import libgit2

/// A thin Swift layer over libgit2's C API: just what gitty needs to keep a shallow clone of a
/// project, switch it between branches and tags, and read a file's history and diffs.
///
/// Every call blocks while libgit2 works (on the network for `fetch`), so call these off the
/// main thread (`CloneStore` does). A `GitRepository` is used from one task at a time.

nonisolated struct GitError: LocalizedError, Equatable, Sendable {
    let message: String
    /// libgit2's error code (`GIT_EAUTH` and so on).
    let code: Int32

    var errorDescription: String? { message }

    var isAuthentication: Bool { code == GIT_EAUTH.rawValue }
}

/// A branch or a tag on the remote.
nonisolated enum GitRef: Hashable, Codable, Sendable {
    case branch(String)
    case tag(String)

    var name: String {
        switch self {
        case .branch(let name), .tag(let name): name
        }
    }

    /// Fetches just this ref.
    fileprivate var refspec: String {
        switch self {
        case .branch(let name): "+refs/heads/\(name):refs/remotes/origin/\(name)"
        case .tag(let name): "+refs/tags/\(name):refs/tags/\(name)"
        }
    }

    /// Where the fetched ref is kept in the clone.
    fileprivate var localReference: String {
        switch self {
        case .branch(let name): "refs/remotes/origin/\(name)"
        case .tag(let name): "refs/tags/\(name)"
        }
    }
}

nonisolated struct GitCommit: Identifiable, Hashable, Sendable {
    /// The full hash.
    let id: String
    let summary: String
    let message: String
    let author: String
    let email: String
    let date: Date
    /// The oldest commit downloaded in a shallow clone: whether it changed the file isn't
    /// known (its parent isn't there), only that the file was in it.
    var isBoundary = false

    var shortID: String { String(id.prefix(7)) }
}

/// One file changed by a commit.
nonisolated struct GitChange: Identifiable, Hashable, Sendable {
    enum Kind: String, Sendable {
        case added, deleted, modified, renamed, copied, typeChanged
    }

    /// The path after the commit (before it, for a deleted file).
    let path: String
    /// The path before, when it was renamed or copied.
    let oldPath: String?
    let kind: Kind

    var id: String { path }
}

/// A file's commits, newest first.
nonisolated struct GitFileHistory: Sendable {
    let commits: [GitCommit]
    /// More can be shown: the walk stopped at the limit, or reached the start of a shallow
    /// clone (fetching more history goes further).
    let canLoadMore: Bool
}

nonisolated final class GitRepository {
    private let pointer: OpaquePointer

    private init(pointer: OpaquePointer) {
        self.pointer = pointer
    }

    deinit {
        git_repository_free(pointer)
    }

    /// Opens the clone in `directory`.
    convenience init(at directory: URL) throws {
        Git.start()
        var repository: OpaquePointer?
        try Git.check(git_repository_open(&repository, directory.path))
        self.init(pointer: repository!)
    }

    /// An empty repository in `directory` whose `origin` is `remote`, ready for `fetch`. (A
    /// clone, done in steps: libgit2's own clone would fetch every branch.)
    static func create(at directory: URL, remote: URL) throws -> GitRepository {
        Git.start()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var repository: OpaquePointer?
        try Git.check(git_repository_init(&repository, directory.path, 0))
        let created = GitRepository(pointer: repository!)
        var origin: OpaquePointer?
        try Git.check(git_remote_create_with_fetchspec(&origin, created.pointer, "origin", remote.absoluteString,
                                                       "+refs/heads/*:refs/remotes/origin/*"))
        git_remote_free(origin)
        return created
    }

    var isShallow: Bool {
        git_repository_is_shallow(pointer) == 1
    }

    // MARK: Fetching

    /// Downloads `ref` from `origin`, `depth` commits deep (`nil`: all of its history).
    /// - Parameters:
    ///   - token: a GitHub token, for private repositories (sent as the password).
    ///   - progress: the fraction of objects received, now and then.
    ///   - isCancelled: checked as data arrives; `true` stops the fetch.
    func fetch(_ ref: GitRef, depth: Int?, token: String?,
               progress: @escaping @Sendable (Double) -> Void = { _ in },
               isCancelled: @escaping @Sendable () -> Bool = { false }) throws {
        var remote: OpaquePointer?
        try Git.check(git_remote_lookup(&remote, pointer, "origin"))
        defer { git_remote_free(remote) }

        let context = FetchContext(token: token, progress: progress, isCancelled: isCancelled)
        var options = git_fetch_options()
        git_fetch_options_init(&options, UInt32(GIT_FETCH_OPTIONS_VERSION))
        options.depth = depth.map { Int32(clamping: $0) }
            ?? Int32(truncatingIfNeeded: GIT_FETCH_DEPTH_UNSHALLOW.rawValue)
        options.download_tags = GIT_REMOTE_DOWNLOAD_TAGS_NONE
        options.callbacks.payload = Unmanaged.passUnretained(context).toOpaque()
        options.callbacks.credentials = { out, _, _, allowed, payload in
            guard let payload else { return GIT_PASSTHROUGH.rawValue }
            let context = Unmanaged<FetchContext>.fromOpaque(payload).takeUnretainedValue()
            // Once only: if GitHub turns the token down, asking again would loop.
            guard let token = context.token, !context.triedToken,
                  allowed & UInt32(truncatingIfNeeded: GIT_CREDENTIAL_USERPASS_PLAINTEXT.rawValue) != 0
            else { return GIT_PASSTHROUGH.rawValue }
            context.triedToken = true
            return git_credential_userpass_plaintext_new(out, "x-access-token", token)
        }
        options.callbacks.transfer_progress = { stats, payload in
            guard let payload else { return 0 }
            let context = Unmanaged<FetchContext>.fromOpaque(payload).takeUnretainedValue()
            if context.isCancelled() { return -1 }  // stops the fetch
            if let stats = stats?.pointee, stats.total_objects > 0 {
                context.report(Double(stats.received_objects) / Double(stats.total_objects))
            }
            return 0
        }
        try withExtendedLifetime(context) {
            try Git.withStrArray([ref.refspec]) { refspecs in
                try Git.check(git_remote_fetch(remote, refspecs, &options, nil))
            }
        }
    }

    /// Puts `ref`'s files (once fetched) in the working directory, replacing what's there, and
    /// points HEAD at its commit. Returns the commit's hash.
    /// - Parameter includes: only the files it lets through (paths in the repository) are
    ///   written; the others are removed from the working directory. `nil`: every file.
    @discardableResult
    func checkout(_ ref: GitRef, including includes: (@Sendable (String) -> Bool)? = nil) throws -> String {
        var object: OpaquePointer?
        try Git.check(git_revparse_single(&object, pointer, ref.localReference + "^{commit}"))
        defer { git_object_free(object) }
        var options = git_checkout_options()
        git_checkout_options_init(&options, UInt32(GIT_CHECKOUT_OPTIONS_VERSION))
        options.checkout_strategy = UInt32(truncatingIfNeeded: GIT_CHECKOUT_FORCE.rawValue)
        if let includes {
            let paths = try filePaths(in: object).filter(includes)
            // No paths would mean every file to libgit2.
            if !paths.isEmpty {
                options.checkout_strategy |= UInt32(truncatingIfNeeded: GIT_CHECKOUT_DISABLE_PATHSPEC_MATCH.rawValue)
                try Git.withStrArray(paths) { array in
                    options.paths = array.pointee
                    try Git.check(git_checkout_tree(pointer, object, &options))
                }
            }
            removeWorkingFiles(keeping: Set(paths))
        } else {
            try Git.check(git_checkout_tree(pointer, object, &options))
        }
        let id = git_object_id(object)
        try Git.check(git_repository_set_head_detached(pointer, id))
        return Git.string(id)
    }

    /// Every file's path in a commit's tree.
    private func filePaths(in commit: OpaquePointer?) throws -> [String] {
        var tree: OpaquePointer?
        try Git.check(git_object_peel(&tree, commit, GIT_OBJECT_TREE))
        defer { git_object_free(tree) }
        let collector = PathCollector()
        try withExtendedLifetime(collector) {
            try Git.check(git_tree_walk(tree, GIT_TREEWALK_PRE, { root, entry, payload in
                guard let entry, let payload, git_tree_entry_type(entry) == GIT_OBJECT_BLOB,
                      let name = git_tree_entry_name(entry)
                else { return 0 }
                let collector = Unmanaged<PathCollector>.fromOpaque(payload).takeUnretainedValue()
                collector.paths.append((root.map { String(cString: $0) } ?? "") + String(cString: name))
                return 0
            }, Unmanaged.passUnretained(collector).toOpaque()))
        }
        return collector.paths
    }

    /// Deletes the working directory's files that aren't in `keeping` (and the folders left
    /// empty), leaving `.git` alone.
    private func removeWorkingFiles(keeping: Set<String>) {
        guard let workdir = git_repository_workdir(pointer).map({ String(cString: $0) }) else { return }
        let root = URL(filePath: workdir, directoryHint: .isDirectory).standardizedFileURL
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        let manager = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey]
        var folders: [URL] = []
        let enumerator = manager.enumerator(at: root, includingPropertiesForKeys: keys)
        while let item = enumerator?.nextObject() as? URL {
            if item.lastPathComponent == ".git", item.deletingLastPathComponent().standardizedFileURL == root {
                enumerator?.skipDescendants()
                continue
            }
            if (try? item.resourceValues(forKeys: Set(keys)))?.isDirectory == true {
                folders.append(item)
                continue
            }
            let path = String(item.standardizedFileURL.path.dropFirst(rootPath.count))
            if !keeping.contains(path) { try? manager.removeItem(at: item) }
        }
        // Deepest first, so a folder's empty folders go before it.
        for folder in folders.sorted(by: { $0.path.count > $1.path.count }) {
            if (try? manager.contentsOfDirectory(atPath: folder.path))?.isEmpty == true {
                try? manager.removeItem(at: folder)
            }
        }
    }

    // MARK: History

    /// The commits that changed `path` (relative to the repository), newest first, looking
    /// at up to `limit` commits from HEAD. A commit counts if the file differs from its first
    /// parent's.
    func history(of path: String, limit: Int) throws -> GitFileHistory {
        var walk: OpaquePointer?
        try Git.check(git_revwalk_new(&walk, pointer))
        defer { git_revwalk_free(walk) }
        git_revwalk_sorting(walk, UInt32(truncatingIfNeeded: GIT_SORT_TIME.rawValue))
        var head = git_oid()
        try Git.check(git_reference_name_to_id(&head, pointer, "HEAD"))
        try Git.check(git_revwalk_push(walk, &head))

        var commits: [GitCommit] = []
        var looked = 0
        var reachedBoundary = false
        var id = git_oid()
        while looked < limit, git_revwalk_next(&id, walk) == 0 {
            looked += 1
            var commit: OpaquePointer?
            guard git_commit_lookup(&commit, pointer, &id) == 0 else { continue }
            defer { git_commit_free(commit) }
            let entry = entryID(of: path, in: commit)
            if git_commit_parentcount(commit) == 0 {
                guard entry != nil else { continue }
                // The first commit, or the oldest one downloaded.
                var info = Self.commit(commit)
                if isShallow {
                    info.isBoundary = true
                    reachedBoundary = true
                }
                commits.append(info)
                continue
            }
            var parent: OpaquePointer?
            let parentEntry: git_oid? = git_commit_parent(&parent, commit, 0) == 0 ? entryID(of: path, in: parent) : nil
            git_commit_free(parent)
            if !Git.same(entry, parentEntry) { commits.append(Self.commit(commit)) }
        }
        return GitFileHistory(commits: commits, canLoadMore: looked >= limit || reachedBoundary)
    }

    /// The files a commit changed, against its first parent (everything, for the first commit
    /// or a shallow clone's oldest), with renames found.
    func changes(in commitID: String) throws -> [GitChange] {
        try withDiff(of: commitID, path: nil) { diff in
            (0..<git_diff_num_deltas(diff)).compactMap { index -> GitChange? in
                guard let delta = git_diff_get_delta(diff, index)?.pointee else { return nil }
                let newPath = String(cString: delta.new_file.path)
                let oldPath = String(cString: delta.old_file.path)
                let kind: GitChange.Kind
                switch delta.status {
                case GIT_DELTA_ADDED: kind = .added
                case GIT_DELTA_DELETED: kind = .deleted
                case GIT_DELTA_RENAMED: kind = .renamed
                case GIT_DELTA_COPIED: kind = .copied
                case GIT_DELTA_TYPECHANGE: kind = .typeChanged
                default: kind = .modified
                }
                return GitChange(path: kind == .deleted ? oldPath : newPath,
                                 oldPath: kind == .renamed || kind == .copied ? oldPath : nil, kind: kind)
            }
        }
    }

    /// One file's changes in a commit, as a unified diff (`diff --git` header and hunks).
    /// Empty if the commit didn't change it.
    func patch(in commitID: String, path: String) throws -> String {
        try withDiff(of: commitID, path: path) { diff in
            var text = ""
            for index in 0..<git_diff_num_deltas(diff) {
                var patch: OpaquePointer?
                guard git_patch_from_diff(&patch, diff, index) == 0, patch != nil else { continue }
                defer { git_patch_free(patch) }
                var buffer = git_buf()
                defer { git_buf_dispose(&buffer) }
                guard git_patch_to_buf(&buffer, patch) == 0, let bytes = buffer.ptr else { continue }
                text += String(decoding: UnsafeRawBufferPointer(start: bytes, count: buffer.size), as: UTF8.self)
            }
            return text
        }
    }

    // MARK: Helpers

    private func entryID(of path: String, in commit: OpaquePointer?) -> git_oid? {
        var tree: OpaquePointer?
        guard git_commit_tree(&tree, commit) == 0 else { return nil }
        defer { git_tree_free(tree) }
        var entry: OpaquePointer?
        guard git_tree_entry_bypath(&entry, tree, path) == 0 else { return nil }
        defer { git_tree_entry_free(entry) }
        return git_tree_entry_id(entry)?.pointee
    }

    private static func commit(_ commit: OpaquePointer?) -> GitCommit {
        let author = git_commit_author(commit)?.pointee
        return GitCommit(
            id: Git.string(git_commit_id(commit)),
            summary: git_commit_summary(commit).map { String(cString: $0) } ?? "",
            message: git_commit_message(commit).map { String(cString: $0) } ?? "",
            author: author?.name.map { String(cString: $0) } ?? "",
            email: author?.email.map { String(cString: $0) } ?? "",
            date: Date(timeIntervalSince1970: TimeInterval(author?.when.time ?? 0))
        )
    }

    /// The diff of a commit against its first parent, limited to `path` if given.
    private func withDiff<Result>(of commitID: String, path: String?,
                                  _ body: (OpaquePointer?) throws -> Result) throws -> Result {
        var id = git_oid()
        try Git.check(git_oid_fromstr(&id, commitID))
        var commit: OpaquePointer?
        try Git.check(git_commit_lookup(&commit, pointer, &id))
        defer { git_commit_free(commit) }
        var tree: OpaquePointer?
        try Git.check(git_commit_tree(&tree, commit))
        defer { git_tree_free(tree) }
        var parentTree: OpaquePointer?
        if git_commit_parentcount(commit) > 0 {
            var parent: OpaquePointer?
            if git_commit_parent(&parent, commit, 0) == 0 {
                _ = git_commit_tree(&parentTree, parent)
                git_commit_free(parent)
            }
        }
        defer { git_tree_free(parentTree) }

        var options = git_diff_options()
        git_diff_options_init(&options, UInt32(GIT_DIFF_OPTIONS_VERSION))
        let paths = path.map { [$0] } ?? []
        return try Git.withStrArray(paths) { pathspec in
            if path != nil {
                options.pathspec = pathspec.pointee
                options.flags |= UInt32(truncatingIfNeeded: GIT_DIFF_DISABLE_PATHSPEC_MATCH.rawValue)
            }
            var diff: OpaquePointer?
            try Git.check(git_diff_tree_to_tree(&diff, pointer, parentTree, tree, &options))
            defer { git_diff_free(diff) }
            if path == nil { _ = git_diff_find_similar(diff, nil) }
            return try body(diff)
        }
    }
}

/// The tree walk's paths, passed to its callback as the payload.
nonisolated private final class PathCollector {
    var paths: [String] = []
}

/// What the fetch callbacks need, passed to them as their payload.
nonisolated private final class FetchContext {
    let token: String?
    var triedToken = false
    let progress: @Sendable (Double) -> Void
    let isCancelled: @Sendable () -> Bool
    private var lastReported = -1.0

    init(token: String?, progress: @escaping @Sendable (Double) -> Void,
         isCancelled: @escaping @Sendable () -> Bool) {
        self.token = token
        self.progress = progress
        self.isCancelled = isCancelled
    }

    /// Every 1%, not every object.
    func report(_ fraction: Double) {
        guard fraction - lastReported >= 0.01 || fraction >= 1 else { return }
        lastReported = fraction
        progress(fraction)
    }
}

nonisolated enum Git {
    /// libgit2 is set up once, the first time it's used.
    private static let started: Void = { _ = git_libgit2_init() }()

    static func start() {
        _ = started
    }

    /// Throws libgit2's last error for a negative status.
    static func check(_ status: Int32) throws {
        guard status < 0 else { return }
        let message = git_error_last()?.pointee.message.map { String(cString: $0) }
        throw GitError(message: message ?? "Git error \(status)", code: status)
    }

    static func string(_ id: UnsafePointer<git_oid>?) -> String {
        guard let id, let text = git_oid_tostr_s(id) else { return "" }
        return String(cString: text)
    }

    static func same(_ lhs: git_oid?, _ rhs: git_oid?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): return true
        case (var lhs?, var rhs?): return git_oid_equal(&lhs, &rhs) == 1
        default: return false
        }
    }

    /// `strings` as a `git_strarray`, valid inside `body`.
    static func withStrArray<Result>(_ strings: [String],
                                     _ body: (UnsafePointer<git_strarray>) throws -> Result) throws -> Result {
        var copies: [UnsafeMutablePointer<CChar>?] = strings.map { strdup($0) }
        defer { copies.forEach { free($0) } }
        return try copies.withUnsafeMutableBufferPointer { buffer in
            var array = git_strarray(strings: buffer.baseAddress, count: buffer.count)
            return try withUnsafePointer(to: &array) { try body($0) }
        }
    }
}
