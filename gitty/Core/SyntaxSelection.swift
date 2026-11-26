import Foundation
import SwiftTreeSitter

/// Growing a selection by the code's syntax: double tap a selection on a page and it becomes
/// the smallest tree-sitter node around it that's bigger than it (`Y` → `X.Y` → `X.Y.Z` →
/// `(X.Y.Z, b)` → `foo(X.Y.Z, b)` → the statement…). Nodes that cover exactly the same text are
/// skipped, so each step shows.
nonisolated enum SyntaxSelection {
    /// The range a selection grows to, in the same (UTF-16) terms; `nil` without a grammar for
    /// the file, or when the selection is already all of it.
    static func range(enclosing selection: NSRange, in text: String, fileExtension: String) -> NSRange? {
        guard let language = SymbolLanguage.forExtension(fileExtension) else { return nil }
        let original = text as NSString
        guard selection.length > 0, NSMaxRange(selection) <= original.length else { return nil }
        let parser = Parser()
        // Ranges are UTF-16, into the same text (see `SymbolIndexer.index`).
        guard (try? parser.setLanguage(language.language)) != nil,
              let root = parser.parse(language.prepare(original))?.rootNode
        else { return nil }
        // Down to the deepest node around the selection, keeping the way down.
        var path: [Node] = [root]
        descend: while let node = path.last {
            for index in 0..<node.childCount {
                guard let child = node.child(at: index) else { continue }
                if contains(child.range, selection) {
                    path.append(child)
                    continue descend
                }
                if child.range.location > selection.location { break }
            }
            break
        }
        // Then up, to the first that's bigger than the selection.
        for node in path.reversed() {
            let range = node.range
            if contains(range, selection), range.length > selection.length, NSMaxRange(range) <= original.length {
                return range
            }
        }
        return nil
    }

    private static func contains(_ outer: NSRange, _ inner: NSRange) -> Bool {
        outer.location <= inner.location && NSMaxRange(outer) >= NSMaxRange(inner)
    }
}
