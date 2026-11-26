import Foundation
import Testing
@testable import gitty

struct SyntaxSelectionTests {
    let source = "void f(void) { foo(X.Y.Z, b); }"

    private func grown(_ selected: String, _ text: String, ext: String = "c") -> String? {
        let ns = text as NSString
        let range = ns.range(of: selected)
        return SyntaxSelection.range(enclosing: range, in: text, fileExtension: ext).map { ns.substring(with: $0) }
    }

    @Test func eachStepIsTheNextNodeOut() {
        #expect(grown("Y", source) == "X.Y")
        #expect(grown("X.Y", source) == "X.Y.Z")
        #expect(grown("X.Y.Z", source) == "(X.Y.Z, b)")
        #expect(grown("(X.Y.Z, b)", source) == "foo(X.Y.Z, b)")
    }

    @Test func noGrammarGrowsNothing() {
        #expect(grown("Y", source, ext: "txt") == nil)
    }

    @Test func allOfItGrowsNothing() {
        #expect(grown(source, source) == nil)
    }
}
