import Foundation
import Testing
@testable import gitty

struct IdentifierMapTests {
    /// The ranges of every `word` in `text`, in order.
    private func ranges(of word: String, in text: String) -> [NSRange] {
        let text = text as NSString
        var found: [NSRange] = []
        var start = 0
        while case let range = text.range(of: word, range: NSRange(location: start, length: text.length - start)),
              range.location != NSNotFound {
            found.append(range)
            start = NSMaxRange(range)
        }
        return found
    }

    @Test func aTypeDoesNotMarkAVariableWithItsName() {
        let source = "struct Point { int x; };\nstruct Point p;\nint Point;\n"
        let map = IdentifierMap(text: source, fileExtension: "c")
        let all = ranges(of: "Point", in: source)
        // "oin" inside the first `Point`.
        let selection = NSRange(location: all[0].location + 1, length: 3)
        let highlight = map.identifier(containing: selection)
        #expect(highlight?.name == "Point")
        #expect(highlight?.kind == "type_identifier")
        #expect(map.occurrences(of: highlight!) == [all[0], all[1]])
    }

    @Test func commentsAndStringsAreLeftOut() {
        let source = "int count = 0; // count\nchar *s = \"count\";\nvoid f(void) { count++; }\n"
        let map = IdentifierMap(text: source, fileExtension: "c")
        let all = ranges(of: "count", in: source)
        let highlight = map.identifier(containing: NSRange(location: all[0].location, length: 0))
        #expect(map.occurrences(of: highlight!) == [all[0], all[3]])
        // Selecting inside the comment isn't an identifier.
        #expect(map.identifier(containing: NSRange(location: all[1].location, length: 5)) == nil)
    }

    @Test func aSelectionAcrossTwoIdentifiersIsNone() {
        let source = "int alpha = beta;\n"
        let map = IdentifierMap(text: source, fileExtension: "c")
        let start = (source as NSString).range(of: "alpha").location
        #expect(map.identifier(containing: NSRange(location: start, length: 12)) == nil)
    }

    @Test func anotherLanguageMatchesAnyIdentifierWithTheName() {
        let source = "struct Point { int x; };\nint Point;\n"
        let map = IdentifierMap(text: source, fileExtension: "c")
        let highlight = IdentifierHighlight(name: "Point", kind: "type_identifier", language: "Swift")
        #expect(map.occurrences(of: highlight) == ranges(of: "Point", in: source))
    }

    @Test func withoutAGrammarWholeWordsExactCase() {
        let source = "foo bar foo_bar Foo foo.\n"
        let map = IdentifierMap(text: source, fileExtension: "md")
        let highlight = map.identifier(containing: NSRange(location: 1, length: 1))
        #expect(highlight == IdentifierHighlight(name: "foo", kind: nil, language: nil))
        #expect(map.occurrences(of: highlight!) == [NSRange(location: 0, length: 3), NSRange(location: 20, length: 3)])
        #expect(map.identifier(containing: NSRange(location: 0, length: 5)) == nil)  // "foo b"
    }
}
