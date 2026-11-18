import Foundation
import Testing
@testable import gitty

struct ProjectSymbolIndexTests {
    private let repo = ProjectInfo(link: RepoLink(owner: "o", repo: "r"), ref: "main", folder: "", addedAt: .now)
    private let folder = ProjectInfo(link: RepoLink(owner: "o", repo: "r", treePath: ["main", "alc"]),
                                     ref: "main", folder: "alc", addedAt: .now)

    @Test func aFileBelongsToTheMostSpecificProject() {
        let inFolder = URL(string: "https://raw.githubusercontent.com/o/r/main/alc/main.c")!
        let atTop = URL(string: "https://raw.githubusercontent.com/o/r/main/README.md")!
        let elsewhere = URL(string: "https://example.com/main.c")!
        #expect(ProjectSymbolIndex.project(containing: inFolder, in: [repo, folder])?.id == folder.id)
        #expect(ProjectSymbolIndex.project(containing: atTop, in: [repo, folder])?.id == repo.id)
        #expect(ProjectSymbolIndex.project(containing: elsewhere, in: [repo, folder]) == nil)
    }

    @Test func aFolderProjectDoesNotIncludeSimilarlyNamedFolders() {
        let lookalike = URL(string: "https://raw.githubusercontent.com/o/r/main/alcove/x.c")!
        #expect(ProjectSymbolIndex.project(containing: lookalike, in: [folder]) == nil)
    }

    @Test func movedSymbolsKeepEverythingButTheirPlace() {
        let symbol = CodeSymbol(id: 0, name: "draw", kind: .function, range: NSRange(location: 5, length: 9),
                                line: 3, preview: "void draw()")
        let file = URL(string: "https://raw.githubusercontent.com/o/r/main/b.c")!
        let moved = symbol.moved(to: 42, file: file)
        #expect(moved.id == 42)
        #expect(moved.fileURL == file)
        #expect(moved.name == "draw" && moved.range == symbol.range && moved.line == 3)
    }

    @Test func savedListPositionsStayInTheirFile() {
        let other = URL(string: "https://raw.githubusercontent.com/o/r/main/b.c")!
        let symbols = [
            CodeSymbol(id: 0, name: "main", kind: .function, range: NSRange(location: 0, length: 1), line: 1, preview: ""),
            CodeSymbol(id: 1, name: "main", kind: .function, range: NSRange(location: 0, length: 1), line: 1, preview: "",
                       fileURL: other),
        ]
        #expect(SymbolsPosition(name: "main", characterIndex: 0).symbolID(in: symbols) == 0)
        #expect(SymbolsPosition(name: "main", characterIndex: 0, file: other).symbolID(in: symbols) == 1)
        #expect(SymbolsPosition(name: "x", characterIndex: 0, file: URL(string: "https://example.com/gone.c")!)
                    .symbolID(in: symbols) == nil)
    }
}
