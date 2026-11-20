import CryptoKit
import Foundation

/// A GitHub repository link that opens as a project: `github.com/owner/repo`, optionally with
/// `/tree/<ref>/<folder>`. File links (`/blob/`, `/raw/`) and other pages (issues, pulls…) aren't.
nonisolated struct RepoLink: Hashable, Codable, Sendable {
    let owner: String
    let repo: String
    /// What came after `/tree/`: a ref, possibly followed by a folder. A ref can contain slashes
    /// (`feature/x`), so it's split into ref and folder only when the tree is fetched.
    let treePath: [String]

    /// Identifies the project: `owner/repo` plus anything after `/tree/`.
    var id: String {
        ([owner, repo] + (treePath.isEmpty ? [] : ["tree"] + treePath)).joined(separator: "/")
    }

    /// The repository (or folder) on github.com: `https://github.com/owner/repo/tree/…`.
    var webURL: URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "github.com"
        components.path = "/" + id
        return components.url
    }

    init(owner: String, repo: String, treePath: [String] = []) {
        self.owner = owner
        self.repo = repo
        self.treePath = treePath
    }

    /// What was typed to add a project: `owner/repo`, `github.com/owner/repo`, or a whole link
    /// (to a folder too, with `/tree/…`). `nil` for anything else.
    static func typed(_ text: String) -> RepoLink? {
        var address = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = address.lowercased()
        if lowered.hasPrefix("http://") {
            address = "https://" + address.dropFirst("http://".count)
        } else if !lowered.hasPrefix("https://") {
            let hasHost = lowered.hasPrefix("github.com/") || lowered.hasPrefix("www.github.com/")
            address = "https://" + (hasHost ? "" : "github.com/") + address
        }
        return URL(string: address).flatMap(RepoLink.init)
    }

    init?(_ url: URL) {
        guard url.scheme?.lowercased() == "https",
              let host = url.host()?.lowercased(), host == "github.com" || host == "www.github.com"
        else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count >= 2 else { return nil }
        var repo = parts[1]
        if repo.hasSuffix(".git") { repo.removeLast(4) }
        guard !repo.isEmpty else { return nil }
        switch parts.count {
        case 2:
            self.init(owner: parts[0], repo: repo)
        case 3... where parts[2] == "tree" && parts.count >= 4:
            self.init(owner: parts[0], repo: repo, treePath: Array(parts[3...]))
        default:
            return nil  // a file, an issue, a pull request…
        }
    }
}

/// A project: a repository (or a folder of one) at a ref, as shown in the Project view.
nonisolated struct ProjectInfo: Hashable, Codable, Sendable, Identifiable {
    let link: RepoLink
    /// Known once the tree has been fetched: the branch, tag or commit…
    var ref: String?
    /// …and the folder the project starts at ("" for the whole repository).
    var folder: String?
    let addedAt: Date

    var id: String { link.id }

    /// `allang`, or `allang/alc` for a folder.
    var title: String {
        guard let folder, !folder.isEmpty else { return link.repo }
        return link.repo + "/" + folder
    }

    /// The raw file URL for a path in the repository (needs `ref`).
    func rawURL(for path: String) -> URL? {
        guard let ref else { return nil }
        var components = URLComponents()
        components.scheme = "https"
        components.host = "raw.githubusercontent.com"
        components.path = "/" + [link.owner, link.repo, ref, path].joined(separator: "/")
        return components.url
    }
}

/// A repository's files, from GitHub's trees API.
nonisolated struct ProjectTree: Codable, Sendable {
    nonisolated struct Entry: Codable, Sendable, Hashable {
        enum Kind: String, Codable, Sendable {
            case file = "blob", folder = "tree", submodule = "commit"
        }
        let path: String
        let kind: Kind
        /// Git's hash of the file, which changes whenever the file does.
        let sha: String
        let size: Int?

        var name: String { path.split(separator: "/").last.map(String.init) ?? path }
    }

    let entries: [Entry]
    /// GitHub cuts very large trees short (about 100k entries).
    let truncated: Bool
    let etag: String?
    let fetchedAt: Date

    /// Files in one directory of a project, for a section of the Project tab.
    nonisolated struct Directory: Sendable, Identifiable {
        /// Relative to the project's folder; "" for the files directly in it.
        let path: String
        let files: [Entry]

        var id: String { path }
    }

    /// Every file inside `folder` ("" for the whole repository), grouped by directory: the top
    /// first, then directories in path order (`Sources` before `Sources/Inner` before `Tests`).
    /// In each directory, code files (those with symbols) come first, then other files, A–Z.
    /// With a filter, only the files it lets through (paths inside `folder`), and only the
    /// directories that still have some.
    func directories(under folder: String, matching filter: FileFilter = .none) -> [Directory] {
        let prefix = folder.isEmpty ? "" : folder + "/"
        var groups: [String: [Entry]] = [:]
        for entry in entries where entry.kind == .file && entry.path.hasPrefix(prefix) {
            let relative = entry.path.dropFirst(prefix.count)
            guard filter.matches(String(relative)) else { continue }
            let directory = relative.lastIndex(of: "/").map { String(relative[..<$0]) } ?? ""
            groups[directory, default: []].append(entry)
        }
        return groups.keys.sorted(by: Self.isDirectoryBefore).map { path in
            Directory(path: path, files: (groups[path] ?? []).sorted(by: Self.isFileBefore))
        }
    }

    /// Every file inside `folder`, at any depth, that the filter lets through.
    func files(under folder: String, matching filter: FileFilter = .none) -> [Entry] {
        let prefix = folder.isEmpty ? "" : folder + "/"
        return entries.filter {
            $0.kind == .file && $0.path.hasPrefix(prefix)
                && filter.matches(String($0.path.dropFirst(prefix.count)))
        }
    }

    static func isCode(_ entry: Entry) -> Bool {
        let ext = (entry.name as NSString).pathExtension
        return SymbolLanguage.extensionHasSymbols(ext)
    }

    /// Compares path components, so a directory's subdirectories follow it directly.
    private static func isDirectoryBefore(_ lhs: String, _ rhs: String) -> Bool {
        let left = lhs.split(separator: "/"), right = rhs.split(separator: "/")
        for (a, b) in zip(left, right) where a != b {
            return a.localizedStandardCompare(b) == .orderedAscending
        }
        return left.count < right.count
    }

    private static func isFileBefore(_ lhs: Entry, _ rhs: Entry) -> Bool {
        let left = isCode(lhs), right = isCode(rhs)
        if left != right { return left }
        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }
}

nonisolated enum ProjectError: LocalizedError, Equatable {
    case notFound
    case rateLimited
    case badStatus(Int)
    case unknownProject

    var errorDescription: String? {
        switch self {
        case .notFound: "GitHub couldn't find this repository, branch or folder."
        case .rateLimited: "GitHub's limit on requests was reached. Try again in a while."
        case .badStatus(let code): "GitHub responded with status \(code)."
        case .unknownProject: "This project is no longer in the list."
        }
    }
}

/// A repository's branch and tag names.
nonisolated struct ProjectRefs: Codable, Equatable, Sendable {
    let branches: [String]
    let tags: [String]
}

/// Projects and their file lists. The list is fetched when a project is added and again only on
/// pull-to-refresh (as a conditional request, so an unchanged repository costs a 304). Files are
/// downloaded separately, through `DocumentStore`, when they're opened.
actor ProjectStore {
    static let shared = ProjectStore()

    static let defaultDirectory: URL = URL.applicationSupportDirectory
        .appending(path: "Projects", directoryHint: .isDirectory)

    private let directory: URL
    private let session: URLSession
    /// Adds the GitHub token, for private repositories (and a higher request limit).
    private let authorizer: (any RequestAuthorizer)?

    init(directory: URL = ProjectStore.defaultDirectory,
         configuration: URLSessionConfiguration = .ephemeral,
         authorizer: (any RequestAuthorizer)? = GitHubAuth.shared) {
        self.directory = directory
        self.authorizer = authorizer
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        self.session = URLSession(configuration: configuration)
    }

    // MARK: Projects

    /// Newest first.
    func projects() -> [ProjectInfo] {
        loadIndex().sorted { $0.addedAt > $1.addedAt }
    }

    func project(id: String) -> ProjectInfo? {
        loadIndex().first { $0.id == id }
    }

    /// Adds the project if it's new. Returns it either way.
    @discardableResult
    func add(_ link: RepoLink) -> ProjectInfo {
        var index = loadIndex()
        if let existing = index.first(where: { $0.id == link.id }) { return existing }
        let project = ProjectInfo(link: link, ref: nil, folder: nil, addedAt: .now)
        index.append(project)
        saveIndex(index)
        return project
    }

    func remove(id: String) {
        trees[id] = nil
        refsCache[id] = nil
        saveIndex(loadIndex().filter { $0.id != id })
        try? FileManager.default.removeItem(at: treeURL(for: id))
    }

    // MARK: Trees

    /// The project's saved file list, fetching it only if there's none yet (or `refresh`).
    func tree(for id: String, refresh: Bool = false) async throws -> (ProjectInfo, ProjectTree) {
        guard var project = project(id: id) else { throw ProjectError.unknownProject }
        let saved = savedTree(for: id)
        if let saved, !refresh, project.ref != nil { return (project, saved) }

        if let ref = project.ref {
            // `nil` means unchanged (304), which only happens when there's a saved tree.
            guard let tree = try await fetchTree(project.link, ref: ref, etag: saved?.etag) ?? saved else {
                throw ProjectError.notFound
            }
            saveTree(tree, for: id)
            return (project, tree)
        }

        // First fetch: work out the ref (the default branch, or which part of `/tree/…` is the
        // ref, since refs can contain slashes) and the folder.
        let candidates = try await refCandidates(for: project.link)
        for (ref, folder) in candidates {
            do {
                guard let tree = try await fetchTree(project.link, ref: ref, etag: nil) else { continue }
                if !folder.isEmpty, !tree.entries.contains(where: { $0.path == folder && $0.kind == .folder }) {
                    continue  // that split didn't name a real folder
                }
                project.ref = ref
                project.folder = folder
                update(project)
                saveTree(tree, for: id)
                return (project, tree)
            } catch ProjectError.notFound {
                continue  // try the next way of splitting ref and folder
            }
        }
        throw ProjectError.notFound
    }

    // MARK: Branches and tags

    /// The repository's branches and tags, from GitHub's API: fetched once per run (or on
    /// `refresh`), for the branch row and for Clone.
    func refs(for id: String, refresh: Bool = false) async throws -> ProjectRefs {
        guard let project = project(id: id) else { throw ProjectError.unknownProject }
        if !refresh, let known = refsCache[id] { return known }
        let link = project.link
        let branches = try await names(at: "/repos/\(link.owner)/\(link.repo)/branches")
        let tags = try await names(at: "/repos/\(link.owner)/\(link.repo)/tags")
        let refs = ProjectRefs(branches: branches, tags: tags)
        refsCache[id] = refs
        return refs
    }

    private var refsCache: [String: ProjectRefs] = [:]

    /// Every `name` in a paged list (up to 1,000).
    private func names(at path: String) async throws -> [String] {
        nonisolated struct Item: Decodable { let name: String }
        var names: [String] = []
        for page in 1...10 {
            let (data, response) = try await get(path: path, query: "per_page=100&page=\(page)", etag: nil)
            try check(response)
            let items = try JSONDecoder().decode([Item].self, from: data)
            names += items.map(\.name)
            if items.count < 100 { break }
        }
        return names
    }

    /// Moves the project to another branch or tag (same folder): its file list is fetched for
    /// it, and its files' addresses change with it.
    func setRef(_ ref: String, for id: String) async throws -> (ProjectInfo, ProjectTree) {
        guard var project = project(id: id) else { throw ProjectError.unknownProject }
        guard let tree = try await fetchTree(project.link, ref: ref, etag: nil) else { throw ProjectError.notFound }
        project.ref = ref
        update(project)
        saveTree(tree, for: id)
        return (project, tree)
    }

    /// Moves the project to another branch or tag with its file list from the clone: no
    /// network.
    func setRef(_ ref: String, for id: String, tree: ProjectTree) throws -> (ProjectInfo, ProjectTree) {
        guard var project = project(id: id) else { throw ProjectError.unknownProject }
        project.ref = ref
        update(project)
        saveTree(tree, for: id)
        return (project, tree)
    }

    /// (ref, folder) pairs to try, most likely first.
    private func refCandidates(for link: RepoLink) async throws -> [(String, String)] {
        guard !link.treePath.isEmpty else {
            return [(try await defaultBranch(of: link), "")]
        }
        let parts = link.treePath
        return (1...min(parts.count, 4)).map { count in
            (parts[..<count].joined(separator: "/"), parts[count...].joined(separator: "/"))
        }
    }

    private func defaultBranch(of link: RepoLink) async throws -> String {
        nonisolated struct Repository: Decodable { let default_branch: String }
        let (data, response) = try await get(path: "/repos/\(link.owner)/\(link.repo)", etag: nil)
        try check(response)
        return try JSONDecoder().decode(Repository.self, from: data).default_branch
    }

    /// `nil` when the server says it hasn't changed (HTTP 304).
    private func fetchTree(_ link: RepoLink, ref: String, etag: String?) async throws -> ProjectTree? {
        nonisolated struct Response: Decodable {
            nonisolated struct Item: Decodable { let path: String; let type: String; let sha: String; let size: Int? }
            let tree: [Item]
            let truncated: Bool
        }
        let encodedRef = ref.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ref
        let (data, response) = try await get(
            path: "/repos/\(link.owner)/\(link.repo)/git/trees/\(encodedRef)", query: "recursive=1", etag: etag)
        if (response as? HTTPURLResponse)?.statusCode == 304 { return nil }
        try check(response)
        let decoded = try JSONDecoder().decode(Response.self, from: data)
        let entries = decoded.tree.compactMap { item in
            ProjectTree.Entry.Kind(rawValue: item.type).map {
                ProjectTree.Entry(path: item.path, kind: $0, sha: item.sha, size: item.size)
            }
        }
        return ProjectTree(entries: entries, truncated: decoded.truncated,
                           etag: (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "ETag"),
                           fetchedAt: .now)
    }

    private func get(path: String, query: String? = nil, etag: String?) async throws -> (Data, URLResponse) {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.github.com"
        components.percentEncodedPath = path
        components.percentEncodedQuery = query
        guard let url = components.url else { throw ProjectError.notFound }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        if let etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        guard let authorization = await authorizer?.authorization(for: url) else {
            return try await session.data(for: request)
        }
        var signedIn = request
        signedIn.setValue(authorization, forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: signedIn)
        guard (response as? HTTPURLResponse)?.statusCode == 401 else { return (data, response) }
        // The token was revoked or expired: forget it and ask again without it (public
        // repositories still work; private ones then ask you to sign in).
        await authorizer?.tokenRejected()
        return try await session.data(for: request)
    }

    private func check(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw ProjectError.badStatus(0) }
        switch http.statusCode {
        case 200: return
        case 404, 409, 422: throw ProjectError.notFound  // 409: empty repository
        case 429: throw ProjectError.rateLimited
        case 403 where http.value(forHTTPHeaderField: "x-ratelimit-remaining") == "0":
            throw ProjectError.rateLimited
        default: throw ProjectError.badStatus(http.statusCode)
        }
    }

    // MARK: Disk

    private var indexURL: URL { directory.appending(path: "projects.json") }

    private func treeURL(for id: String) -> URL {
        let digest = SHA256.hash(data: Data(id.utf8))
        return directory.appending(path: digest.map { String(format: "%02x", $0) }.joined() + ".tree.json")
    }

    private func loadIndex() -> [ProjectInfo] {
        guard let data = try? Data(contentsOf: indexURL) else { return [] }
        return (try? JSONDecoder().decode([ProjectInfo].self, from: data)) ?? []
    }

    private func saveIndex(_ index: [ProjectInfo]) {
        ensureDirectory()
        if let data = try? JSONEncoder().encode(index) { try? data.write(to: indexURL, options: .atomic) }
    }

    private func update(_ project: ProjectInfo) {
        saveIndex(loadIndex().map { $0.id == project.id ? project : $0 })
    }

    /// Trees already read from disk (a big repository's takes a moment to decode).
    private var trees: [String: ProjectTree] = [:]

    private func savedTree(for id: String) -> ProjectTree? {
        if let tree = trees[id] { return tree }
        guard let data = try? Data(contentsOf: treeURL(for: id)),
              let tree = try? JSONDecoder().decode(ProjectTree.self, from: data)
        else { return nil }
        trees[id] = tree
        return tree
    }

    private func saveTree(_ tree: ProjectTree, for id: String) {
        trees[id] = tree
        ensureDirectory()
        if let data = try? JSONEncoder().encode(tree) { try? data.write(to: treeURL(for: id), options: .atomic) }
    }

    private func ensureDirectory() {
        guard !FileManager.default.fileExists(atPath: directory.path) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var directory = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true  // can be fetched again
        try? directory.setResourceValues(values)
    }
}
