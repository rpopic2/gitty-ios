import Foundation
import Testing
@testable import gitty

struct CloneScopeTests {
    @Test func keepsTheProjectsFolderAndWhatItsFilterShows() {
        let includes = CloneScope(folder: "src", filter: "*.c !test_*").includes
        #expect(includes("src/main.c"))
        #expect(includes("src/lib/util.c"))
        #expect(!includes("src/logo.png"))  // not in the filter
        #expect(!includes("src/test_main.c"))  // left out
        #expect(!includes("docs/readme.c"))  // outside the project's folder
        #expect(!includes("srcfile.c"))
    }

    @Test func noFilterKeepsTheWholeFolder() {
        let includes = CloneScope(folder: "", filter: "").includes
        #expect(includes("a/b/logo.png"))
    }
}
