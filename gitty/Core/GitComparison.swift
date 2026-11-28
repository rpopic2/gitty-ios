import Foundation

/// One side of a comparison: a branch, a tag, a commit (its hash, or the start of it), or the
/// commit the clone has checked out.
nonisolated enum GitSide: Hashable, Codable, Sendable {
    case branch(String)
    case tag(String)
    case commit(String)
    case checkedOut

    /// "main", "v1.0", "3f2a9c1", or "Checked Out".
    var label: String {
        switch self {
        case .branch(let name), .tag(let name): name
        case .commit(let id): String(id.prefix(7))
        case .checkedOut: String(localized: "Checked Out")
        }
    }

    var systemImage: String {
        switch self {
        case .branch: "arrow.triangle.branch"
        case .tag: "tag"
        case .commit: "smallcircle.filled.circle"
        case .checkedOut: "checkmark.circle"
        }
    }

    init(_ ref: GitRef) {
        switch ref {
        case .branch(let name): self = .branch(name)
        case .tag(let name): self = .tag(name)
        }
    }

    /// The branch or tag to fetch for it (`nil`: a commit, or the checkout, which can't be).
    var ref: GitRef? {
        switch self {
        case .branch(let name): .branch(name)
        case .tag(let name): .tag(name)
        case .commit, .checkedOut: nil
        }
    }

    /// What was typed, if it looks like a commit's hash: 7 to 40 hexadecimal digits.
    static func commitHash(in text: String) -> String? {
        let hash = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard (7...40).contains(hash.count), hash.allSatisfy(\.isHexDigit) else { return nil }
        return hash
    }
}

/// Two sides to compare, and how.
nonisolated struct GitComparison: Hashable, Sendable {
    enum Mode: String, Hashable, Codable, Sendable {
        /// What `head` changed since it split off `base` (`base...head`, like a pull request).
        case sinceSplit
        /// The difference between the two, directly (`base..head`): `base`'s own changes since
        /// they split show too, as if `head` undid them.
        case direct
    }

    var base: GitSide
    var head: GitSide
    var mode: Mode = .sinceSplit

    /// "main...feature" or "main..feature".
    var title: String {
        base.label + (mode == .sinceSplit ? "..." : "..") + head.label
    }
}

/// A comparison worked out in the clone: the commit its diff starts from (where the two split,
/// or `base` itself) and the one it goes to, and the commits in between.
nonisolated struct ResolvedComparison: Hashable, Sendable {
    let comparison: GitComparison
    let before: String
    let after: String
    /// `after`'s commit, for the diff pages (their caption, comments).
    let afterCommit: GitCommit
    /// `head`'s commits that `base` doesn't have, newest first (up to a limit).
    let commits: [GitCommit]
    /// There are more commits than `commits`.
    let hasMoreCommits: Bool

    var title: String { comparison.title }
}
