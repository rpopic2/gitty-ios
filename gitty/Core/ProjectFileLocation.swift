import Foundation

/// Where a file address is in a project: the project, and the file's path in the repository
/// (for its history in the clone, and its page on github.com).
nonisolated struct ProjectFileLocation: Equatable, Sendable {
    let project: ProjectInfo
    /// From the repository's root (the folder a project starts at included), unescaped.
    let path: String

    /// The file on github.com, at the project's branch or tag.
    var webURL: URL? {
        guard let ref = project.ref, let link = project.link else { return nil }
        var components = URLComponents()
        components.scheme = "https"
        components.host = "github.com"
        components.path = "/" + [link.owner, link.repo, "blob", ref, path].joined(separator: "/")
        return components.url
    }

    /// `nil` for a file outside every project (or at a branch the project has since left).
    static func locate(_ url: URL, in projects: [ProjectInfo]) -> ProjectFileLocation? {
        guard let project = ProjectSymbolIndex.project(containing: url, in: projects),
              let root = project.rawURL(for: "")?.absoluteString,
              url.absoluteString.hasPrefix(root)
        else { return nil }
        let relative = String(url.absoluteString.dropFirst(root.count))
        let path = relative.removingPercentEncoding ?? relative
        guard !path.isEmpty else { return nil }
        return ProjectFileLocation(project: project, path: path)
    }
}
