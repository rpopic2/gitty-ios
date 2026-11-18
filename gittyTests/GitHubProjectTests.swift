import Foundation
import Testing
@testable import gitty

struct GitHubProjectTests {
    private func link(_ string: String) -> RepoLink? { RepoLink(URL(string: string)!) }

    @Test func repositoryAndFolderLinksAreProjects() {
        #expect(link("https://github.com/rpopic2/allang") == RepoLink(owner: "rpopic2", repo: "allang"))
        #expect(link("https://github.com/rpopic2/allang.git") == RepoLink(owner: "rpopic2", repo: "allang"))
        #expect(link("https://www.github.com/o/r/tree/main/Sources/App")
                == RepoLink(owner: "o", repo: "r", treePath: ["main", "Sources", "App"]))
        #expect(link("https://github.com/o/r/tree/main") == RepoLink(owner: "o", repo: "r", treePath: ["main"]))
    }

    @Test func otherGitHubLinksAreNot() {
        #expect(link("https://github.com/o/r/blob/main/a.swift") == nil)  // a file
        #expect(link("https://github.com/o/r/issues/1") == nil)
        #expect(link("https://github.com/o") == nil)
        #expect(link("https://github.com/o/r/tree") == nil)
        #expect(link("https://example.com/o/r") == nil)
    }

    @Test func projectIDs() {
        #expect(RepoLink(owner: "o", repo: "r").id == "o/r")
        #expect(RepoLink(owner: "o", repo: "r", treePath: ["main", "Sources"]).id == "o/r/tree/main/Sources")
        #expect(RepoLink(owner: "o", repo: "r").webURL?.absoluteString == "https://github.com/o/r")
        #expect(RepoLink(owner: "o", repo: "r", treePath: ["main", "My Folder"]).webURL?.absoluteString
                    == "https://github.com/o/r/tree/main/My%20Folder")
    }

    @Test func rawURLs() {
        let project = ProjectInfo(link: RepoLink(owner: "o", repo: "r"), ref: "feature/x", folder: "", addedAt: .now)
        #expect(project.rawURL(for: "Sources/My File.swift")?.absoluteString
                == "https://raw.githubusercontent.com/o/r/feature/x/Sources/My%20File.swift")
        let unresolved = ProjectInfo(link: RepoLink(owner: "o", repo: "r"), ref: nil, folder: nil, addedAt: .now)
        #expect(unresolved.rawURL(for: "a.swift") == nil)
    }

    private let tree = ProjectTree(
        entries: [
            .init(path: "README.md", kind: .file, sha: "1", size: 10),
            .init(path: "Sources", kind: .folder, sha: "2", size: nil),
            .init(path: "Sources/b.swift", kind: .file, sha: "3", size: 20),
            .init(path: "Sources/a.png", kind: .file, sha: "4", size: 30),
            .init(path: "Sources/Inner", kind: .folder, sha: "5", size: nil),
            .init(path: "Sources/Inner/c.c", kind: .file, sha: "6", size: 40),
            .init(path: "Package.swift", kind: .file, sha: "7", size: 50),
            .init(path: "vendor", kind: .submodule, sha: "8", size: nil),
        ],
        truncated: false, etag: nil, fetchedAt: .now
    )

    @Test func filesGroupedByDirectoryCodeFirst() {
        let groups = tree.directories(under: "")
        #expect(groups.map(\.path) == ["", "Sources", "Sources/Inner"])
        #expect(groups.map { $0.files.map(\.name) } == [["Package.swift", "README.md"], ["b.swift", "a.png"], ["c.c"]])
    }

    @Test func directoriesAreRelativeToTheProjectFolder() {
        let groups = tree.directories(under: "Sources")
        #expect(groups.map(\.path) == ["", "Inner"])
        #expect(groups.first?.files.map(\.path) == ["Sources/b.swift", "Sources/a.png"])
    }

    @Test func subdirectoriesFollowTheirParent() {
        let paths = ["c/x.c", "a.b/x.c", "a/b/x.c", "a/x.c"]
        let tree = ProjectTree(entries: paths.enumerated().map { ProjectTree.Entry(path: $1, kind: .file, sha: "\($0)", size: 1) },
                               truncated: false, etag: nil, fetchedAt: .now)
        #expect(tree.directories(under: "").map(\.path) == ["a", "a/b", "a.b", "c"])
    }

    @Test func aFilterNarrowsTheListAndDropsEmptyDirectories() {
        let groups = tree.directories(under: "", matching: FileFilter("*.swift *.c"))
        #expect(groups.map(\.path) == ["", "Sources", "Sources/Inner"])
        #expect(groups.map { $0.files.map(\.name) } == [["Package.swift"], ["b.swift"], ["c.c"]])
        #expect(tree.directories(under: "", matching: FileFilter("*.md")).map(\.path) == [""])
    }

    @Test func filterPathsAreInsideTheProjectFolder() {
        #expect(tree.files(under: "Sources", matching: FileFilter("Inner/")).map(\.path) == ["Sources/Inner/c.c"])
        #expect(tree.files(under: "", matching: FileFilter("!Sources/")).map(\.path) == ["README.md", "Package.swift"])
    }

    @Test func filesUnderAFolderAtAnyDepth() {
        #expect(Set(tree.files(under: "Sources").map(\.path)) == ["Sources/b.swift", "Sources/a.png", "Sources/Inner/c.c"])
        #expect(tree.files(under: "").count == 5)
    }
}
