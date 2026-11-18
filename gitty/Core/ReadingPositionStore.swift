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

/// Where the reader left off in a file's Symbols list: the card in the middle of the screen.
///
/// Symbol ids are only positions in one version of the file, so it's stored as the symbol's name
/// and where it starts. After a refresh it finds the same symbol even if code above it changed.
nonisolated struct SymbolsPosition: Codable, Equatable, Sendable {
    var name: String
    var characterIndex: Int

    init(name: String, characterIndex: Int) {
        self.name = name
        self.characterIndex = characterIndex
    }

    init(_ symbol: CodeSymbol) {
        self.init(name: symbol.name, characterIndex: symbol.range.location)
    }

    /// The symbol to bring back: the one with this name nearest the saved place, or, if it's gone,
    /// whichever symbol starts nearest the saved place.
    func symbolID(in symbols: [CodeSymbol]) -> Int? {
        let sameName = symbols.filter { $0.name == name }
        let candidates = sameName.isEmpty ? symbols : sameName
        return candidates.min { lhs, rhs in
            abs(lhs.range.location - characterIndex) < abs(rhs.range.location - characterIndex)
        }?.id
    }
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

    func symbolsPosition(for url: URL) -> SymbolsPosition? {
        guard let data = defaults.data(forKey: symbolsKey(for: url)) else { return nil }
        return try? JSONDecoder().decode(SymbolsPosition.self, from: data)
    }

    func saveSymbolsPosition(_ position: SymbolsPosition, for url: URL) {
        guard let data = try? JSONEncoder().encode(position) else { return }
        defaults.set(data, forKey: symbolsKey(for: url))
    }

    /// Forgets both places in the file: File's and the Symbols list's.
    func remove(for url: URL) {
        defaults.removeObject(forKey: key(for: url))
        defaults.removeObject(forKey: symbolsKey(for: url))
    }

    private func key(for url: URL) -> String {
        "readingPosition:" + url.absoluteString
    }

    private func symbolsKey(for url: URL) -> String {
        "symbolsPosition:" + url.absoluteString
    }
}
