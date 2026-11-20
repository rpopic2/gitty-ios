import Foundation
import Testing
@testable import gitty

struct SymbolSearchTests {
    @Test func branchesAreSearchedLikeSymbols() {
        let branches = ["main", "parser-old/main", "feature/parser", "release/1.0", "fix/Parser-crash"]
        #expect(SymbolSearch.matchingNames("parser", in: branches)
                == ["feature/parser", "fix/Parser-crash", "parser-old/main"])  // the last part first, any case
        #expect(SymbolSearch.matchingNames("fpc", in: branches) == ["fix/Parser-crash"])  // letters in order
        #expect(SymbolSearch.matchingNames("", in: branches) == branches)
    }

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

    @Test func definitionPrefersTheFullName() {
        let all = symbols(["Circle", "Circle.Circle", "Circle.draw", "IShape.draw"])
        #expect(SymbolSearch.definition(named: "Circle", in: all)?.name == "Circle")
        #expect(SymbolSearch.definition(named: "draw", in: all)?.name == "Circle.draw")  // first in file
    }

    @Test func definitionNamesAndSelections() {
        let all = symbols(["struct point", "Circle.Pi, Tau", "read_regable", "SQUARE"])
        #expect(SymbolSearch.definition(named: "point", in: all)?.name == "struct point")
        #expect(SymbolSearch.definition(named: "Tau", in: all)?.name == "Circle.Pi, Tau")
        #expect(SymbolSearch.definition(named: " read_regable(", in: all)?.name == "read_regable")
        #expect(SymbolSearch.definition(named: "SQUARE", in: all)?.name == "SQUARE")
        #expect(SymbolSearch.definition(named: "read regable", in: all) == nil)  // not a single name
        #expect(SymbolSearch.definition(named: "42", in: all) == nil)
        #expect(SymbolSearch.definition(named: "missing", in: all) == nil)
    }

    @Test func searchTermFromSelection() {
        #expect(SymbolSearch.searchTerm(fromSelection: " read_regable(") == "read_regable")
        #expect(SymbolSearch.searchTerm(fromSelection: "Circle") == "Circle")
        #expect(SymbolSearch.searchTerm(fromSelection: "read regable") == nil)
        #expect(SymbolSearch.searchTerm(fromSelection: "42") == nil)
        #expect(SymbolSearch.searchTerm(fromSelection: "();") == nil)
    }

    @Test func searchQueryFromAnySelection() {
        #expect(SymbolSearch.query(fromSelection: " read_regable(") == "read_regable")
        #expect(SymbolSearch.query(fromSelection: "read  regable\n") == "read regable")
        #expect(SymbolSearch.query(fromSelection: "();") == "();")
        #expect(SymbolSearch.query(fromSelection: " \n ") == nil)
    }

    @Test func memberNameIsTheLastPart() {
        #expect(SymbolSearch.memberName("list.icollection<t>.isreadonly") == "isreadonly")
        #expect(SymbolSearch.memberName("main") == "main")
        #expect(SymbolSearch.memberName("c.==") == "==")
    }

    // MARK: Streaming

    /// A big list: names like `Module12.readValue34`, with a few that match "rdval" exactly.
    private func manySymbols(_ count: Int) -> [CodeSymbol] {
        symbols((0..<count).map { index in
            index % 997 == 0 ? "rdval" : "Module\(index / 100).\(index % 3 == 0 ? "read" : "write")Value\(index)"
        })
    }

    private func snapshots(_ query: String, in symbols: [CodeSymbol]) async -> [[CodeSymbol]] {
        var all: [[CodeSymbol]] = []
        for await snapshot in SymbolSearch.stream(query, in: SymbolSearch.Index(symbols)) {
            all.append(snapshot)
        }
        return all
    }

    @Test func theLastSnapshotIsTheWholeSearch() async {
        let symbols = manySymbols(10_000)
        for query in ["rdval", "read value", "write", "module1.r", "zzz"] {
            let last = await snapshots(query, in: symbols).last
            #expect(last?.map(\.id) == SymbolSearch.matches(query, in: symbols).map(\.id), "\(query)")
        }
    }

    @Test func snapshotsOnlyGrow() async {
        let all = await snapshots("rv", in: manySymbols(20_000))
        #expect(!all.isEmpty)
        for (earlier, later) in zip(all, all.dropFirst()) {
            #expect(Set(earlier.map(\.id)).isSubset(of: Set(later.map(\.id))))
        }
    }

    @Test func emptyListsAndQueries() async {
        #expect(await snapshots("draw", in: []).map(\.count) == [0])
        let few = symbols(["b", "a"])
        #expect(await snapshots("  ", in: few).map { $0.map(\.name) } == [["b", "a"]])
    }

    @Test func stoppingTheListenerStopsTheSearch() async {
        let index = SymbolSearch.Index(manySymbols(50_000))
        let listener = Task {
            var count = 0
            for await _ in SymbolSearch.stream("rv", in: index) { count += 1 }
            return count
        }
        listener.cancel()
        _ = await listener.value  // ends instead of waiting for the whole search
    }
}
