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
}
