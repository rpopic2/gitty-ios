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

/// Who last changed a run of a file's lines, and when (`git blame`).
nonisolated struct GitBlameHunk: Equatable, Sendable {
    /// The run's first line in the file (1-based), and how many lines it has.
    let startLine: Int
    let lineCount: Int
    let commitID: String
    let author: String
    let date: Date
    /// Traced back to the oldest commit downloaded (a shallow clone's start): it may be older.
    let isBoundary: Bool

    var lines: ClosedRange<Int> { startLine...(startLine + max(lineCount, 1) - 1) }
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
    ///   - progress: how far it's got, now and then.
    ///   - isCancelled: checked as data arrives; `true` stops the fetch.
    func fetch(_ ref: GitRef, depth: Int?, token: String?,
               progress: @escaping @Sendable (FetchProgress) -> Void = { _ in },
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
                let bytes = Int(stats.received_bytes)
                if stats.received_objects == stats.total_objects, stats.total_deltas > 0 {
                    context.report(FetchProgress(fraction: Double(stats.indexed_deltas) / Double(stats.total_deltas),
                                                 receivedBytes: bytes, phase: .resolving))
                } else {
                    context.report(FetchProgress(fraction: Double(stats.received_objects) / Double(stats.total_objects),
                                                 receivedBytes: bytes))
                }
            }
            return 0
        }
        try withExtendedLifetime(context) {
            try Git.withStrArray([ref.refspec]) { refspecs in
                try Git.check(git_remote_fetch(remote, refspecs, &options, nil))
            }
        }
    }

    /// The branches and tags `origin` has (`git ls-remote`): asked of the remote, nothing
    /// downloaded. Sorted by name.
    func remoteRefs(token: String?) throws -> ProjectRefs {
        var remote: OpaquePointer?
        try Git.check(git_remote_lookup(&remote, pointer, "origin"))
        defer { git_remote_free(remote) }
        let context = FetchContext(token: token, progress: { _ in }, isCancelled: { false })
        var callbacks = git_remote_callbacks()
        git_remote_init_callbacks(&callbacks, UInt32(GIT_REMOTE_CALLBACKS_VERSION))
        callbacks.payload = Unmanaged.passUnretained(context).toOpaque()
        callbacks.credentials = { out, _, _, allowed, payload in
            guard let payload else { return GIT_PASSTHROUGH.rawValue }
            let context = Unmanaged<FetchContext>.fromOpaque(payload).takeUnretainedValue()
            guard let token = context.token, !context.triedToken,
                  allowed & UInt32(truncatingIfNeeded: GIT_CREDENTIAL_USERPASS_PLAINTEXT.rawValue) != 0
            else { return GIT_PASSTHROUGH.rawValue }
            context.triedToken = true
            return git_credential_userpass_plaintext_new(out, "x-access-token", token)
        }
        return try withExtendedLifetime(context) {
            try Git.check(git_remote_connect(remote, GIT_DIRECTION_FETCH, &callbacks, nil, nil))
            defer { git_remote_disconnect(remote) }
            var heads: UnsafeMutablePointer<UnsafePointer<git_remote_head>?>?
            var count = 0
            try Git.check(git_remote_ls(&heads, &count, remote))
            var branches: [String] = []
            var tags: [String] = []
            for index in 0..<count {
                guard let head = heads?[index]?.pointee, let raw = head.name else { continue }
                let name = String(cString: raw)
                if name.hasPrefix("refs/heads/") {
                    branches.append(String(name.dropFirst("refs/heads/".count)))
                } else if name.hasPrefix("refs/tags/"), !name.hasSuffix("^{}") {
                    tags.append(String(name.dropFirst("refs/tags/".count)))
                }
            }
            let order: (String, String) -> Bool = { $0.localizedStandardCompare($1) == .orderedAscending }
            return ProjectRefs(branches: branches.sorted(by: order), tags: tags.sorted(by: order))
        }
    }

    /// The file list at `ref` (fetched), from the clone: no network. Like GitHub's, with each
    /// file's size.
    func tree(of ref: GitRef) throws -> ProjectTree {
        var commit: OpaquePointer?
        try Git.check(git_revparse_single(&commit, pointer, ref.localReference + "^{commit}"))
        defer { git_object_free(commit) }
        var tree: OpaquePointer?
        try Git.check(git_object_peel(&tree, commit, GIT_OBJECT_TREE))
        defer { git_object_free(tree) }
        let collector = TreeCollector()
        try withExtendedLifetime(collector) {
            try Git.check(git_tree_walk(tree, GIT_TREEWALK_PRE, { root, entry, payload in
                guard let entry, let payload, let name = git_tree_entry_name(entry) else { return 0 }
                let collector = Unmanaged<TreeCollector>.fromOpaque(payload).takeUnretainedValue()
                let kind: ProjectTree.Entry.Kind
                switch git_tree_entry_type(entry) {
                case GIT_OBJECT_BLOB: kind = .file
                case GIT_OBJECT_TREE: kind = .folder
                case GIT_OBJECT_COMMIT: kind = .submodule
                default: return 0
                }
                let path = (root.map { String(cString: $0) } ?? "") + String(cString: name)
                collector.items.append((path, kind, git_tree_entry_id(entry).pointee))
                return 0
            }, Unmanaged.passUnretained(collector).toOpaque()))
        }
        var odb: OpaquePointer?
        try Git.check(git_repository_odb(&odb, pointer))
        defer { git_odb_free(odb) }
        let entries = collector.items.map { item -> ProjectTree.Entry in
            var id = item.id
            var size: Int?
            if item.kind == .file {
                var length = 0
                var type = GIT_OBJECT_ANY
                if git_odb_read_header(&length, &type, odb, &id) == 0 { size = length }
            }
            return ProjectTree.Entry(path: item.path, kind: item.kind, sha: Git.string(&id), size: size)
        }
        return ProjectTree(entries: entries, truncated: false, etag: nil, fetchedAt: .now)
    }

    /// The commit `ref` is at in the clone, if it was ever fetched.
    func fetchedCommit(of ref: GitRef) -> String? {
        var object: OpaquePointer?
        guard git_revparse_single(&object, pointer, ref.localReference + "^{commit}") == 0 else { return nil }
        defer { git_object_free(object) }
        return Git.string(git_object_id(object))
    }

    /// How many commits `newer` has that `older` doesn't (0 if either isn't known).
    func commitsAhead(_ newer: String, of older: String) -> Int {
        var newerID = git_oid(), olderID = git_oid()
        guard git_oid_fromstr(&newerID, newer) == 0, git_oid_fromstr(&olderID, older) == 0 else { return 0 }
        var ahead = 0, behind = 0
        guard git_graph_ahead_behind(&ahead, &behind, pointer, &newerID, &olderID) == 0 else { return 0 }
        return ahead
    }

    /// Puts `ref`'s files (once fetched) in the working directory, replacing what's there, and
    /// points HEAD at its commit. Returns the commit's hash.
    /// - Parameter progress: the share of files written, now and then.
    @discardableResult
    func checkout(_ ref: GitRef, progress: (@Sendable (Double) -> Void)? = nil) throws -> String {
        var object: OpaquePointer?
        try Git.check(git_revparse_single(&object, pointer, ref.localReference + "^{commit}"))
        defer { git_object_free(object) }
        var options = git_checkout_options()
        git_checkout_options_init(&options, UInt32(GIT_CHECKOUT_OPTIONS_VERSION))
        options.checkout_strategy = UInt32(truncatingIfNeeded: GIT_CHECKOUT_FORCE.rawValue)
        let context = CheckoutContext(progress: progress ?? { _ in })
        if progress != nil {
            options.progress_payload = Unmanaged.passUnretained(context).toOpaque()
            options.progress_cb = { _, completed, total, payload in
                guard let payload, total > 0 else { return }
                Unmanaged<CheckoutContext>.fromOpaque(payload).takeUnretainedValue()
                    .report(Double(completed) / Double(total))
            }
        }
        try withExtendedLifetime(context) {
            try Git.check(git_checkout_tree(pointer, object, &options))
        }
        let id = git_object_id(object)
        try Git.check(git_repository_set_head_detached(pointer, id))
        return Git.string(id)
    }

    /// Every file's path in the checked-out commit, in Git's order: each folder's entries by
    /// name, a folder's files where the folder comes. Already in order, so a big clone's list
    /// needs no sorting (and no walk through its folder on disk).
    func checkedOutFilePaths() throws -> [String] {
        var tree: OpaquePointer?
        try Git.check(git_revparse_single(&tree, pointer, "HEAD^{tree}"))
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

    /// The size of the files among `entries` (a tree's, by their hashes) this clone doesn't
    /// have: what fetching them would add, before compression.
    func missingBytes(of entries: [ProjectTree.Entry]) throws -> Int64 {
        var odb: OpaquePointer?
        try Git.check(git_repository_odb(&odb, pointer))
        defer { git_odb_free(odb) }
        var bytes: Int64 = 0
        for entry in entries where entry.kind == .file {
            var id = git_oid()
            guard git_oid_fromstr(&id, entry.sha) == 0 else { continue }
            if git_odb_exists(odb, &id) == 0 { bytes += Int64(entry.size ?? 0) }
        }
        return bytes
    }

    /// Writes the checked-out commit's files to the working directory again, replacing what's
    /// there (and putting back any that are missing).
    func checkOutHeadAgain() throws {
        var options = git_checkout_options()
        git_checkout_options_init(&options, UInt32(GIT_CHECKOUT_OPTIONS_VERSION))
        options.checkout_strategy = UInt32(truncatingIfNeeded: GIT_CHECKOUT_FORCE.rawValue)
        try Git.check(git_checkout_head(pointer, &options))
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

    /// Who last changed each run of lines of `path` (relative to the repository), at HEAD.
    func blame(of path: String) throws -> [GitBlameHunk] {
        var options = git_blame_options()
        try Git.check(git_blame_options_init(&options, UInt32(GIT_BLAME_OPTIONS_VERSION)))
        var blame: OpaquePointer?
        try Git.check(git_blame_file(&blame, pointer, path, &options))
        defer { git_blame_free(blame) }
        return (0..<git_blame_get_hunk_count(blame)).compactMap { index -> GitBlameHunk? in
            guard let hunk = git_blame_get_hunk_byindex(blame, index)?.pointee else { return nil }
            var id = hunk.final_commit_id
            let signature = hunk.final_signature?.pointee
            return GitBlameHunk(
                startLine: Int(hunk.final_start_line_number),
                lineCount: Int(hunk.lines_in_hunk),
                commitID: Git.string(&id),
                author: signature?.name.map { String(cString: $0) } ?? "",
                date: Date(timeIntervalSince1970: TimeInterval(signature?.when.time ?? 0)),
                isBoundary: hunk.boundary != 0
            )
        }
    }

    /// One commit, by its hash.
    func commit(_ id: String) throws -> GitCommit {
        var oid = git_oid()
        try Git.check(git_oid_fromstr(&oid, id))
        var commit: OpaquePointer?
        try Git.check(git_commit_lookup(&commit, pointer, &oid))
        defer { git_commit_free(commit) }
        return Self.commit(commit)
    }

    /// The checked-out branch or tag's commits, newest first, up to `limit` (`git log`). The
    /// oldest one of a shallow clone is marked as its boundary.
    func log(limit: Int) throws -> GitFileHistory {
        var walk: OpaquePointer?
        try Git.check(git_revwalk_new(&walk, pointer))
        defer { git_revwalk_free(walk) }
        git_revwalk_sorting(walk, UInt32(truncatingIfNeeded: GIT_SORT_TIME.rawValue))
        var head = git_oid()
        try Git.check(git_reference_name_to_id(&head, pointer, "HEAD"))
        try Git.check(git_revwalk_push(walk, &head))

        var commits: [GitCommit] = []
        var reachedBoundary = false
        var id = git_oid()
        while commits.count < limit, git_revwalk_next(&id, walk) == 0 {
            var commit: OpaquePointer?
            guard git_commit_lookup(&commit, pointer, &id) == 0 else { continue }
            defer { git_commit_free(commit) }
            var info = Self.commit(commit)
            if git_commit_parentcount(commit) == 0, isShallow {
                info.isBoundary = true
                reachedBoundary = true
            }
            commits.append(info)
        }
        return GitFileHistory(commits: commits, canLoadMore: commits.count >= limit || reachedBoundary)
    }

    /// The files a commit changed, against its first parent (everything, for the first commit
    /// or a shallow clone's oldest), with renames found.
    func changes(in commitID: String) throws -> [GitChange] {
        try withDiff(of: commitID, path: nil, Self.changeList)
    }

    /// The files that differ from one commit to another, with renames found.
    func changes(from before: String, to after: String) throws -> [GitChange] {
        try withDiff(from: before, to: after, path: nil, Self.changeList)
    }

    /// One file's changes from one commit to another, as a unified diff.
    func patch(from before: String, to after: String, path: String) throws -> String {
        try withDiff(from: before, to: after, path: path, Self.patchText)
    }

    private static func changeList(_ diff: OpaquePointer?) -> [GitChange] {
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

    /// One file's changes in a commit, as a unified diff (`diff --git` header and hunks).
    /// Empty if the commit didn't change it.
    func patch(in commitID: String, path: String) throws -> String {
        try withDiff(of: commitID, path: path, Self.patchText)
    }

    private static func patchText(_ diff: OpaquePointer?) -> String {
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

    // MARK: Comparing

    /// The commit a side is at in the clone, without fetching: `nil` if it isn't downloaded
    /// (or the hash isn't in the downloaded history).
    func resolve(_ side: GitSide) -> String? {
        let spec: String
        switch side {
        case .branch(let name): spec = GitRef.branch(name).localReference
        case .tag(let name): spec = GitRef.tag(name).localReference
        case .commit(let id): spec = id
        case .checkedOut: spec = "HEAD"
        }
        var object: OpaquePointer?
        guard git_revparse_single(&object, pointer, spec + "^{commit}") == 0 else { return nil }
        defer { git_object_free(object) }
        return Git.string(git_object_id(object))
    }

    /// Where two commits' histories meet (`git merge-base`): `nil` if they don't within the
    /// downloaded history.
    func mergeBase(_ one: String, _ two: String) -> String? {
        var first = git_oid(), second = git_oid(), base = git_oid()
        guard git_oid_fromstr(&first, one) == 0, git_oid_fromstr(&second, two) == 0,
              git_merge_base(&base, pointer, &first, &second) == 0
        else { return nil }
        return Git.string(&base)
    }

    /// `head`'s commits that `base` doesn't have (`git log base..head`), newest first, up to
    /// `limit`; and whether there are more.
    func commits(from base: String, to head: String, limit: Int) throws -> (commits: [GitCommit], hasMore: Bool) {
        var walk: OpaquePointer?
        try Git.check(git_revwalk_new(&walk, pointer))
        defer { git_revwalk_free(walk) }
        git_revwalk_sorting(walk, UInt32(truncatingIfNeeded: GIT_SORT_TIME.rawValue))
        var headID = git_oid(), baseID = git_oid()
        try Git.check(git_oid_fromstr(&headID, head))
        try Git.check(git_oid_fromstr(&baseID, base))
        try Git.check(git_revwalk_push(walk, &headID))
        _ = git_revwalk_hide(walk, &baseID)
        var commits: [GitCommit] = []
        var id = git_oid()
        while git_revwalk_next(&id, walk) == 0 {
            guard commits.count < limit else { return (commits, true) }
            var commit: OpaquePointer?
            guard git_commit_lookup(&commit, pointer, &id) == 0 else { continue }
            defer { git_commit_free(commit) }
            commits.append(Self.commit(commit))
        }
        return (commits, false)
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
        return try withDiff(parentTree, tree, path: path, body)
    }

    /// The diff from one commit's files to another's, limited to `path` if given.
    private func withDiff<Result>(from before: String, to after: String, path: String?,
                                  _ body: (OpaquePointer?) throws -> Result) throws -> Result {
        func tree(of commitID: String) throws -> OpaquePointer? {
            var id = git_oid()
            try Git.check(git_oid_fromstr(&id, commitID))
            var commit: OpaquePointer?
            try Git.check(git_commit_lookup(&commit, pointer, &id))
            defer { git_commit_free(commit) }
            var tree: OpaquePointer?
            try Git.check(git_commit_tree(&tree, commit))
            return tree
        }
        let old = try tree(of: before)
        defer { git_tree_free(old) }
        let new = try tree(of: after)
        defer { git_tree_free(new) }
        return try withDiff(old, new, path: path, body)
    }

    /// The diff from one tree to another (`nil`: nothing, so everything is added).
    private func withDiff<Result>(_ parentTree: OpaquePointer?, _ tree: OpaquePointer?, path: String?,
                                  _ body: (OpaquePointer?) throws -> Result) throws -> Result {
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

/// What `checkedOutFilePaths` walks into, from libgit2's callback.
nonisolated private final class PathCollector {
    var paths: [String] = []
}

/// What `tree(of:)` walks into, from libgit2's callback.
nonisolated private final class TreeCollector {
    var items: [(path: String, kind: ProjectTree.Entry.Kind, id: git_oid)] = []
}

/// How far a fetch has got: the share of objects received, and the bytes downloaded so far;
/// then, with nothing left to download, rebuilding the files Git sent as changes to others
/// (resolving deltas) and writing them out (checking out), which take a while too.
nonisolated struct FetchProgress: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case receiving
        case resolving
        case checkingOut
    }

    var fraction: Double
    var receivedBytes: Int
    var phase: Phase = .receiving

    static let start = FetchProgress(fraction: 0, receivedBytes: 0)
}

/// What the checkout's progress callback needs, passed to it as its payload.
nonisolated private final class CheckoutContext {
    let progress: @Sendable (Double) -> Void
    private var lastReported: ContinuousClock.Instant?

    init(progress: @escaping @Sendable (Double) -> Void) {
        self.progress = progress
    }

    /// Ten times a second, and the end.
    func report(_ fraction: Double) {
        let now = ContinuousClock.now
        if let lastReported, now - lastReported < .milliseconds(100), fraction < 1 { return }
        lastReported = now
        progress(fraction)
    }
}

/// What the fetch callbacks need, passed to them as their payload.
nonisolated private final class FetchContext {
    let token: String?
    var triedToken = false
    let progress: @Sendable (FetchProgress) -> Void
    let isCancelled: @Sendable () -> Bool
    private var lastReported: ContinuousClock.Instant?

    init(token: String?, progress: @escaping @Sendable (FetchProgress) -> Void,
         isCancelled: @escaping @Sendable () -> Bool) {
        self.token = token
        self.progress = progress
        self.isCancelled = isCancelled
    }

    /// Ten times a second (and as each phase starts and ends), not for every object.
    func report(_ progress: FetchProgress) {
        let now = ContinuousClock.now
        let isNew = progress.phase != lastPhase || (progress.fraction >= 1 && lastFraction < 1)
        if let lastReported, now - lastReported < .milliseconds(100), !isNew { return }
        lastReported = now
        lastPhase = progress.phase
        lastFraction = progress.fraction
        self.progress(progress)
    }
    private var lastPhase = FetchProgress.Phase.receiving
    private var lastFraction = 0.0
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
