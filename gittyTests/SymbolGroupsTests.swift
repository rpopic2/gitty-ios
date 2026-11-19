import Foundation
import Testing
@testable import gitty

struct SymbolGroupsTests {
    private let open = URL(string: "https://raw.githubusercontent.com/o/r/main/a.c")!
    private let other = URL(string: "https://raw.githubusercontent.com/o/r/main/b.c")!
    private let third = URL(string: "https://raw.githubusercontent.com/o/r/main/c.c")!

    private func symbol(_ id: Int, _ name: String, in file: URL? = nil) -> CodeSymbol {
        CodeSymbol(id: id, name: name, kind: .function, range: NSRange(location: 0, length: 1),
                   line: id + 1, preview: "", fileURL: file)
    }

    @Test func filesComeInTheOrderOfTheirFirstSymbol() {
        // The full list: the open file's symbols, then the others' in path order.
        let list = [symbol(0, "main"), symbol(1, "helper"), symbol(2, "b1", in: other), symbol(3, "c1", in: third)]
        let groups = SymbolFileGroup.groups(of: list, openFile: open)
        #expect(groups.map(\.file) == [open, other, third])
        #expect(groups.map(\.anchorID) == [0, 2, 3])  // no entries here: each file's first symbol
        #expect(groups.map { $0.symbols.map(\.name) } == [["main", "helper"], ["b1"], ["c1"]])
    }

    @Test func searchResultsPutTheFileWithTheBestMatchFirst() {
        // Results, best first: the best match is in c.c, then one in the open file, then c.c again.
        let results = [symbol(3, "c1", in: third), symbol(0, "main"), symbol(4, "c2", in: third)]
        let groups = SymbolFileGroup.groups(of: results, openFile: open)
        #expect(groups.map(\.file) == [third, open])
        #expect(groups.first?.symbols.map(\.name) == ["c1", "c2"])  // best first within the file
    }

    @Test func filesEntriesAreHeadersNotRows() {
        let file = CodeSymbol(id: 0, name: "a.c", kind: .file, range: NSRange(location: 0, length: 9),
                              line: 1, preview: "")
        let otherFile = CodeSymbol(id: 2, name: "b.c", kind: .file, range: NSRange(location: 0, length: 9),
                                   line: 1, preview: "", fileURL: other)
        let groups = SymbolFileGroup.groups(of: [file, symbol(1, "main"), otherFile], openFile: open)
        #expect(groups.map(\.file) == [open, other])
        #expect(groups.map { $0.symbols.map(\.name) } == [["main"], []])  // b.c matched by name only
        // Each file is one item at the Files level, scrolled to by its entry's id.
        #expect(groups.map(\.anchorID) == [0, 2])
    }

    @Test func noSymbolsNoGroups() {
        #expect(SymbolFileGroup.groups(of: [], openFile: open).isEmpty)
    }

    @Test func foldedFilesAreRemembered() {
        let defaults = UserDefaults(suiteName: "SymbolGroupsTests")!
        defaults.removePersistentDomain(forName: "SymbolGroupsTests")
        let store = SymbolFoldStore(defaults: defaults)
        store.setFolded(true, open)
        store.setFolded(true, other)
        store.setFolded(false, open)
        #expect(store.foldedFiles() == [other])
        #expect(SymbolFoldStore(defaults: defaults).foldedFiles() == [other])
    }

    @Test func theFilesLevelSearchesFileNames() {
        func entry(_ id: Int, _ name: String, in file: URL?) -> CodeSymbol {
            CodeSymbol(id: id, name: name, kind: .file, range: NSRange(location: 0, length: 9),
                       line: 1, preview: "", fileURL: file)
        }
        let list = [entry(0, "a.c", in: nil), symbol(1, "main"),
                    entry(2, "b.c", in: other), symbol(3, "abc", in: other),
                    entry(4, "c.c", in: third), symbol(5, "b", in: third)]
        // "b" names b.c (and the function `b` in c.c doesn't count): b.c, with all its symbols.
        #expect(SymbolFileGroup.symbols(inFilesNamed: "b", in: list).map(\.id) == [2, 3])
        // ".c" matches all three, equally: list order.
        #expect(SymbolFileGroup.symbols(inFilesNamed: ".c", in: list).map(\.id) == [0, 1, 2, 3, 4, 5])
        #expect(SymbolFileGroup.symbols(inFilesNamed: "c.c", in: list).first?.id == 4)  // exact name first
        #expect(SymbolFileGroup.symbols(inFilesNamed: "zzz", in: list).isEmpty)
    }
}
