import Foundation
import Testing
@testable import gitty

struct FileNameSearchTests {
    private let other = URL(string: "https://raw.githubusercontent.com/o/r/main/b.c")!
    private let third = URL(string: "https://raw.githubusercontent.com/o/r/main/c.c")!

    private func symbol(_ id: Int, _ name: String, in file: URL? = nil) -> CodeSymbol {
        CodeSymbol(id: id, name: name, kind: .function, range: NSRange(location: 0, length: 1),
                   line: id + 1, preview: "", fileURL: file)
    }

    private func entry(_ id: Int, _ name: String, in file: URL?) -> CodeSymbol {
        CodeSymbol(id: id, name: name, kind: .file, range: NSRange(location: 0, length: 9),
                   line: 1, preview: "", fileURL: file)
    }

    private var list: [CodeSymbol] {
        [entry(0, "a.c", in: nil), symbol(1, "main"),
         entry(2, "b.c", in: other), symbol(3, "abc", in: other),
         entry(4, "c.c", in: third), symbol(5, "b", in: third)]
    }

    @Test func matchingFilesComeWithAllTheirSymbols() {
        // "b" names b.c (and the function `b` in c.c doesn't count): b.c, with all its symbols.
        #expect(FileNameSearch.symbols(inFilesNamed: "b", in: list).map(\.id) == [2, 3])
        // ".c" matches all three, equally: list order.
        #expect(FileNameSearch.symbols(inFilesNamed: ".c", in: list).map(\.id) == [0, 1, 2, 3, 4, 5])
        #expect(FileNameSearch.symbols(inFilesNamed: "c.c", in: list).first?.id == 4)  // exact name first
        #expect(FileNameSearch.symbols(inFilesNamed: "zzz", in: list).isEmpty)
    }

    @Test func aMaximumRankLeavesOutLooseMatches() {
        // "ac" is only a subsequence of a.c: fine for fuzzy, not for "the name contains it".
        #expect(FileNameSearch.symbols(inFilesNamed: "ac", in: list).first?.id == 0)
        #expect(FileNameSearch.symbols(inFilesNamed: "ac", in: list, maxRank: 5).isEmpty)
    }
}

struct FolderGroupTests {
    private let scope = "https://raw.githubusercontent.com/o/r/main/"

    private func url(_ path: String) -> URL { URL(string: "https://raw.githubusercontent.com/o/r/main/" + path)! }

    private func entry(_ id: Int, _ path: String, open: Bool = false) -> CodeSymbol {
        CodeSymbol(id: id, name: (path as NSString).lastPathComponent, kind: .file,
                   range: NSRange(location: 0, length: 1), line: 1, preview: "", fileURL: open ? nil : url(path))
    }

    private func symbol(_ id: Int, in path: String, open: Bool = false) -> CodeSymbol {
        CodeSymbol(id: id, name: "s\(id)", kind: .function, range: NSRange(location: 0, length: 1), line: 1,
                   preview: "", fileURL: open ? nil : url(path))
    }

    @Test func filesGroupByFolderEvenWhenSubfoldersComeBetween() {
        // Path order: README.md, src/a.c, src/lib/b.c, src/z.c (the open file).
        let list = [entry(0, "README.md"), entry(1, "src/a.c"), symbol(2, in: "src/a.c"),
                    entry(3, "src/lib/b.c"), symbol(4, in: "src/lib/b.c"),
                    entry(5, "src/z.c", open: true), symbol(6, in: "src/z.c", open: true)]
        let groups = FolderGroup.groups(of: list, openFile: url("src/z.c"), scope: scope)
        #expect(groups.map(\.path) == ["", "src", "src/lib"])
        #expect(groups.map { $0.symbols.map(\.id) } == [[0], [1, 2, 5, 6], [3, 4]])
        #expect(groups.map(\.fileCount) == [1, 2, 1])
    }

    @Test func aFoldersPathIsDecoded() {
        #expect(FolderGroup.path(of: url("My%20Folder/a.c"), scope: scope) == "My Folder")
        #expect(FolderGroup.path(of: URL(string: "https://elsewhere/a.c")!, scope: scope) == "")
    }

    @Test func aPlaceInAFileIsReadLikeACompilersMessage() {
        #expect(FileLineQuery("SomeFile.c:980") == FileLineQuery(file: "SomeFile.c", line: 980))
        #expect(FileLineQuery("src/net/SomeFile.c:980:12")?.file == "src/net/SomeFile.c")  // no column
        #expect(FileLineQuery("src/net/SomeFile.c:980:12")?.line == 980)
        #expect(FileLineQuery(":980") == FileLineQuery(file: "", line: 980))  // the open file
        #expect(FileLineQuery("SomeFile.c") == nil)
        #expect(FileLineQuery("SomeFile.c:") == nil)
        #expect(FileLineQuery("SomeFile.c:0") == nil)
        #expect(FileLineQuery("a b:3") == nil)  // words, not a file
    }

    @Test func aPlaceInAFileFindsTheFilesItNames() {
        let open = URL(string: "https://raw.githubusercontent.com/o/r/main/src/a.c")!
        let nested = URL(string: "https://raw.githubusercontent.com/o/r/main/lib/b.c")!
        let list = [entry(0, "a.c", in: nil), symbol(1, "main"),
                    entry(2, "b.c", in: other), symbol(3, "abc", in: other),
                    entry(4, "b.c", in: nested), symbol(5, "f", in: nested)]
        #expect(FileLineQuery("b.c:9")?.files(in: list, openFile: open).map(\.id) == [2, 3, 4, 5])  // both
        #expect(FileLineQuery("lib/b.c:9")?.files(in: list, openFile: open).map(\.id) == [4, 5])  // the path's
        #expect(FileLineQuery("src/a.c:9")?.files(in: list, openFile: open).map(\.id) == [0, 1])  // the open one
        #expect(FileLineQuery(":9")?.files(in: list, openFile: open).map(\.id) == [0, 1])
    }
}
