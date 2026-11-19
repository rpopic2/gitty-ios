import Foundation
import Testing
@testable import gitty

struct ReviewTextTests {
    private let selection = ReviewSelection(location: "alc/main.c", startLine: 12, endLine: 14,
                                            code: "int a;\nint b;\nint c;\n", language: "c")

    @Test func compactIsFileLinesThenTheComment() {
        #expect(ReviewText.block(for: selection, format: .compact) == "alc/main.c:12-14: ")
        var one = selection
        one.endLine = 12
        #expect(ReviewText.block(for: one, format: .compact) == "alc/main.c:12: ")
    }

    @Test func markdownQuotesTheCode() {
        #expect(ReviewText.block(for: selection, format: .markdown)
                == "### alc/main.c:12-14\n\n```c\nint a;\nint b;\nint c;\n```\n\n")
    }

    @Test func commentsAppendAtTheEnd() {
        #expect(ReviewText.appending("b.c:1: ", to: "", format: .compact) == "b.c:1: ")
        #expect(ReviewText.appending("b.c:1: ", to: "a.c:3: Typo.\n\n", format: .compact) == "a.c:3: Typo.\nb.c:1: ")
        #expect(ReviewText.appending("### b.c:1\n", to: "Intro\n", format: .markdown) == "Intro\n\n### b.c:1\n")
    }

    @Test func linesOfASelection() {
        let text = "one\ntwo\nthree\nfour" as NSString
        #expect(ReviewText.lines(of: NSRange(location: 0, length: 3), in: text) == (1, 1))
        #expect(ReviewText.lines(of: NSRange(location: 5, length: 6), in: text) == (2, 3))   // "wo\nthr"
        #expect(ReviewText.lines(of: NSRange(location: 4, length: 4), in: text) == (2, 2))   // "two\n": a whole line
        #expect(ReviewText.lines(of: NSRange(location: 14, length: 4), in: text) == (4, 4))
    }

    @Test func projectFilesAreNamedByTheirPath() {
        let project = ProjectInfo(link: RepoLink(owner: "o", repo: "r"), ref: "main", folder: "", addedAt: .now)
        let file = URL(string: "https://raw.githubusercontent.com/o/r/main/Sources/My%20File.swift")!
        #expect(ReviewText.location(for: file, projects: [project]) == "Sources/My File.swift")
        let other = URL(string: "https://example.com/a.c")!
        #expect(ReviewText.location(for: other, projects: [project]) == "https://example.com/a.c")
        #expect(ReviewText.language(for: file) == "swift")
    }
}

@MainActor
struct ReviewDraftTests {
    private func makeDraft() -> (ReviewDraft, UserDefaults) {
        let suite = "ReviewDraftTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (ReviewDraft(defaults: defaults), defaults)
    }

    private let selection = ReviewSelection(location: "a.c", startLine: 1, endLine: 1, code: "x", language: "c")

    @Test func addingOpensTheComposerAndKeepsTheDraft() {
        let (draft, defaults) = makeDraft()
        draft.add(selection, format: .compact)
        draft.text += "Rename this."
        draft.add(selection, format: .compact)
        #expect(draft.isComposing)
        #expect(draft.commentCount == 2)
        #expect(draft.text == "a.c:1: Rename this.\na.c:1: ")
        #expect(ReviewDraft(defaults: defaults).text == draft.text)  // survives a relaunch
    }

    @Test func clearingEndsTheReview() {
        let (draft, defaults) = makeDraft()
        draft.add(selection, format: .compact)
        draft.clear()
        #expect(!draft.hasDraft)
        #expect(!draft.isComposing)
        #expect(ReviewDraft(defaults: defaults).commentCount == 0)
    }
}

struct ReviewContextTests {
    private let diffSelection = ReviewDiffSelection(
        path: "src/parse.c", oldPath: nil, commit: "3f2a9c1e0b7d4a5f6e8c9d0a1b2c3d4e5f6a7b8c",
        summary: "Fix overflow in parser", oldLines: 40...42, newLines: 40...44,
        diff: " int n;\n-int a;\n+long a;\n+long b;")

    @Test func diffCommentsCarryTheCommitAndBothSides() {
        #expect(diffSelection.label == "src/parse.c@3f2a9c1 (before 40-42, after 40-44)")
        #expect(ReviewText.block(for: diffSelection, format: .compact)
                == "src/parse.c@3f2a9c1 (before 40-42, after 40-44): ")
        #expect(ReviewText.block(for: diffSelection, format: .markdown)
                == "### src/parse.c@3f2a9c1 (before 40-42, after 40-44)\n\n"
                + "Commit 3f2a9c1e0b7d4a5f6e8c9d0a1b2c3d4e5f6a7b8c: Fix overflow in parser\n\n"
                + "```diff\n int n;\n-int a;\n+long a;\n+long b;\n```\n\n")
        var added = diffSelection
        added.oldLines = nil
        added.newLines = 7...7
        #expect(added.label == "src/parse.c@3f2a9c1 (after 7)")
    }

    @Test func fileCommentsNameTheirCommit() {
        let selection = ReviewSelection(location: "a.c", startLine: 3, endLine: 3, code: "x", language: "c",
                                        commit: "abcdef0123456789")
        #expect(ReviewText.block(for: selection, format: .compact) == "a.c@abcdef0:3: ")
    }

    @Test func theRepositoryIsNamedOnceAtTheTop() {
        let repository = ReviewRepository(name: "o/r", ref: "main", commit: "3f2a9c1e0b")
        #expect(repository.heading == "Review of o/r (branch main, at 3f2a9c1)")
        let first = ReviewText.appending("a.c:1: ", to: "", format: .compact, repository: repository)
        #expect(first == "Review of o/r (branch main, at 3f2a9c1)\na.c:1: ")
        let second = ReviewText.appending("a.c:2: ", to: first + "Typo.", format: .compact, repository: repository)
        #expect(second == first + "Typo.\na.c:2: ")
        let markdown = ReviewText.appending("### a.c:1\n\n", to: "", format: .markdown, repository: repository)
        #expect(markdown == "## Review of o/r (branch main, at 3f2a9c1)\n\n### a.c:1\n\n")
    }

    @Test func aDiffSelectionGetsItsLinesBack() {
        let diff = UnifiedDiff("@@ -40,3 +40,4 @@\n int n;\n-int a;\n+long a;\n+long b;\n")
        let picked = diff.selection(1...4)
        #expect(picked.old == 40...41)
        #expect(picked.new == 40...42)
        #expect(picked.text == " int n;\n-int a;\n+long a;\n+long b;")
        #expect(diff.selection(3...3).old == nil)
    }
}
