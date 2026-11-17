import Foundation

/// Recently opened URLs, most recent first, shown while the address bar is being edited.
nonisolated struct RecentFilesStore: @unchecked Sendable {
    static let standard = RecentFilesStore(defaults: .standard)
    static let limit = 50

    private let defaults: UserDefaults
    private let key = "recentFiles"

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    func urls() -> [URL] {
        (defaults.stringArray(forKey: key) ?? []).compactMap { URL(string: $0) }
    }

    /// Moves `url` to the front, adding it if it's new.
    func add(_ url: URL) {
        var list = defaults.stringArray(forKey: key) ?? []
        list.removeAll { $0 == url.absoluteString }
        list.insert(url.absoluteString, at: 0)
        defaults.set(Array(list.prefix(Self.limit)), forKey: key)
    }

    func remove(_ url: URL) {
        var list = defaults.stringArray(forKey: key) ?? []
        list.removeAll { $0 == url.absoluteString }
        defaults.set(list, forKey: key)
    }
}
