import Foundation
import Testing
@testable import gitty

struct GitComparisonTests {
    @Test func aHashIsSevenToFortyHexDigits() {
        #expect(GitSide.commitHash(in: " 3F2A9C1 ") == "3f2a9c1")
        #expect(GitSide.commitHash(in: String(repeating: "a", count: 40)) != nil)
        #expect(GitSide.commitHash(in: "3f2a9c") == nil)  // too short
        #expect(GitSide.commitHash(in: "feature") == nil)
        #expect(GitSide.commitHash(in: String(repeating: "a", count: 41)) == nil)
    }

    @Test func theTitleUsesThreeDotsSinceTheySplitAndTwoDirectly() {
        var comparison = GitComparison(base: .branch("main"), head: .branch("feature"))
        #expect(comparison.title == "main...feature")
        comparison.mode = .direct
        #expect(comparison.title == "main..feature")
        #expect(GitComparison(base: .commit("3f2a9c1e0b7d"), head: .checkedOut).title.hasPrefix("3f2a9c1..."))
    }

    @Test func onlyBranchesAndTagsCanBeFetched() {
        #expect(GitSide.branch("main").ref == .branch("main"))
        #expect(GitSide.tag("v1").ref == .tag("v1"))
        #expect(GitSide.commit("abc1234").ref == nil)
        #expect(GitSide.checkedOut.ref == nil)
    }
}
