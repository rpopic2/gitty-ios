import Foundation
import Testing
@testable import gitty

struct SyntaxHighlighterTests {
    /// The category of the first occurrence of `piece` (every character of it).
    private func category(of piece: String, in text: String, fileExtension: String) -> SyntaxCategory?? {
        guard let runs = SyntaxHighlighter.runs(in: text, fileExtension: fileExtension) else { return nil }
        let range = (text as NSString).range(of: piece)
        let covering = runs.filter { NSIntersectionRange($0.range, range).length > 0 }
        let categories = Set(covering.map(\.category))
        return categories.count == 1 ? .some(categories.first!) : nil
    }

    @Test func runsCoverTheTextEndToEnd() throws {
        let text = "int main(void) {\n\treturn 0; // done\n}\n"
        let runs = try #require(SyntaxHighlighter.runs(in: text, fileExtension: "c"))
        var next = 0
        for run in runs {
            #expect(run.range.location == next)
            next = NSMaxRange(run.range)
        }
        #expect(next == (text as NSString).length)
    }

    @Test func cKeywordsStringsCommentsAndNumbers() {
        let text = "int main(void) { puts(\"hi\"); return 42; } // done\n"
        #expect(category(of: "return", in: text, fileExtension: "c") == .some(.keyword))
        #expect(category(of: "\"hi\"", in: text, fileExtension: "c") == .some(.string))
        #expect(category(of: "42", in: text, fileExtension: "c") == .some(.number))
        #expect(category(of: "// done", in: text, fileExtension: "c") == .some(.comment))
        #expect(category(of: "puts", in: text, fileExtension: "c") == .some(.function))
    }

    @Test func swiftAndCSharp() {
        let swift = "struct Point { let x: Int }\n"
        #expect(category(of: "struct", in: swift, fileExtension: "swift") == .some(.keyword))
        #expect(category(of: "Int", in: swift, fileExtension: "swift") == .some(.type))
        let cSharp = "class Circle { public int R; }\n"
        #expect(category(of: "class", in: cSharp, fileExtension: "cs") == .some(.keyword))
        #expect(category(of: "Circle", in: cSharp, fileExtension: "cs") == .some(.type))
    }

    @Test func noGrammarNoRuns() {
        #expect(SyntaxHighlighter.runs(in: "# Title", fileExtension: "md") == nil)
    }

    @Test func capturesMapToCategories() {
        #expect(SyntaxCategory(capture: "keyword.function") == .keyword)
        #expect(SyntaxCategory(capture: "comment.documentation") == .comment)
        #expect(SyntaxCategory(capture: "string.escape") == .string)
        #expect(SyntaxCategory(capture: "keyword.directive") == .preprocessor)
        #expect(SyntaxCategory(capture: "variable.member") == .property)
        #expect(SyntaxCategory(capture: "constant.builtin") == .number)
        #expect(SyntaxCategory(capture: "variable") == nil)
        #expect(SyntaxCategory(capture: "punctuation.bracket") == nil)
        #expect(SyntaxCategory(capture: "typeface") == nil)  // not under `type`
    }
}
