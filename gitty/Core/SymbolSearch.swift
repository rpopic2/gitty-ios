import Foundation

/// Fuzzy symbol search, like Xcode's Open Quickly: the typed letters must appear in order in the
/// name, but not necessarily next to each other ("crdr" finds `Circle.draw`). Case doesn't matter.
nonisolated enum SymbolSearch {
    /// The symbols that match `query`, best first. Equally good matches keep file order.
    /// An empty query matches everything, in file order.
    static func matches(_ query: String, in symbols: [CodeSymbol]) -> [CodeSymbol] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return symbols }

        var ranked: [Ranked] = []
        for symbol in symbols {
            if let score = rank(query, symbol.name) {
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
