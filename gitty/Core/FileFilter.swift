import Foundation

/// A project's file filter, such as `*.cs *.md` or `src/*.swift !*Tests.cs`: space-separated
/// globs. A file passes if it matches any pattern (or there are none) and no `!` pattern.
///
/// - A pattern without `/` matches the file name: `*.cs`, `README*`.
/// - A pattern with `/` matches the path inside the project, as the Project tab's headers show
///   it: `src/*.swift`. A pattern ending in `/` matches everything in that directory: `!Tests/`.
/// - `*` is any run of characters within one name, `**` crosses directories (`src/**/*.c` also
///   matches `src/a.c`), and `?` is one character.
/// - Case doesn't matter: `*.cs` matches `Main.CS`.
nonisolated struct FileFilter: Equatable, Sendable {
    /// What was typed.
    let text: String
    private let includes: [Pattern]
    private let excludes: [Pattern]

    init(_ text: String) {
        self.text = text
        var includes: [Pattern] = [], excludes: [Pattern] = []
        for token in text.split(whereSeparator: { $0.isWhitespace || $0 == "," }) {
            if token.hasPrefix("!") {
                if let pattern = Pattern(token.dropFirst()) { excludes.append(pattern) }
            } else if let pattern = Pattern(token) {
                includes.append(pattern)
            }
        }
        self.includes = includes
        self.excludes = excludes
    }

    static let none = FileFilter("")

    /// Lets every file through.
    var isEmpty: Bool { includes.isEmpty && excludes.isEmpty }

    /// - Parameter path: the file's path inside the project, without a leading `/`.
    func matches(_ path: String) -> Bool {
        guard !isEmpty else { return true }
        let path = Array(path.lowercased())
        let name = Array(path.split(separator: "/").last ?? [])
        if excludes.contains(where: { $0.matches(path: path, name: name) }) { return false }
        return includes.isEmpty || includes.contains { $0.matches(path: path, name: name) }
    }

    private nonisolated struct Pattern: Equatable, Sendable {
        let glob: [Character]
        let isPath: Bool
        /// `*.cs` and the like, the usual case: just the end of the name, without the matcher.
        let suffix: [Character]?

        init?(_ token: Substring) {
            var text = token.lowercased()
            while text.hasPrefix("/") { text.removeFirst() }
            if text.hasSuffix("/") { text += "**" }  // a directory: everything in it
            guard !text.isEmpty else { return nil }
            glob = Array(text)
            isPath = text.contains("/")
            let rest = text.dropFirst()
            suffix = text.hasPrefix("*") && !rest.contains(where: { "*?/".contains($0) }) ? Array(rest) : nil
        }

        func matches(path: [Character], name: [Character]) -> Bool {
            if let suffix {
                return name.count >= suffix.count && name.suffix(suffix.count).elementsEqual(suffix)
            }
            var matcher = GlobMatcher(pattern: glob, text: isPath ? path : name)
            return matcher.matches()
        }
    }
}

/// `*`, `**` and `?` against one string, remembering each (pattern, text) position it has
/// tried, so no pattern takes more than pattern × text steps.
private nonisolated struct GlobMatcher {
    let pattern: [Character]
    let text: [Character]
    private var tried: [Int: Bool] = [:]

    init(pattern: [Character], text: [Character]) {
        self.pattern = pattern
        self.text = text
    }

    mutating func matches() -> Bool {
        match(0, 0)
    }

    private mutating func match(_ p: Int, _ t: Int) -> Bool {
        let key = p * (text.count + 1) + t
        if let known = tried[key] { return known }
        let result = step(p, t)
        tried[key] = result
        return result
    }

    private mutating func step(_ p: Int, _ t: Int) -> Bool {
        guard p < pattern.count else { return t == text.count }
        switch pattern[p] {
        case "*" where p + 1 < pattern.count && pattern[p + 1] == "*":
            let next = p + 2
            // `**/` can also stand for no directories at all.
            if next < pattern.count, pattern[next] == "/", match(next + 1, t) { return true }
            for end in t...text.count where match(next, end) { return true }
            return false
        case "*":
            var end = t
            while true {
                if match(p + 1, end) { return true }
                guard end < text.count, text[end] != "/" else { return false }
                end += 1
            }
        case "?":
            return t < text.count && text[t] != "/" && match(p + 1, t + 1)
        case let character:
            return t < text.count && text[t] == character && match(p + 1, t + 1)
        }
    }
}

/// Each project's filter text, saved in `UserDefaults` on this device.
nonisolated struct ProjectFilterStore: @unchecked Sendable {
    static let standard = ProjectFilterStore(defaults: .standard)

    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    func text(for projectID: String) -> String {
        defaults.string(forKey: key(for: projectID)) ?? ""
    }

    func filter(for projectID: String) -> FileFilter {
        FileFilter(text(for: projectID))
    }

    func save(_ text: String, for projectID: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            defaults.removeObject(forKey: key(for: projectID))
        } else {
            defaults.set(trimmed, forKey: key(for: projectID))
        }
    }

    func remove(for projectID: String) {
        defaults.removeObject(forKey: key(for: projectID))
    }

    private func key(for projectID: String) -> String {
        "projectFilter:" + projectID
    }
}
