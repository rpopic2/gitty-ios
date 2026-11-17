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

    @Test func memberNameIsTheLastPart() {
        #expect(SymbolSearch.memberName("list.icollection<t>.isreadonly") == "isreadonly")
        #expect(SymbolSearch.memberName("main") == "main")
        #expect(SymbolSearch.memberName("c.==") == "==")
    }
}
