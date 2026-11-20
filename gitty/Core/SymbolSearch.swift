import Foundation

/// Fuzzy symbol search, like Xcode's Open Quickly: the typed letters must appear in order in the
/// name, but not necessarily next to each other ("crdr" finds `Circle.draw`). Case doesn't matter.
///
/// Spaces separate words: "read regable" finds `read_regable`, `readRegable` and `Reader.regable`,
/// and "regable read" finds them too, a little lower. Each typed word must start a word of the
/// name, where names split at `_`, `.`, other punctuation and camelCase.
nonisolated enum SymbolSearch {
    /// The symbols that match `query`, best first. Equally good matches keep file order.
    /// An empty query matches everything, in file order. (Synchronous; the app uses `stream`.)
    static func matches(_ query: String, in symbols: [CodeSymbol]) -> [CodeSymbol] {
        let query = Query(query)
        guard !query.text.isEmpty else { return symbols }
        let index = Index(symbols)
        var found: [Ranked] = []
        collect(query, in: index, index.entries.indices, into: &found)
        return snapshot(found)
    }

    // MARK: - Searching in the background

    /// The names of a list of symbols, prepared once for searching: lowercased, with their
    /// member names and words, so a search doesn't work them out again on every keystroke.
    nonisolated struct Index: Sendable {
        let symbols: [CodeSymbol]
        let entries: [Entry]

        init(_ symbols: [CodeSymbol]) {
            self.symbols = symbols
            entries = symbols.map { Entry($0.name) }
        }

        nonisolated struct Entry: Sendable {
            let full: String
            let member: String
            let fullWords: [String]
            let memberWords: [String]

            /// - Parameter separator: what the name's last part follows, which counts most (a
            ///   member's `.`; a branch's `/`).
            init(_ name: String, separator: Character = ".") {
                full = name.lowercased()
                member = SymbolSearch.memberName(full, separator: separator)
                fullWords = SymbolSearch.words(of: name)
                memberWords = SymbolSearch.words(of: SymbolSearch.memberName(name, separator: separator))
            }
        }
    }

    /// How many names are ranked between checks for a newer search and snapshots.
    static let chunkSize = 2_000

    /// How long a search runs before it shows what it has found so far, and how often after
    /// that. Each snapshot redraws the list on the main thread, so a search that finishes
    /// within this shows its results once, complete.
    static let snapshotInterval = Duration.milliseconds(100)

    /// The search, in the background: snapshots of the matches found so far, best first (equal
    /// matches in list order), each one including all the earlier ones. The complete list comes
    /// last; before it, only on a search that takes a while: the first after
    /// `snapshotInterval` (even if empty, so the previous search's results go), then one at most
    /// every `snapshotInterval` while new matches turn up. Stop
    /// listening (cancel the task that's iterating) and the search stops too. An empty query
    /// gives every symbol, in one snapshot.
    static func stream(_ text: String, in index: Index) -> AsyncStream<[CodeSymbol]> {
        let query = Query(text)
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let producer = Task.detached(priority: .userInitiated) {
                guard !query.text.isEmpty else {
                    continuation.yield(index.symbols)
                    continuation.finish()
                    return
                }
                let count = index.entries.count
                var found: [Ranked] = []
                var start = 0
                var hasYielded = false
                var hasNew = false
                var lastYield = ContinuousClock.now  // the start, until the first snapshot
                repeat {
                    guard !Task.isCancelled else {
                        continuation.finish()
                        return
                    }
                    let end = min(start + chunkSize, count)
                    let before = found.count
                    collect(query, in: index, start..<end, into: &found)
                    hasNew = hasNew || found.count > before
                    start = end
                    let now = ContinuousClock.now
                    if start < count, now - lastYield >= snapshotInterval, !hasYielded || hasNew {
                        continuation.yield(snapshot(found))
                        hasYielded = true
                        hasNew = false
                        lastYield = now
                    }
                } while start < count
                if !Task.isCancelled { continuation.yield(snapshot(found)) }
                continuation.finish()
            }
            continuation.onTermination = { _ in producer.cancel() }
        }
    }

    /// What was typed, prepared once per search.
    nonisolated struct Query: Sendable {
        /// Lowercased, without spaces at the ends.
        let text: String
        let hasSpaces: Bool
        /// With spaces: the words of each typed word.
        let words: [String]
        /// With spaces: the typed words, and all of them run together.
        let typed: [String]
        let joined: String

        init(_ raw: String) {
            text = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            hasSpaces = text.contains(where: \.isWhitespace)
            typed = text.split(whereSeparator: \.isWhitespace).map(String.init)
            words = typed.flatMap { SymbolSearch.words(of: $0) }
            joined = typed.joined()
        }
    }

    /// Ranks the names at `positions`, adding the matches to `found`.
    private static func collect<Positions: Sequence<Int>>(_ query: Query, in index: Index, _ positions: Positions,
                                                          into found: inout [Ranked]) {
        for position in positions {
            if let rank = rank(query, index.entries[position]) {
                found.append(Ranked(symbol: index.symbols[position], rank: rank))
            }
        }
    }

    private static func snapshot(_ found: [Ranked]) -> [CodeSymbol] {
        found.sorted(by: Ranked.isBetter).map { (match: Ranked) -> CodeSymbol in match.symbol }
    }

    /// A match and how good it is. (Spelled out instead of a tuple: a chain of closures over
    /// tuples was too slow for the type checker.)
    nonisolated private struct Ranked: Sendable {
        let symbol: CodeSymbol
        let rank: Int

        /// Better rank first; equal ranks keep file order.
        static func isBetter(_ lhs: Ranked, _ rhs: Ranked) -> Bool {
            if lhs.rank != rhs.rank { return lhs.rank < rhs.rank }
            return lhs.symbol.id < rhs.symbol.id
        }
    }

    // MARK: - Ranking

    /// Lower is better; `nil` means no match.
    ///
    /// Without spaces: 0 the member name is the query, 1 the full name is, 2 the member name
    /// starts with it, 3 the full name does, 4 the member name contains it, 5 the full name does,
    /// 6 its letters appear in order in the member name, 7 in the full name.
    ///
    /// With spaces: 0 the member name's words are the search's, 1 the full name's are, 2 the
    /// words start words of the member name in order, 3 of the full name in order, 4 of the
    /// member name in any order, 5 of the full name in any order, 6 every word appears in the
    /// name, 7 all the letters appear in order.
    static func rank(_ query: Query, _ entry: Index.Entry) -> Int? {
        guard query.hasSpaces else {
            let text = query.text
            if entry.member == text { return 0 }
            if entry.full == text { return 1 }
            if entry.member.hasPrefix(text) { return 2 }
            if entry.full.hasPrefix(text) { return 3 }
            if entry.member.contains(text) { return 4 }
            if entry.full.contains(text) { return 5 }
            if isSubsequence(text, of: entry.member) { return 6 }
            if isSubsequence(text, of: entry.full) { return 7 }
            return nil
        }
        guard !query.words.isEmpty else { return nil }
        if entry.memberWords == query.words { return 0 }
        if entry.fullWords == query.words { return 1 }
        if startsWordsInOrder(query.words, entry.memberWords) { return 2 }
        if startsWordsInOrder(query.words, entry.fullWords) { return 3 }
        if startsWordsInAnyOrder(query.words, entry.memberWords) { return 4 }
        if startsWordsInAnyOrder(query.words, entry.fullWords) { return 5 }
        if query.typed.allSatisfy({ entry.full.contains($0) }) { return 6 }
        if isSubsequence(query.joined, of: entry.full) { return 7 }
        return nil
    }

    /// `rank` for one query (lowercased, without spaces) and one name.
    static func rank(_ query: String, _ name: String) -> Int? {
        rank(Query(query), Index.Entry(name))
    }

    /// The words of a name, lowercased: split at anything that isn't a letter or digit and at
    /// camelCase boundaries. `readRegable` → read, regable; `HTTPServer` → http, server;
    /// `List.ICollection<T>.IsReadOnly` → list, i, collection, t, is, read, only.
    static func words(of name: String) -> [String] {
        let characters = Array(name)
        var words: [String] = []
        var current = ""
        for (index, character) in characters.enumerated() {
            guard character.isLetter || character.isNumber else {
                if !current.isEmpty { words.append(current) }
                current = ""
                continue
            }
            if let previous = current.last {
                let next: Character? = index + 1 < characters.count ? characters[index + 1] : nil
                let lowerToUpper = previous.isLowercase && character.isUppercase
                let endOfAcronym = previous.isUppercase && character.isUppercase && (next?.isLowercase ?? false)
                if lowerToUpper || endOfAcronym {
                    words.append(current)
                    current = ""
                }
            }
            current.append(character)
        }
        if !current.isEmpty { words.append(current) }
        return words.map { $0.lowercased() }
    }

    /// Each query word starts a later word of the name than the one before it.
    static func startsWordsInOrder(_ query: [String], _ words: [String]) -> Bool {
        var next = 0
        for word in words where next < query.count && word.hasPrefix(query[next]) {
            next += 1
        }
        return next == query.count
    }

    /// Each query word starts a different word of the name, in any order.
    static func startsWordsInAnyOrder(_ query: [String], _ words: [String]) -> Bool {
        var used = Array(repeating: false, count: words.count)
        func assign(_ index: Int) -> Bool {
            guard index < query.count else { return true }
            for (wordIndex, word) in words.enumerated() where !used[wordIndex] && word.hasPrefix(query[index]) {
                used[wordIndex] = true
                if assign(index + 1) { return true }
                used[wordIndex] = false
            }
            return false
        }
        return assign(0)
    }

    // MARK: - Searching for a selection

    /// What Search in the text menu searches for: a selected name without the punctuation around
    /// it (`read_regable(` → `read_regable`), otherwise the selected text with its spaces and line
    /// breaks collapsed (`read  regable` → `read regable`). `nil` when only spaces are selected.
    static func query(fromSelection selection: String) -> String? {
        if let name = searchTerm(fromSelection: selection) { return name }
        let words = selection.split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return nil }
        return String(words.joined(separator: " ").prefix(100))
    }

    /// The symbol a selected name refers to: a symbol whose full name is
    /// the name (`Circle` the type) first, otherwise the first one in file order whose own name is
    /// (`Circle.draw` for `draw`, `struct point` for `point`, `Pi, Tau` for `Tau`). Surrounding
    /// punctuation is ignored; text with spaces or no letters isn't a name.
    static func definition(named selection: String, in symbols: [CodeSymbol]) -> CodeSymbol? {
        guard let name = searchTerm(fromSelection: selection) else { return nil }
        if let exact = symbols.first(where: { $0.name == name }) { return exact }
        return symbols.first { definedNames(in: $0.name).contains(name) }
    }

    /// The name in a text selection: punctuation around it trimmed
    /// (`read_regable(` → `read_regable`). `nil` when it isn't a single name (spaces, no letters).
    static func searchTerm(fromSelection selection: String) -> String? {
        let name = selection.trimmingCharacters(in: CharacterSet.alphanumerics.union(["_"]).inverted)
        guard !name.isEmpty, !name.contains(where: \.isWhitespace),
              name.contains(where: { $0.isLetter || $0 == "_" })
        else { return nil }
        return name
    }

    /// The names a symbol defines: the part after the last dot, split at ", ", each without a
    /// leading keyword (`struct point` → `point`).
    static func definedNames(in name: String) -> [String] {
        memberName(name)
            .components(separatedBy: ", ")
            .compactMap { $0.split(separator: " ").last.map(String.init) }
    }

    /// The part after the last dot: `draw` in `Circle.draw`, `IsReadOnly` in
    /// `List.ICollection<T>.IsReadOnly`. Names without a dot are their own member name.
    static func memberName(_ name: String, separator: Character = ".") -> String {
        guard let dot = name.lastIndex(of: separator), name.index(after: dot) < name.endIndex else { return name }
        return String(name[name.index(after: dot)...])
    }

    /// Names (branches, say) that match `query`, best first (equal matches keep their order),
    /// ranked as symbols are. An empty query keeps them all.
    /// - Parameter separator: what a name's last part follows, which counts most (`/` for
    ///   branches: `parser` finds `feature/parser` before `parser-old/main`).
    static func matchingNames(_ query: String, in names: [String], separator: Character = "/") -> [String] {
        let query = Query(query)
        guard !query.text.isEmpty else { return names }
        return names.enumerated()
            .compactMap { index, name in rank(query, Index.Entry(name, separator: separator)).map { (name, $0, index) } }
            .sorted { $0.1 != $1.1 ? $0.1 < $1.1 : $0.2 < $1.2 }
            .map(\.0)
    }

    static func isSubsequence(_ query: String, of text: String) -> Bool {
        var remaining = query[...]
        for character in text where character == remaining.first {
            remaining = remaining.dropFirst()
            if remaining.isEmpty { return true }
        }
        return remaining.isEmpty
    }
}
