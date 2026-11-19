import Foundation
import SwiftTreeSitter

/// What a piece of code is, for its color. Each theme gives each one a color (or none).
nonisolated enum SyntaxCategory: UInt8, CaseIterable, Sendable {
    case keyword, string, comment, number, constant, type, function, property, attribute, preprocessor

    /// The category for a highlights query capture (`@keyword.function`, `@string.escape`…);
    /// `nil` for plain text (`@variable`, `@operator`, `@punctuation.bracket`…).
    init?(capture: String) {
        func isOrUnder(_ name: String) -> Bool { capture == name || capture.hasPrefix(name + ".") }
        if isOrUnder("comment") { self = .comment }
        else if isOrUnder("string") || isOrUnder("character") { self = .string }
        else if isOrUnder("number") || isOrUnder("boolean") || capture == "constant.builtin" { self = .number }
        else if capture == "keyword.directive" || capture == "function.special" || capture == "function.macro"
                    || capture == "constant.macro" { self = .preprocessor }
        else if isOrUnder("constant") { self = .constant }
        else if isOrUnder("keyword") || capture == "variable.builtin" || isOrUnder("label") { self = .keyword }
        else if isOrUnder("type") || isOrUnder("constructor") || isOrUnder("module") { self = .type }
        else if isOrUnder("function") { self = .function }
        else if isOrUnder("property") || capture == "variable.member" { self = .property }
        else if isOrUnder("attribute") { self = .attribute }
        else { return nil }
    }
}

/// Syntax highlighting with each grammar's own highlights query: the code split into runs, each
/// with its category (`nil`: plain). Safe to use off the main thread.
nonisolated enum SyntaxHighlighter {
    /// One stretch of text and what it is.
    nonisolated struct Run: Equatable, Sendable {
        let range: NSRange
        let category: SyntaxCategory?
    }

    /// The text as runs that cover it end to end, or `nil` for a file type without a grammar.
    /// Works on part of a file too (one symbol's code, a card's first lines): tree-sitter makes
    /// what it can of it.
    static func runs(in text: String, fileExtension: String) -> [Run]? {
        guard let language = SymbolLanguage.forExtension(fileExtension) else { return nil }
        let original = text as NSString
        let length = original.length
        guard length > 0 else { return [] }
        let prepared = language.prepare(original)  // same length: ranges match
        let parser = Parser()
        guard (try? parser.setLanguage(language.language)) != nil, let tree = parser.parse(prepared) else {
            return [Run(range: NSRange(location: 0, length: length), category: nil)]
        }

        // Every capture, then painted in order: bigger nodes first, so what's inside them wins
        // (an escape in a string); for the same node, later patterns win, as these queries are
        // written (`(identifier) @variable` first, the more specific ones after).
        struct Capture { let range: NSRange; let pattern: Int; let category: SyntaxCategory? }
        var captures: [Capture] = []
        let matches = language.highlightsQuery.execute(in: tree).resolve(with: .init(string: prepared))
        for match in matches {
            for capture in match.captures {
                guard let name = capture.name, name != "spell" else { continue }
                let range = capture.range
                guard range.length > 0, NSMaxRange(range) <= length else { continue }
                captures.append(Capture(range: range, pattern: match.patternIndex,
                                        category: SyntaxCategory(capture: name)))
            }
        }
        captures.sort { $0.range.length != $1.range.length ? $0.range.length > $1.range.length : $0.pattern < $1.pattern }

        let plain = UInt8.max
        var painted = [UInt8](repeating: plain, count: length)
        for capture in captures {
            let value = capture.category?.rawValue ?? plain
            for index in capture.range.location..<NSMaxRange(capture.range) { painted[index] = value }
        }

        var runs: [Run] = []
        var start = 0
        for index in 1...length where index == length || painted[index] != painted[start] {
            let value = painted[start]
            runs.append(Run(range: NSRange(location: start, length: index - start),
                            category: value == plain ? nil : SyntaxCategory(rawValue: value)))
            start = index
        }
        return runs
    }
}
