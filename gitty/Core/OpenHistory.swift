import Foundation

/// When each file was last opened, for the file a project opens at (`ProjectStartFile`). Read
/// from disk once, then kept in memory; each open updates one entry and saves the (small) file.
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
