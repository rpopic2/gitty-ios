import Foundation
import Testing
@testable import gitty

struct SymbolSearchTests {
    private func symbols(_ names: [String]) -> [CodeSymbol] {
        names.enumerated().map { index, name in
            CodeSymbol(id: index, name: name, kind: .method, range: NSRange(location: 0, length: 0),
                       line: index + 1, preview: "")
        }
    }

    private func search(_ query: String, _ names: [String]) -> [String] {
        SymbolSearch.matches(query, in: symbols(names)).map(\.name)
    }

    @Test func emptyQueryKeepsEverythingInFileOrder() {
        #expect(search("", ["b", "a"]) == ["b", "a"])
        #expect(search("   ", ["b", "a"]) == ["b", "a"])
    }

    @Test func lettersInOrderAnywhere() {
        #expect(search("crdr", ["Circle.draw", "Color.red", "Shape.area"]) == ["Circle.draw"])
        #expect(search("xyz", ["Circle.draw"]).isEmpty)
    }

    @Test func caseDoesNotMatter() {
        #expect(search("DRAW", ["Circle.draw"]) == ["Circle.draw"])
    }

    @Test func bestMatchesFirst() {
        let names = ["Shape.redraw", "drawLater", "Circle.draw", "Canvas.dRaW2", "d.r.a.w"]
        // exact member name, then member prefix (file order), then contains, then letters in order
        #expect(search("draw", names) == ["Circle.draw", "drawLater", "Canvas.dRaW2", "Shape.redraw", "d.r.a.w"])
    }

    @Test func spacesSeparateWords() {
        let names = ["read_regable", "readRegable", "Reader.regable", "regable", "read", "Parser.readRegs"]
        // Exact words first (like typing "read_regable"), then words in order.
        #expect(search("read regable", names) == ["read_regable", "readRegable", "Reader.regable"])
        #expect(search("read_regable", names).first == "read_regable")
    }

    @Test func wordsInAnyOrderRankLower() {
        let names = ["regable_read", "read_regable"]
        #expect(search("read regable", names) == ["read_regable", "regable_read"])
        #expect(search("regable read", names) == ["regable_read", "read_regable"])
    }

    @Test func typedWordsStartNameWords() {
        #expect(search("read reg", ["read_regable", "bread_regable"]) == ["read_regable", "bread_regable"])
        #expect(search("rd rg", ["read_regable"]) == ["read_regable"])  // letters in order still match
        #expect(search("zz qq", ["read_regable"]).isEmpty)
    }

    @Test func splitsNamesIntoWords() {
        #expect(SymbolSearch.words(of: "readRegable") == ["read", "regable"])
        #expect(SymbolSearch.words(of: "HTTPServer") == ["http", "server"])
        #expect(SymbolSearch.words(of: "read_regable") == ["read", "regable"])
        #expect(SymbolSearch.words(of: "Circle.operator +") == ["circle", "operator"])
    }

    @Test func memberNameIsTheLastPart() {
        #expect(SymbolSearch.memberName("list.icollection<t>.isreadonly") == "isreadonly")
        #expect(SymbolSearch.memberName("main") == "main")
        #expect(SymbolSearch.memberName("c.==") == "==")
    }
}
