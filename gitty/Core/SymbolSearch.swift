import Foundation

/// Fuzzy symbol search, like Xcode's Open Quickly: the typed letters must appear in order in the
/// name, but not necessarily next to each other ("crdr" finds `Circle.draw`). Case doesn't matter.
///
/// Spaces separate words: "read regable" finds `read_regable`, `readRegable` and `Reader.regable`,
/// and "regable read" finds them too, a little lower. Each typed word must start a word of the
/// name, where names split at `_`, `.`, other punctuation and camelCase.
nonisolated enum SymbolSearch {
    /// The symbols that match `query`, best first. Equally good matches keep file order.
    /// An empty query matches everything, in file order.
    static func matches(_ query: String, in symbols: [CodeSymbol]) -> [CodeSymbol] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return symbols }

        let queryWords = query.split(whereSeparator: \.isWhitespace).flatMap { words(of: String($0)) }
        let hasSpaces = query.contains(where: \.isWhitespace)

        var ranked: [Ranked] = []
        for symbol in symbols {
            let score = hasSpaces
                ? rank(words: queryWords, query, symbol.name)
                : rank(query, symbol.name)
            if let score {
                ranked.append(Ranked(symbol: symbol, rank: score))
            }
        }
        ranked.sort(by: Ranked.isBetter)
        return ranked.map { (match: Ranked) -> CodeSymbol in match.symbol }
    }

    /// A match and how good it is. (Spelled out instead of a tuple: a chain of closures over
    /// tuples was too slow for the type checker.)
    nonisolated private struct Ranked {
        let symbol: CodeSymbol
        let rank: Int

        /// Better rank first; equal ranks keep file order.
        static func isBetter(_ lhs: Ranked, _ rhs: Ranked) -> Bool {
            if lhs.rank != rhs.rank { return lhs.rank < rhs.rank }
            return lhs.symbol.id < rhs.symbol.id
        }
    }

    /// Lower is better; `nil` means no match.
    /// 0 the member name is the query, 1 the full name is, 2 the member name starts with it,
    /// 3 the full name does, 4 the member name contains it, 5 the full name does,
    /// 6 its letters appear in order in the member name, 7 in the full name.
    static func rank(_ query: String, _ name: String) -> Int? {
        let full = name.lowercased()
        let member = memberName(full)
        if member == query { return 0 }
        if full == query { return 1 }
        if member.hasPrefix(query) { return 2 }
        if full.hasPrefix(query) { return 3 }
        if member.contains(query) { return 4 }
        if full.contains(query) { return 5 }
        if isSubsequence(query, of: member) { return 6 }
        if isSubsequence(query, of: full) { return 7 }
        return nil
    }

    /// Like `rank(_:_:)`, for a search with spaces. Lower is better; `nil` means no match.
    /// 0 the member name's words are the search's, 1 the full name's are, 2 the words start
    /// words of the member name in order, 3 of the full name in order, 4 of the member name in
    /// any order, 5 of the full name in any order, 6 every word appears in the name,
    /// 7 all the letters appear in order.
    static func rank(words query: [String], _ rawQuery: String, _ name: String) -> Int? {
        guard !query.isEmpty else { return nil }
        let fullWords = words(of: name)
        let memberWords = words(of: memberName(name))
        if memberWords == query { return 0 }
        if fullWords == query { return 1 }
        if startsWordsInOrder(query, memberWords) { return 2 }
        if startsWordsInOrder(query, fullWords) { return 3 }
        if startsWordsInAnyOrder(query, memberWords) { return 4 }
        if startsWordsInAnyOrder(query, fullWords) { return 5 }
        let full = name.lowercased()
        let typed = rawQuery.split(whereSeparator: \.isWhitespace).map(String.init)
        if typed.allSatisfy({ full.contains($0) }) { return 6 }
        if isSubsequence(typed.joined(), of: full) { return 7 }
        return nil
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

    // MARK: - Jump to Definition

    /// The symbol a selected name refers to, for Jump to Definition: a symbol whose full name is
    /// the name (`Circle` the type) first, otherwise the first one in file order whose own name is
    /// (`Circle.draw` for `draw`, `struct point` for `point`, `Pi, Tau` for `Tau`). Surrounding
    /// punctuation is ignored; text with spaces or no letters isn't a name.
    static func definition(named selection: String, in symbols: [CodeSymbol]) -> CodeSymbol? {
        guard let name = searchTerm(fromSelection: selection) else { return nil }
        if let exact = symbols.first(where: { $0.name == name }) { return exact }
        return symbols.first { definedNames(in: $0.name).contains(name) }
    }

    /// The name in a text selection, for Jump to Definition: punctuation around it trimmed
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
    static func memberName(_ name: String) -> String {
        guard let dot = name.lastIndex(of: "."), name.index(after: dot) < name.endIndex else { return name }
        return String(name[name.index(after: dot)...])
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
