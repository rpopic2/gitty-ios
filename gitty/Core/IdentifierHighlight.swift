import Foundation
import SwiftTreeSitter

/// The identifier highlighted on pages (Highlight in the text menu): one at a time, on every
/// page until it's removed.
nonisolated struct IdentifierHighlight: Equatable, Sendable {
    let name: String
    /// The tree-sitter node type it was chosen on (`type_identifier`, `field_identifier`…), and
    /// its language. `nil` for a word chosen on a page without a grammar.
    let kind: String?
    let language: String?
}

/// A page's identifiers, found with tree-sitter, for Highlight. Pages in a language with a
/// grammar match identifier nodes only (never comments or strings): in the same language, of the
/// same node type as the highlight (so the type `Point` doesn't mark a field named `Point`); in
/// another language, of any identifier type. Pages without one match whole words, exact case.
nonisolated struct IdentifierMap: Sendable {
    nonisolated struct Item: Sendable {
        let range: NSRange
        let kind: String
        let name: String
    }

    /// The page's language; `nil` without a grammar.
    let language: String?
    /// In text order.
    let items: [Item]
    /// The text, for pages without a grammar.
    private let text: String

    /// Parses the page's text (a whole file, or one symbol's part of it).
    init(text: String, fileExtension: String) {
        self.text = text
        guard let language = SymbolLanguage.forExtension(fileExtension) else {
            self.language = nil
            items = []
            return
        }
        self.language = language.name
        let original = text as NSString
        let parser = Parser()
        // Ranges are UTF-16, into the same text (see `SymbolIndexer.index`).
        guard (try? parser.setLanguage(language.language)) != nil,
              let root = parser.parse(language.prepare(original))?.rootNode
        else {
            items = []
            return
        }
        var found: [Item] = []
        // Depth first, children in order, so the leaves come in text order.
        var stack: [Node] = [root]
        while let node = stack.popLast() {
            let count = node.childCount
            if count == 0 {
                if let kind = node.nodeType, Self.isIdentifier(kind), node.range.length > 0,
                   NSMaxRange(node.range) <= original.length {
                    found.append(Item(range: node.range, kind: kind, name: original.substring(with: node.range)))
                }
                continue
            }
            for index in stride(from: count - 1, through: 0, by: -1) {
                if let child = node.child(at: index) { stack.append(child) }
            }
        }
        items = found
    }

    /// `identifier`, `type_identifier`, `field_identifier`, Swift's `simple_identifier`…
    static func isIdentifier(_ kind: String) -> Bool {
        kind.hasSuffix("identifier")
    }

    /// The identifier the selection is inside (it may be just part of it), if it's inside one.
    func identifier(containing selection: NSRange) -> IdentifierHighlight? {
        guard let language else { return word(containing: selection) }
        // The last identifier starting at or before the selection.
        var low = 0, high = items.count
        while low < high {
            let middle = (low + high) / 2
            if items[middle].range.location <= selection.location { low = middle + 1 } else { high = middle }
        }
        guard low > 0 else { return nil }
        let item = items[low - 1]
        guard NSMaxRange(selection) <= NSMaxRange(item.range) else { return nil }
        return IdentifierHighlight(name: item.name, kind: item.kind, language: language)
    }

    /// Where the highlight occurs on this page.
    func occurrences(of highlight: IdentifierHighlight) -> [NSRange] {
        guard let language else { return wholeWords(highlight.name) }
        let sameKind = highlight.language == language ? highlight.kind : nil
        return items.compactMap { item in
            guard item.name == highlight.name, sameKind == nil || item.kind == sameKind else { return nil }
            return item.range
        }
    }

    // MARK: Without a grammar

    private static func isWordCharacter(_ unit: unichar) -> Bool {
        guard let scalar = Unicode.Scalar(unit) else { return false }
        return scalar == "_" || CharacterSet.alphanumerics.contains(scalar)
    }

    private func word(containing selection: NSRange) -> IdentifierHighlight? {
        let text = self.text as NSString
        guard NSMaxRange(selection) <= text.length else { return nil }
        for offset in 0..<selection.length where !Self.isWordCharacter(text.character(at: selection.location + offset)) {
            return nil  // more than one word
        }
        var start = selection.location
        while start > 0, Self.isWordCharacter(text.character(at: start - 1)) { start -= 1 }
        var end = NSMaxRange(selection)
        while end < text.length, Self.isWordCharacter(text.character(at: end)) { end += 1 }
        guard end > start else { return nil }
        return IdentifierHighlight(name: text.substring(with: NSRange(location: start, length: end - start)),
                                   kind: nil, language: nil)
    }

    private func wholeWords(_ name: String) -> [NSRange] {
        let pattern = "(?<![\\p{L}\\p{N}_])" + NSRegularExpression.escapedPattern(for: name) + "(?![\\p{L}\\p{N}_])"
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        let text = self.text
        return expression.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length))
            .map(\.range)
    }
}
