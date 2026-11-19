import Foundation
import Testing
@testable import gitty

struct CodeTokenTests {
    /// The token around the first occurrence of `marker`'s first character, as text.
    private func token(in text: String, at marker: String) -> String? {
        let ns = text as NSString
        let index = ns.range(of: marker).location
        return CodeToken.range(at: index, in: ns).map { ns.substring(with: $0) }
    }

    @Test func aMemberIsItsOwnToken() {
        #expect(token(in: "self.view.frame", at: "view") == "view")
        #expect(token(in: "self.view.frame", at: "self") == "self")
        #expect(token(in: "a->next_node", at: "next") == "next_node")
        #expect(token(in: "std::vector<int>", at: "vector") == "vector")
    }

    @Test func operatorsAreRuns() {
        #expect(token(in: "a->b", at: "-") == "->")
        #expect(token(in: "x != y", at: "!") == "!=")
        #expect(token(in: "std::move", at: ":") == "::")
    }

    @Test func bracketsAndSeparatorsStandAlone() {
        #expect(token(in: "f(x)", at: "(") == "(")
        #expect(token(in: "{});", at: ";") == ";")
        #expect(token(in: "\"hi\"", at: "\"") == "\"")
    }

    @Test func numbersKeepTheirDecimalPoint() {
        #expect(token(in: "x = 1.25;", at: "1") == "1.25")
        #expect(token(in: "x = 1.25;", at: "25") == "1.25")
        #expect(token(in: "0x1F + 2", at: "x1") == "0x1F")
        #expect(token(in: "x = 1.25;", at: ".") == "1.25")
        #expect(token(in: "v1.x", at: "v") == "v1")  // a member, not a number
    }

    @Test func spaceKeepsTheTextViewsSelection() {
        #expect(CodeToken.range(at: 1, in: "a b") == nil)
        #expect(CodeToken.range(at: 5, in: "abc") == nil)
    }

    @Test func readsAMutableString() {
        let text = NSMutableString(string: "a.bc")
        #expect(CodeToken.range(at: 3, in: text) == NSRange(location: 2, length: 2))
    }

    @Test func otherScriptsAreWords() {
        #expect(token(in: "let café = 1", at: "caf") == "café")
        #expect(token(in: "이름.길이", at: "길") == "길이")
    }
}
