import Foundation

/// How the Project tab and Symbols order their files: the sort button beside the mode selector.
nonisolated enum ListOrder: String, Codable, CaseIterable, Sendable {
    /// By path, A–Z (directory headers in the Project tab).
    case name
    /// The files you opened last first; files never opened after them, by name.
    case recentlyOpened
}

nonisolated struct ListSorting: Codable, Equatable, Sendable {
    var order: ListOrder = .name
    /// Name: Z–A. Recently opened: the files opened longest ago first (never-opened files stay
    /// after them, A–Z).
    var isReversed = false

    /// Files in this order. Recently opened needs `history`, from `OpenHistory`.
    /// - Parameters:
    ///   - key: the file's URL string, as `OpenHistory` keeps it (`nil`: never opened).
    ///   - name: what to sort by name: its path.
    func arrange<Item>(_ items: [Item], key: (Item) -> String?, name: (Item) -> String,
                       history: [String: Date]) -> [Item] {
        switch order {
        case .name:
            return isReversed ? items.reversed() : items  // items come in name order
        case .recentlyOpened:
            var opened: [(item: Item, date: Date)] = []
            var never: [Item] = []
            for item in items {
                if let key = key(item), let date = history[key] {
                    opened.append((item, date))
                } else {
                    never.append(item)
                }
            }
            opened.sort { isReversed ? $0.date < $1.date : $0.date > $1.date }
            never.sort { name($0).localizedStandardCompare(name($1)) == .orderedAscending }
            return opened.map { $0.item } + never
        }
    }
}

/// Each project's sorting for each view, saved in `UserDefaults` on this device.
nonisolated struct ListSortingStore: @unchecked Sendable {
    enum Tab: String {
        case project, symbols
    }

    static let standard = ListSortingStore(defaults: .standard)

    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// - Parameter projectID: the project's id ("" for files that aren't in one).
    func sorting(for tab: Tab, projectID: String) -> ListSorting {
        guard let data = defaults.data(forKey: key(tab, projectID)),
              let sorting = try? JSONDecoder().decode(ListSorting.self, from: data)
        else { return ListSorting() }
        return sorting
    }

    func save(_ sorting: ListSorting, for tab: Tab, projectID: String) {
        if sorting == ListSorting() {
            defaults.removeObject(forKey: key(tab, projectID))
        } else if let data = try? JSONEncoder().encode(sorting) {
            defaults.set(data, forKey: key(tab, projectID))
        }
    }

    private func key(_ tab: Tab, _ projectID: String) -> String {
        "listSorting:\(tab.rawValue):\(projectID)"
    }
}

/// When each file was last opened, for recently opened order. Read from disk once, then kept
/// in memory; each open updates one entry and saves the (small) file. Sorting a project by it
/// costs a dictionary lookup per file.
actor OpenHistory {
    static let shared = OpenHistory()

    /// The most files remembered; the ones opened longest ago go first.
    static let limit = 10_000

    private let fileURL: URL
    private var dates: [String: Date]?

    init(directory: URL = .applicationSupportDirectory) {
        fileURL = directory.appending(path: "OpenHistory.json")
    }

    /// When each file was last opened, by URL string.
    func snapshot() -> [String: Date] {
        load()
    }

    func recordOpen(_ url: URL, at date: Date = .now) {
        var dates = load()
        dates[url.absoluteString] = date
        if dates.count > Self.limit {
            let oldest = dates.sorted { $0.value < $1.value }.prefix(dates.count - Self.limit)
            for (key, _) in oldest { dates[key] = nil }
        }
        self.dates = dates
        save(dates)
    }

    func remove(_ url: URL) {
        var dates = load()
        guard dates.removeValue(forKey: url.absoluteString) != nil else { return }
        self.dates = dates
        save(dates)
    }

    private func load() -> [String: Date] {
        if let dates { return dates }
        let loaded = (try? Data(contentsOf: fileURL))
            .flatMap { try? JSONDecoder().decode([String: Date].self, from: $0) } ?? [:]
        dates = loaded
        return loaded
    }

    private func save(_ dates: [String: Date]) {
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(dates) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
