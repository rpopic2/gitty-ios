import Foundation
import Testing
@testable import gitty

struct ProjectStartFileTests {
    let prefix = "https://raw.githubusercontent.com/o/r/main/"

    func url(_ path: String) -> URL {
        URL(string: prefix + path)!
    }

    @Test func theLastOpenedFileInTheProjectComesFirst() {
        let history = [
            url("a.swift").absoluteString: Date(timeIntervalSince1970: 1),
            url("b.swift").absoluteString: Date(timeIntervalSince1970: 2),
            "https://raw.githubusercontent.com/o/other/main/c.swift": Date(timeIntervalSince1970: 3),
        ]
        let chosen = ProjectStartFile.choose(prefix: prefix, filter: .none, history: history,
                                             saved: [url("z.swift")], treeFiles: [])
        #expect(chosen == url("b.swift"))
    }

    @Test func otherwiseTheFirstDownloadedFileInPathOrder() {
        let saved = [url("src/b.swift"), url("src/a.swift"),
                     URL(string: "https://raw.githubusercontent.com/o/other/main/0.swift")!]
        let chosen = ProjectStartFile.choose(prefix: prefix, filter: .none, history: [:],
                                             saved: saved, treeFiles: [])
        #expect(chosen == url("src/a.swift"))
    }

    @Test func otherwiseTheReadmeAtTheTop() {
        let files = [url("Sources/main.swift"), url("Package.swift"), url("README.md"), url("docs/README.md")]
        let chosen = ProjectStartFile.choose(prefix: prefix, filter: .none, history: [:],
                                             saved: [], treeFiles: files)
        #expect(chosen == url("README.md"))
    }

    @Test func otherwiseTheFirstListedFile() {
        let files = [url("Sources/main.swift"), url("Package.swift")]
        let chosen = ProjectStartFile.choose(prefix: prefix, filter: .none, history: [:],
                                             saved: [], treeFiles: files)
        #expect(chosen == url("Sources/main.swift"))
    }

    @Test func onlyFilesTheFilterLetsThrough() {
        let history = [url("notes.md").absoluteString: Date()]
        let chosen = ProjectStartFile.choose(prefix: prefix, filter: FileFilter("*.swift"), history: history,
                                             saved: [url("a.md"), url("b.swift")], treeFiles: [])
        #expect(chosen == url("b.swift"))
    }

    @Test func nothingWhenTheProjectHasNoFiles() {
        #expect(ProjectStartFile.choose(prefix: prefix, filter: .none, history: [:], saved: [], treeFiles: []) == nil)
    }
}
