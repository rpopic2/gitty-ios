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

    @Test func markdownIsTheFileItsLineAndThatLine() {
        #expect(ReviewText.block(for: selection, format: .markdown) == "### alc/main.c:12\n```c\nint a;\n```\n\n")
        // A selection starting with a blank line: the first line with something on it.
        var spaced = selection
        spaced.code = "\n   \nint b;  \n"
        #expect(ReviewText.block(for: spaced, format: .markdown) == "### alc/main.c:14\n```c\nint b;\n```\n\n")
        // No language known: a plain fence.
        var plain = selection
        plain.language = nil
        #expect(ReviewText.block(for: plain, format: .markdown) == "### alc/main.c:12\n```\nint a;\n```\n\n")
    }

    @Test func aFileOrFolderIsJustItsPath() {
        #expect(ReviewText.block(forPath: "alc/main.c", format: .compact) == "alc/main.c: ")
        #expect(ReviewText.block(forPath: "alc/", format: .markdown) == "### alc/\n\n")
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
        draft.add(selection, format: .compact, projectID: "o/r")
        draft.text += "Rename this."
        draft.add(selection, format: .compact, projectID: "o/r")
        #expect(draft.isComposing)
        #expect(draft.commentCount == 2)
        #expect(draft.text == "a.c:1: Rename this.\na.c:1: ")
        #expect(ReviewDraft(defaults: defaults).text == draft.text)  // survives a relaunch
    }

    @Test func eachProjectHasItsOwn() {
        let (draft, _) = makeDraft()
        draft.add(selection, format: .compact, projectID: "o/a")
        draft.add(selection, format: .compact, projectID: "o/b")
        #expect(draft.projectID == "o/b" && draft.commentCount == 1)
        #expect(draft.review(for: "o/a").commentCount == 1)
        draft.open(projectID: "o/a")
        #expect(draft.projectID == "o/a" && draft.isComposing)
    }

    @Test func theXPutsItAwayButKeepsIt() {
        let (draft, _) = makeDraft()
        draft.add(selection, format: .compact, projectID: "o/r")
        draft.putAway()
        #expect(!draft.isComposing && !draft.isDocked)
        #expect(draft.review(for: "o/r").hasDraft)
        draft.add(selection, format: .compact, projectID: "o/r")  // a new comment brings it back
        draft.isComposing = false
        #expect(draft.isDocked)
    }

    @Test func sharingKeepsItAsTheLastShared() {
        let (draft, defaults) = makeDraft()
        draft.add(selection, format: .compact, projectID: "o/r")
        let text = draft.text
        draft.didShare()
        #expect(!draft.hasDraft && !draft.isComposing)
        #expect(ReviewDraft(defaults: defaults).review(for: "o/r").shared?.text == text)
        draft.deleteShared(projectID: "o/r")
        #expect(draft.review(for: "o/r") == ProjectReview())
    }

    @Test func theOldSingleDraftMovesToFiles() {
        let suite = "ReviewDraftTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set("old.c:1: hi", forKey: "reviewDraft")
        defaults.set(1, forKey: "reviewCommentCount")
        let draft = ReviewDraft(defaults: defaults)
        #expect(draft.review(for: "").text == "old.c:1: hi")
        #expect(defaults.string(forKey: "reviewDraft") == nil)
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
        // Markdown: the first change's line (removed: its number before the commit) and that line.
        #expect(ReviewText.block(for: diffSelection, format: .markdown)
                == "### src/parse.c:41\n```diff\n-int a;\n```\n\n")
        var addedOnly = diffSelection
        addedOnly.diff = " int n;\n+long b;"
        #expect(ReviewText.block(for: addedOnly, format: .markdown)
                == "### src/parse.c:41\n```diff\n+long b;\n```\n\n")
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

    @Test func thereIsNoRepositoryHeading() {
        let repository = ReviewRepository(name: "o/r", ref: "main", commit: "3f2a9c1e0b")
        let first = ReviewText.appending("a.c:1: ", to: "", format: .compact, repository: repository)
        #expect(first == "a.c:1: ")
        let markdown = ReviewText.appending("### a.c:1\n\n", to: "", format: .markdown, repository: repository)
        #expect(markdown == "### a.c:1\n\n")
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
