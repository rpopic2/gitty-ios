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
