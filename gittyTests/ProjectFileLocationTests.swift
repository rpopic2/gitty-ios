import Foundation
import Testing
@testable import gitty

struct ProjectFileLocationTests {
    let project = ProjectInfo(link: RepoLink(owner: "o", repo: "r"), ref: "main", folder: "", addedAt: .now)
    let folderProject = ProjectInfo(link: RepoLink(owner: "o", repo: "r", treePath: ["main", "src"]),
                                    ref: "main", folder: "src", addedAt: .now)

    @Test func thePathIsFromTheRepositoryRoot() {
        let url = URL(string: "https://raw.githubusercontent.com/o/r/main/src/My%20File.c")!
        let location = ProjectFileLocation.locate(url, in: [project])
        #expect(location?.path == "src/My File.c")
        #expect(location?.webURL?.absoluteString == "https://github.com/o/r/blob/main/src/My%20File.c")
    }

    @Test func theMostSpecificProjectWins() {
        let url = URL(string: "https://raw.githubusercontent.com/o/r/main/src/a.c")!
        #expect(ProjectFileLocation.locate(url, in: [project, folderProject])?.project == folderProject)
        #expect(ProjectFileLocation.locate(url, in: [folderProject])?.path == "src/a.c")
    }

    @Test func filesOutsideProjectsAreNowhere() {
        let url = URL(string: "https://raw.githubusercontent.com/o/r/dev/a.c")!
        #expect(ProjectFileLocation.locate(url, in: [project]) == nil)
        #expect(ProjectFileLocation.locate(URL(string: "https://example.com/a.c")!, in: [project]) == nil)
    }
}
