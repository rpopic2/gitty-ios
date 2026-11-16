import Foundation

/// Where the reader left off in a file.
///
/// It is stored as a text position, not a pixel offset, so it survives rotation, iPad split view
/// and refreshed text: `characterIndex` is the first character of the line at the top of the
/// screen, and `lineOffset` is how far (pt) that line was scrolled past the top.
nonisolated struct ReadingPosition: Codable, Equatable, Sendable {
    var characterIndex: Int
    var lineOffset: Double

    static let top = ReadingPosition(characterIndex: 0, lineOffset: 0)
}

/// Saves reading positions per file URL in `UserDefaults`: a few bytes per file, cheap to
/// write each time scrolling stops.
nonisolated struct ReadingPositionStore: @unchecked Sendable {
    static let standard = ReadingPositionStore(defaults: .standard)

    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    func position(for url: URL) -> ReadingPosition? {
        guard let data = defaults.data(forKey: key(for: url)) else { return nil }
        return try? JSONDecoder().decode(ReadingPosition.self, from: data)
    }

    func save(_ position: ReadingPosition, for url: URL) {
        guard let data = try? JSONEncoder().encode(position) else { return }
        defaults.set(data, forKey: key(for: url))
    }

    private func key(for url: URL) -> String {
        "readingPosition:" + url.absoluteString
    }
}
