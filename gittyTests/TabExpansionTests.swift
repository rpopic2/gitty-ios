import Testing
@testable import gitty

struct TabExpansionTests {
    @Test func tabsGoToTheNextStop() {
        #expect(TabExpansion.expand("\tx") == "        x")
        #expect(TabExpansion.expand("ab\tx") == "ab      x")
        #expect(TabExpansion.expand("abcdefgh\tx") == "abcdefgh        x")
    }

    @Test func eachLineStartsAtColumnZero() {
        #expect(TabExpansion.expand("abc\n\tx") == "abc\n        x")
    }

    @Test func textWithoutTabsIsUnchanged() {
        #expect(TabExpansion.expand("int main(void);") == "int main(void);")
    }

    @Test func chunksSplitAtLineBreaksAndLoseNothing() {
        let text = (1...7).map { "line \($0)" }.joined(separator: "\n")
        let chunks = TabExpansion.chunks(of: text, lines: 3)
        #expect(chunks == ["line 1\nline 2\nline 3", "line 4\nline 5\nline 6", "line 7"])
        #expect(chunks.joined(separator: "\n") == text)
    }

    @Test func shortTextIsOneChunk() {
        #expect(TabExpansion.chunks(of: "int a;", lines: 30) == ["int a;"])
        #expect(TabExpansion.chunks(of: "", lines: 30) == [""])
    }

    @Test func aTrailingLineBreakDoesNotMakeAnEmptyChunk() {
        #expect(TabExpansion.chunks(of: "a\nb\n", lines: 2) == ["a\nb"])
    }
}
