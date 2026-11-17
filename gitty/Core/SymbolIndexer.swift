import Foundation
import SwiftTreeSitter
import TreeSitterC

/// Finds the top-level definitions in a source file with tree-sitter.
nonisolated enum SymbolIndexer {
    enum Outcome: Sendable {
        case symbols([CodeSymbol])
        case unsupportedLanguage
    }

    static let previewLineCount = 6

    static func index(_ text: String, fileExtension: String) -> Outcome {
        guard ["c", "h"].contains(fileExtension.lowercased()) else { return .unsupportedLanguage }
        let original = text as NSString
        let parser = Parser()
        // `parse(_:)` feeds the text as UTF-16, so node ranges are NSRanges into the same text.
        // The blanked copy has the same length, so its ranges work on the original too.
        guard (try? parser.setLanguage(Language(tree_sitter_c()))) != nil,
              let tree = parser.parse(blankingTopLevelMacroCalls(in: original)),
              let root = tree.rootNode
        else { return .symbols([]) }
        var walker = CWalker(text: original)
        walker.visitChildren(of: root)
        return .symbols(walker.symbols)
    }

    /// tree-sitter can't expand macros. A top-level macro call without a semicolon, such as
    /// `OPT_GENERIC(i64)`, reads as a function's return type, and everything after it becomes one
    /// giant function. Like ctags, replace such calls with spaces before parsing. Every other
    /// character stays where it was, so ranges and line numbers don't move.
    ///
    /// A call is a line that starts at column 0 with `NAME(` and, after the matching `)` (which may
    /// be on a later line), has nothing but an optional `;`. It is left alone when `{` follows (an
    /// old-style function definition), or when the line before doesn't end a statement, as in GNU
    /// style `static int` / `foo(int x);`, where it's the second half of a declaration.
    static func blankingTopLevelMacroCalls(in text: NSString) -> String {
        let count = text.length
        var units = [unichar](repeating: 0, count: count)
        text.getCharacters(&units, range: NSRange(location: 0, length: count))

        func isIdentifierStart(_ c: unichar) -> Bool {
            (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95  // A-Z a-z _
        }
        func isIdentifier(_ c: unichar) -> Bool {
            isIdentifierStart(c) || (c >= 48 && c <= 57)
        }
        func isBlank(_ c: unichar) -> Bool { c == 32 || c == 9 || c == 13 }  // space, tab, CR
        let newline: unichar = 10, space: unichar = 32, quote: unichar = 34, apostrophe: unichar = 39,
            backslash: unichar = 92, open: unichar = 40, close: unichar = 41, semicolon: unichar = 59,
            brace: unichar = 123

        func endOfLine(from index: Int) -> Int {
            var i = index
            while i < count, units[i] != newline { i += 1 }
            return i
        }

        /// True when the previous non-blank line ends a statement or is a directive or comment.
        func previousLineEndsStatement(before lineStart: Int) -> Bool {
            var last = lineStart - 1
            while last >= 0, isBlank(units[last]) || units[last] == newline { last -= 1 }
            guard last >= 0 else { return true }  // start of the file
            var first = last
            while first > 0, units[first - 1] != newline { first -= 1 }
            while first < last, isBlank(units[first]) { first += 1 }

            let hash: unichar = 35, slash: unichar = 47, star: unichar = 42, closeBrace: unichar = 125
            if units[first] == hash { return true }  // preprocessor directive
            if units[first] == slash, first + 1 <= last, units[first + 1] == slash { return true }  // // comment
            switch units[last] {
            case semicolon, closeBrace, brace, close: return true
            case slash: return last > first && units[last - 1] == star  // end of /* comment */
            default: return false
            }
        }

        var lineStart = 0
        while lineStart < count {
            let lineEnd = endOfLine(from: lineStart)
            defer { lineStart = lineEnd + 1 }
            guard isIdentifierStart(units[lineStart]) else { continue }

            var i = lineStart
            while i < count, isIdentifier(units[i]) { i += 1 }
            while i < count, isBlank(units[i]) { i += 1 }
            guard i < count, units[i] == open else { continue }

            // Find the matching `)`, skipping string and character literals.
            var depth = 0
            while i < count {
                let c = units[i]
                if c == quote || c == apostrophe {
                    i += 1
                    while i < count, units[i] != c, units[i] != newline {
                        i += units[i] == backslash ? 2 : 1
                    }
                } else if c == open {
                    depth += 1
                } else if c == close {
                    depth -= 1
                    if depth == 0 { break }
                }
                i += 1
            }
            guard depth == 0, i < count else { continue }

            // Only blanks and an optional `;` may follow on that line.
            var rest = i + 1
            while rest < count, isBlank(units[rest]) { rest += 1 }
            if rest < count, units[rest] == semicolon { rest += 1 }
            while rest < count, isBlank(units[rest]) { rest += 1 }
            guard rest == count || units[rest] == newline else { continue }

            // An old-style definition (`main(argc) {`) has a body next: keep it.
            var next = rest
            while next < count, isBlank(units[next]) || units[next] == newline { next += 1 }
            guard next == count || units[next] != brace else { continue }
            guard previousLineEndsStatement(before: lineStart) else { continue }

            // Lines of a multi-line call now start with spaces, so the loop skips them.
            for k in lineStart..<rest where units[k] != newline {
                units[k] = space
            }
        }
        return String(decoding: units, as: UTF16.self)
    }
}

/// Walks the top level of a C syntax tree (including `#if` blocks) and collects definitions.
nonisolated private struct CWalker {
    let text: NSString
    var symbols: [CodeSymbol] = []

    /// Nodes whose children are top-level items too.
    private static let containers: Set<String> = [
        "preproc_if", "preproc_ifdef", "preproc_else", "preproc_elif", "preproc_elifdef",
        "linkage_specification", "declaration_list", "ERROR",
    ]
    private static let specifiers: Set<String> = ["struct_specifier", "union_specifier", "enum_specifier"]

    init(text: NSString) {
        self.text = text
    }

    mutating func visitChildren(of parent: Node) {
        var commentStart: Node?  // first comment of the block right above the next item
        var lastComment: Node?
        var lastCodeEndRow = -1

        for index in 0..<parent.namedChildCount {
            guard let node = parent.namedChild(at: index), let type = node.nodeType else { continue }
            let startRow = Int(node.pointRange.lowerBound.row)

            if type == "comment" {
                if startRow == lastCodeEndRow { continue }  // trailing comment on a line of code
                if let last = lastComment, startRow <= Int(last.pointRange.upperBound.row) + 1 {
                    lastComment = node  // the block continues
                } else {
                    commentStart = node
                    lastComment = node
                }
                continue
            }

            var leadingComment: Node?
            if let last = lastComment, startRow <= Int(last.pointRange.upperBound.row) + 1 {
                leadingComment = commentStart  // no blank line between comment and definition
            }
            commentStart = nil
            lastComment = nil
            lastCodeEndRow = endRow(of: node)

            if Self.containers.contains(type) {
                visitChildren(of: node)
            } else if let found = describe(node, type: type) {
                add(name: found.name, kind: found.kind, node: node, leadingComment: leadingComment)
            }
        }
    }

    /// The last row a node covers. `#define` nodes end at column 0 of the next line (they include
    /// the newline), which would make a comment on that next line look like a trailing comment.
    private func endRow(of node: Node) -> Int {
        let range = node.pointRange
        let row = Int(range.upperBound.row)
        return range.upperBound.column == 0 && range.upperBound.row > range.lowerBound.row ? row - 1 : row
    }

    // MARK: - What a node defines

    private func describe(_ node: Node, type: String) -> (name: String, kind: CodeSymbol.Kind)? {
        switch type {
        case "function_definition":
            guard let functionName = name(ofDeclarator: node.child(byFieldName: "declarator")) else { return nil }
            return (functionName, .function)
        case "preproc_def", "preproc_function_def":
            guard let name = node.child(byFieldName: "name") else { return nil }
            return (string(of: name), .macro)
        case "type_definition":
            // `typedef struct { … } Foo;` is one symbol, named after the typedef.
            guard let names = joinedNames(of: declarators(of: node)) else { return nil }
            return (names, .type)
        case _ where Self.specifiers.contains(type):
            return describeSpecifier(node)
        case "declaration":
            let variables = declarators(of: node)
            // `struct point { … } origin;` defines a named type: show the type.
            if let typeNode = node.child(byFieldName: "type"),
               typeNode.child(byFieldName: "name") != nil,
               let specifier = describeSpecifier(typeNode) {
                return specifier
            }
            if variables.contains(where: isFunctionPrototype) { return nil }
            guard let names = joinedNames(of: variables) else { return nil }
            return (names, .global)
        default:
            return nil
        }
    }

    /// A struct, union or enum with a body. Forward declarations (`struct foo;`) don't count.
    private func describeSpecifier(_ node: Node) -> (name: String, kind: CodeSymbol.Kind)? {
        guard let type = node.nodeType, Self.specifiers.contains(type),
              node.child(byFieldName: "body") != nil
        else { return nil }
        let keyword = String(type.prefix { $0 != "_" })  // struct, union, enum
        guard let name = node.child(byFieldName: "name") else { return ("\(keyword) (anonymous)", .type) }
        return ("\(keyword) \(string(of: name))", .type)
    }

    /// `int *foo(void);` is a prototype; `int (*handler)(void);` is a function-pointer variable.
    private func isFunctionPrototype(_ declarator: Node) -> Bool {
        var current: Node? = declarator
        var depth = 0
        while let node = current, depth < 32 {
            switch node.nodeType {
            case "init_declarator":
                return false
            case "function_declarator":
                return node.child(byFieldName: "declarator")?.nodeType != "parenthesized_declarator"
            default:
                current = inner(of: node)
                depth += 1
            }
        }
        return false
    }

    // MARK: - Names

    private func declarators(of node: Node) -> [Node] {
        (0..<node.childCount).compactMap { index in
            node.fieldNameForChild(at: index) == "declarator" ? node.child(at: index) : nil
        }
    }

    private func joinedNames(of declarators: [Node]) -> String? {
        let names = declarators.compactMap(name(ofDeclarator:))
        return names.isEmpty ? nil : names.joined(separator: ", ")
    }

    /// Follows pointer, array, function and parenthesized declarators down to the identifier.
    private func name(ofDeclarator declarator: Node?) -> String? {
        var current = declarator
        var depth = 0
        while let node = current, depth < 32 {
            switch node.nodeType {
            case "identifier", "type_identifier", "field_identifier", "primitive_type":
                return string(of: node)
            default:
                current = inner(of: node)
                depth += 1
            }
        }
        return nil
    }

    private func inner(of declarator: Node) -> Node? {
        // Parenthesized and attributed declarators have no `declarator` field; it's the first child.
        declarator.child(byFieldName: "declarator") ?? declarator.namedChild(at: 0)
    }

    private func string(of node: Node) -> String {
        text.substring(with: node.range)
    }

    // MARK: - Ranges

    private mutating func add(name: String, kind: CodeSymbol.Kind, node: Node, leadingComment: Node?) {
        let definition = trimmingTrailingWhitespace(node.range)
        let start = leadingComment?.range.location ?? definition.location
        symbols.append(CodeSymbol(
            id: symbols.count,
            name: name,
            kind: kind,
            range: NSRange(location: start, length: NSMaxRange(definition) - start),
            line: Int(node.pointRange.lowerBound.row) + 1,
            preview: preview(of: definition)
        ))
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
