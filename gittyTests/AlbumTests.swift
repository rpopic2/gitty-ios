import Foundation
import Testing
@testable import gitty

@MainActor
struct AlbumTests {
    private let open = URL(string: "https://raw.githubusercontent.com/o/r/main/a.c")!
    private let other = URL(string: "https://raw.githubusercontent.com/o/r/main/b.c")!

    private func entry(_ id: Int, _ name: String, in file: URL? = nil) -> CodeSymbol {
        CodeSymbol(id: id, name: name, kind: .file, range: NSRange(location: 0, length: 100), line: 1,
                   preview: "", fileURL: file)
    }

    private func function(_ id: Int, _ name: String, at location: Int, in file: URL? = nil) -> CodeSymbol {
        CodeSymbol(id: id, name: name, kind: .function, range: NSRange(location: location, length: 10),
                   line: location / 10 + 1, preview: "", fileURL: file)
    }

    /// a.c (open): main, helper, helper (an overload); b.c: b1, b2.
    private var list: [CodeSymbol] {
        [entry(0, "a.c"), function(1, "main", at: 0), function(2, "helper", at: 20), function(3, "helper", at: 60),
         entry(4, "b.c", in: other), function(5, "b1", at: 0, in: other), function(6, "b2", at: 30, in: other)]
    }

    private func album(_ items: [AlbumItem]) -> Album {
        Album(name: "Test", projectID: "p", items: items)
    }

    private func symbolItem(_ name: String, in file: URL, at location: Int) -> AlbumItem {
        .symbol(AlbumSymbol(file: file, name: name, kind: CodeSymbol.Kind.function.rawValue, location: location))
    }

    @Test func showsItsSymbolsInTheOrderTheyWereAddedWithTheirIDs() {
        // Added b1 first, then main.
        let album = album([symbolItem("b1", in: other, at: 0), symbolItem("main", in: open, at: 0)])
        let shown = AlbumContents.symbols(of: album, in: list, openFile: open, texts: [:])
        #expect(shown.map(\.id) == [5, 1])
    }

    @Test func somethingAddedTwiceShowsOnceWhereItCameFirst() {
        // b2, then the whole of b.c: its entry and b1 follow, b2 stays first.
        let album = album([symbolItem("b2", in: other, at: 30), .file(other)])
        let shown = AlbumContents.symbols(of: album, in: list, openFile: open, texts: [:])
        #expect(shown.map(\.id) == [6, 4, 5])
    }

    @Test func aWholeFileBringsItsEntryAndEverySymbol() {
        let shown = AlbumContents.symbols(of: album([.file(other)]), in: list, openFile: open, texts: [:])
        #expect(shown.map(\.id) == [4, 5, 6])
    }

    @Test func anOverloadIsTheOneNearestWhereItWas() {
        let shown = AlbumContents.symbols(of: album([symbolItem("helper", in: open, at: 55)]), in: list,
                                          openFile: open, texts: [:])
        #expect(shown.map(\.id) == [3])
    }

    @Test func aSymbolThatsGoneIsLeftOut() {
        let shown = AlbumContents.symbols(of: album([symbolItem("removed", in: open, at: 0)]), in: list,
                                          openFile: open, texts: [:])
        #expect(shown.isEmpty)
    }

    @Test func linesAreEntriesOfTheirOwn() {
        let text = "int a;\n\n  int b = 1;\nint c;\nint d;\n" as NSString
        let lines = AlbumItem.lines(AlbumLines(file: other, start: 2, end: 4))
        let shown = AlbumContents.symbols(of: album([lines, symbolItem("b2", in: other, at: 30)]), in: list,
                                          openFile: open, texts: [other: text])
        #expect(shown.count == 2)
        let excerpt = shown[0]
        #expect(excerpt.kind == .lines)
        #expect(excerpt.id >= list.count)  // not a place in the full list
        #expect(excerpt.line == 2 && excerpt.endLine == 4)
        #expect(excerpt.name == "int b = 1;")  // its first line that isn't blank
        #expect(text.substring(with: excerpt.range) == "\n  int b = 1;\nint c;")
        #expect(excerpt.fileURL == other)
        #expect(shown[1].id == 6)
    }

    @Test func linesWaitForTheirFilesText() {
        let lines = AlbumItem.lines(AlbumLines(file: other, start: 1, end: 1))
        #expect(AlbumContents.symbols(of: album([lines]), in: list, openFile: open, texts: [:]).isEmpty)
    }

    @Test func linesPastTheEndOfTheFileAreLeftOut() {
        let lines = AlbumItem.lines(AlbumLines(file: other, start: 9, end: 12))
        let shown = AlbumContents.symbols(of: album([lines]), in: list, openFile: open, texts: [other: "one\ntwo\n"])
        #expect(shown.isEmpty)
    }

    @Test func anEntryBecomesTheRightItem() {
        #expect(AlbumItem(entry(4, "b.c", in: other), openFile: open) == .file(other))
        #expect(AlbumItem(entry(0, "a.c"), openFile: open) == .file(open))
        let item = AlbumItem(function(2, "helper", at: 20), openFile: open)
        #expect(item.isSame(as: symbolItem("helper", in: open, at: 999)))  // moved, still the same
        #expect(!item.isSame(as: symbolItem("main", in: open, at: 20)))
    }

    @Test func theStoreKeepsItemsOnceAndSavesThem() throws {
        let defaults = try #require(UserDefaults(suiteName: "AlbumTests-\(UUID().uuidString)"))
        let store = AlbumStore(defaults: defaults)
        let album = store.create(named: "  Parsing  ", projectID: "p", items: [.file(other)])
        #expect(album.name == "Parsing")
        store.add([.file(other), symbolItem("main", in: open, at: 0)], to: album.id)
        store.add([symbolItem("main", in: open, at: 40)], to: album.id)  // the same symbol, moved
        #expect(store.album(id: album.id)?.items.count == 2)
        store.remove([.file(other)], from: album.id)
        #expect(store.album(id: album.id)?.items.count == 1)

        let reloaded = AlbumStore(defaults: defaults)
        #expect(reloaded.albums.map(\.name) == ["Parsing"])
        reloaded.deleteAlbums(inProject: "p")
        #expect(AlbumStore(defaults: defaults).albums.isEmpty)
    }
}
