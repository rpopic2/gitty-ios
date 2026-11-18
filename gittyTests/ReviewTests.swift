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
