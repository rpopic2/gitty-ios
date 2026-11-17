import Foundation
import SwiftTreeSitter

/// Finds the top-level definitions in a source file, for any language in `SymbolLanguage.all`.
///
/// The language's query says what a definition is, using the tags.scm conventions:
/// `@definition.<kind>` on the definition and `@name` on its name (`@name.prefix` is shown before
/// it). This engine is the same for every language. It groups matches, keeps only top-level ones,
/// and adds each symbol's range (with the comment above it), line and preview.
nonisolated enum SymbolIndexer {
    enum Outcome: Sendable {
        case symbols([CodeSymbol])
        case unsupportedLanguage
    }

    static let previewLineCount = 6

    static func index(_ text: String, fileExtension: String) -> Outcome {
        guard let language = SymbolLanguage.forExtension(fileExtension) else { return .unsupportedLanguage }
        let original = text as NSString
        let parser = Parser()
        // `parse(_:)` feeds the text as UTF-16, so node ranges are NSRanges into the same text.
        // `prepare` keeps the length, so ranges into the prepared text work on the original too.
        guard (try? parser.setLanguage(language.language)) != nil,
              let tree = parser.parse(language.prepare(original))
        else { return .symbols([]) }

        let definitions = collectDefinitions(language.query.execute(in: tree))
        let topLevel = keepTopLevel(definitions, bodyNodeTypes: language.bodyNodeTypes)
        let builder = SymbolBuilder(text: original)
        return .symbols(topLevel.enumerated().map { index, definition in
            builder.symbol(id: index, for: definition)
        })
    }

    // MARK: - Matches → definitions

    nonisolated struct Definition {
        let node: Node
        let kind: CodeSymbol.Kind
        var names: [NSRange]
        var prefix: NSRange?
    }

    /// One entry per definition node. Several declarators (`int a, b;`) arrive as several matches
    /// for the same node, each with its own `@name`.
    private static func collectDefinitions(_ matches: QueryCursor) -> [Definition] {
        var order: [NSRange] = []
        var byRange: [NSRange: Definition] = [:]
        for match in matches {
            guard let definition = match.captures.first(where: { $0.nameComponents.first == "definition" }),
                  definition.nameComponents.count > 1,
                  let kind = kind(for: definition.nameComponents[1])
            else { continue }
            let key = definition.node.range
            if byRange[key] == nil {
                byRange[key] = Definition(node: definition.node, kind: kind, names: [], prefix: nil)
                order.append(key)
            }
            for capture in match.captures {
                switch capture.nameComponents {
                case ["name"] where !(byRange[key]!.names.contains(capture.range)):
                    byRange[key]!.names.append(capture.range)
                case ["name", "prefix"]:
                    byRange[key]!.prefix = capture.range
                default:
                    break
                }
            }
        }
        return order.compactMap { byRange[$0] }.filter { !$0.names.isEmpty }
    }

    /// tags.scm kinds → what Symbols mode shows. Other kinds (references, modules…) are ignored.
    private static func kind(for tagKind: String) -> CodeSymbol.Kind? {
        switch tagKind {
        case "function", "method": .function
        case "class", "struct", "interface", "type", "enum": .type
        case "macro": .macro
        case "variable", "constant": .global
        default: nil
        }
    }

    /// Drops definitions inside bodies (locals, fields, parameters) and inside other definitions
    /// (the struct inside `typedef struct {…} Size;`), so the outermost one wins.
    private static func keepTopLevel(_ definitions: [Definition], bodyNodeTypes: Set<String>) -> [Definition] {
        let sorted = definitions.sorted {
            $0.node.range.location != $1.node.range.location
                ? $0.node.range.location < $1.node.range.location
                : $0.node.range.length > $1.node.range.length  // outer first
        }
        var kept: [Definition] = []
        var keptEnd = 0  // syntax nodes nest, so "inside a kept one" means "ends before keptEnd"
        for definition in sorted {
            let range = definition.node.range
            if range.location < keptEnd && NSMaxRange(range) <= keptEnd { continue }
            if hasAncestor(definition.node, in: bodyNodeTypes) { continue }
            kept.append(definition)
            keptEnd = max(keptEnd, NSMaxRange(range))
        }
        return kept
    }

    private static func hasAncestor(_ node: Node, in types: Set<String>) -> Bool {
        var current = node.parent
        while let ancestor = current {
            if let type = ancestor.nodeType, types.contains(type) { return true }
            current = ancestor.parent
        }
        return false
    }
}

/// Turns a definition into a `CodeSymbol`: name, range with the comment above it, line, preview.
nonisolated private struct SymbolBuilder {
    let text: NSString

    func symbol(id: Int, for definition: SymbolIndexer.Definition) -> CodeSymbol {
        let node = definition.node
        var name = definition.names.map { text.substring(with: $0) }.joined(separator: ", ")
        if let prefix = definition.prefix {
            name = text.substring(with: prefix) + " " + name
        }
        let body = trimmingTrailingWhitespace(node.range)
        let start = leadingComment(of: node)?.range.location ?? body.location
        return CodeSymbol(
            id: id,
            name: name,
            kind: definition.kind,
            range: NSRange(location: start, length: NSMaxRange(body) - start),
            line: Int(node.pointRange.lowerBound.row) + 1,
            preview: preview(of: body)
        )
    }

    /// The first comment of the block directly above the node: no blank line in between, and not
    /// a trailing comment on the line of the code before it.
    private func leadingComment(of node: Node) -> Node? {
        var first: Node?
        var rowBelow = Int(node.pointRange.lowerBound.row)
        var sibling = node.previousNamedSibling
        while let comment = sibling, isComment(comment) {
            let row = Int(comment.pointRange.lowerBound.row)
            guard Int(comment.pointRange.upperBound.row) + 1 >= rowBelow else { break }  // blank line
            if let before = comment.previousNamedSibling, !isComment(before), endRow(of: before) == row {
                break  // `int x; // note` belongs to the line it's on
            }
            first = comment
            rowBelow = row
            sibling = comment.previousNamedSibling
        }
        return first
    }

    private func isComment(_ node: Node) -> Bool {
        node.nodeType?.contains("comment") == true  // comment, line_comment, block_comment…
    }

    /// The last row a node covers. Nodes that include their newline (`#define`) end at column 0 of
    /// the next line, which would make a comment on that line look like a trailing comment.
    private func endRow(of node: Node) -> Int {
        let range = node.pointRange
        let row = Int(range.upperBound.row)
        return range.upperBound.column == 0 && range.upperBound.row > range.lowerBound.row ? row - 1 : row
    }

    /// `#define` nodes include their newline; drop trailing whitespace so ranges end at the code.
    private func trimmingTrailingWhitespace(_ range: NSRange) -> NSRange {
        var end = NSMaxRange(range)
        while end > range.location,
              let scalar = Unicode.Scalar(text.character(at: end - 1)),
              CharacterSet.whitespacesAndNewlines.contains(scalar) {
            end -= 1
        }
        return NSRange(location: range.location, length: end - range.location)
    }

    private func preview(of range: NSRange) -> String {
        text.substring(with: range)
            .split(separator: "\n", maxSplits: SymbolIndexer.previewLineCount, omittingEmptySubsequences: false)
            .prefix(SymbolIndexer.previewLineCount)
            .map { $0.replacingOccurrences(of: "\t", with: "    ").replacingOccurrences(of: "\r", with: "") }
            .joined(separator: "\n")
    }
}
