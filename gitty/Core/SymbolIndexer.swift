import Foundation
import SwiftTreeSitter

/// Finds the top-level definitions in a source file, for any language in `SymbolLanguage.all`.
///
/// The language's query says what a definition is, using the tags.scm conventions:
/// `@definition.<kind>` on the definition and `@name` on its name (`@name.prefix` is shown before
/// it). This engine is the same for every language. It groups matches, keeps only top-level ones
/// and the members of container types (C# classes), names members `Type.Member`, and adds each
/// symbol's range (with the comment above it), line and preview.
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
        let builder = SymbolBuilder(text: original)
        let kept = keepTopLevel(definitions, language: language, builder: builder)
        return .symbols(kept.enumerated().map { index, item in
            builder.symbol(id: index, for: item.definition, name: item.name)
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
    /// for the same node, each with its own `@name`. Patterns that only add a `@name.prefix` (C#
    /// explicit interface implementations) also land on the same entry.
    private static func collectDefinitions(_ matches: QueryCursor) -> [Definition] {
        var order: [UInt] = []
        var byID: [UInt: Definition] = [:]
        for match in matches {
            guard let definition = match.captures.first(where: { $0.nameComponents.first == "definition" }),
                  definition.nameComponents.count > 1,
                  let kind = kind(for: definition.nameComponents[1])
            else { continue }
            let key = definition.node.id
            if byID[key] == nil {
                byID[key] = Definition(node: definition.node, kind: kind, names: [], prefix: nil)
                order.append(key)
            }
            for capture in match.captures {
                switch capture.nameComponents {
                case ["name"] where !(byID[key]!.names.contains(capture.range)):
                    byID[key]!.names.append(capture.range)
                case ["name", "prefix"]:
                    byID[key]!.prefix = capture.range
                default:
                    break
                }
            }
        }
        return order.compactMap { byID[$0] }.filter { !$0.names.isEmpty }
    }

    /// tags.scm kinds → what Symbols mode shows. Other kinds (references, modules…) are ignored.
    private static func kind(for tagKind: String) -> CodeSymbol.Kind? {
        switch tagKind {
        case "function": .function
        case "method": .method
        case "class", "struct", "interface", "type", "enum": .type
        case "macro": .macro
        case "variable", "constant": .global
        case "property": .property
        case "field": .field
        case "enum_member": .enumMember
        default: nil
        }
    }

    /// Keeps top-level definitions and the members of container types, in file order, each with
    /// its full name (`Circle.Inner.Value`). Drops a definition when it's inside a body (locals,
    /// struct fields, parameters, C# method bodies) or inside a definition that isn't a container
    /// (the struct inside C's `typedef struct {…} Size;`).
    private static func keepTopLevel(
        _ definitions: [Definition], language: SymbolLanguage, builder: SymbolBuilder
    ) -> [(definition: Definition, name: String)] {
        let byID = Dictionary(definitions.map { ($0.node.id, $0) }, uniquingKeysWith: { first, _ in first })
        let sorted = definitions.sorted {
            $0.node.range.location != $1.node.range.location
                ? $0.node.range.location < $1.node.range.location
                : $0.node.range.length > $1.node.range.length  // a type before its members
        }
        var kept: [(definition: Definition, name: String)] = []
        nextDefinition: for definition in sorted {
            var containers: [String] = []
            var current = definition.node.parent
            while let ancestor = current {
                let type = ancestor.nodeType ?? ""
                if language.bodyNodeTypes.contains(type) { continue nextDefinition }
                if let enclosing = byID[ancestor.id] {
                    guard language.containerNodeTypes.contains(type) else { continue nextDefinition }
                    containers.insert(builder.simpleName(of: enclosing), at: 0)
                }
                current = ancestor.parent
            }
            kept.append((definition, (containers + [builder.simpleName(of: definition)]).joined(separator: ".")))
        }
        return kept
    }
}

/// Turns a definition into a `CodeSymbol`: name, range with the comment above it, line, preview.
nonisolated private struct SymbolBuilder {
    let text: NSString

    /// The definition's own name: its `@name`s joined with ", ", after its `@name.prefix`. A space
    /// follows a prefix that ends in a letter or digit (`struct point`, `operator +`), but not one
    /// that ends in punctuation (`~Circle`, `IList.Add`).
    func simpleName(of definition: SymbolIndexer.Definition) -> String {
        let names = definition.names.map { text.substring(with: $0) }.joined(separator: ", ")
        guard let range = definition.prefix else { return names }
        let prefix = text.substring(with: range)
        guard let last = prefix.last else { return names }
        return prefix + (last.isLetter || last.isNumber ? " " : "") + names
    }

    func symbol(id: Int, for definition: SymbolIndexer.Definition, name: String) -> CodeSymbol {
        let node = definition.node
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
