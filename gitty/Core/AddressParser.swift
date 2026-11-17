import Foundation

/// Turns what was typed into the address bar into the URL to load.
nonisolated enum AddressParser {
    enum Parsed: Equatable, Sendable {
        case url(URL)
        /// Not something we can open. The message says why.
        case invalid(String)
    }

    static let notAURL = "Enter a URL that starts with https://"
    static let notSecure = "Only https:// links can be opened."

    static func parse(_ input: String) -> Parsed {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: text),
              let scheme = url.scheme?.lowercased(),
              let host = url.host(), !host.isEmpty
        else { return .invalid(notAURL) }
        guard scheme == "https" else { return .invalid(scheme == "http" ? notSecure : notAURL) }
        return .url(rawGitHubURL(for: url) ?? url)
    }

    /// `github.com/owner/repo/blob/<ref>/<path>` (or `/raw/`) → `raw.githubusercontent.com/owner/repo/<ref>/<path>`,
    /// so a link copied from a GitHub page opens as the file itself. Anything else (other hosts, repo
    /// pages, folders) returns `nil` and is loaded as typed.
    static func rawGitHubURL(for url: URL) -> URL? {
        guard let host = url.host()?.lowercased(), host == "github.com" || host == "www.github.com" else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }  // owner, repo, blob, ref…, path…
        guard parts.count >= 5, parts[2] == "blob" || parts[2] == "raw" else { return nil }
        var components = URLComponents()
        components.scheme = "https"
        components.host = "raw.githubusercontent.com"
        components.path = "/" + ([parts[0], parts[1]] + parts[3...]).joined(separator: "/")
        return components.url  // drops `?plain=1` and `#L10`
    }
}

extension URL {
    /// The file name for the bar, or the host when the path has none (`https://example.com/`).
    var displayFileName: String {
        let name = lastPathComponent
        return name.isEmpty || name == "/" ? (host() ?? absoluteString) : name
    }

    /// Host and path, for the recent files list.
    var displayLocation: String {
        (host() ?? "") + path()
    }
}
