import Foundation
import Testing
@testable import gitty

struct OccurrencesTests {
    private func found(_ term: String, in text: String) -> [String] {
        let ns = text as NSString
        return Occurrences.ranges(of: term, in: ns).map { "\($0.location)" }
    }

    @Test func wholeWordsWithTheirCase() {
        let text = "count = counter + Count + count; recount(count)"
        #expect(found("count", in: text) == ["0", "26", "41"])
    }

    @Test func punctuationAtTheEndsNeedsNoBoundary() {
        #expect(found("a.b", in: "x.a.b.c a.bc a.b") == ["2", "13"])
        #expect(found("->", in: "p->q->r") == ["1", "4"])
    }

    @Test func otherScriptsAreWordCharacters() {
        #expect(found("이름", in: "이름 이름표 (이름)") == ["0", "8"])
    }

    @Test func aTermIsOneLine() {
        #expect(Occurrences.term(fromSelection: "  value \n") == "value")
        #expect(Occurrences.term(fromSelection: "a\nb") == nil)
        #expect(Occurrences.term(fromSelection: "   ") == nil)
    }

    @Test func theLineOfALocation() {
        let starts = AlbumContents.lineStarts(of: "ab\ncd\n\nef")
        #expect(Occurrences.line(of: 0, lineStarts: starts) == 0)
        #expect(Occurrences.line(of: 4, lineStarts: starts) == 1)
        #expect(Occurrences.line(of: 6, lineStarts: starts) == 2)
        #expect(Occurrences.line(of: 8, lineStarts: starts) == 3)
    }

    @Test @MainActor func eachLineWithItOpensTheSymbolItsIn() {
        let url = URL(string: "https://raw.githubusercontent.com/o/r/main/a.c")!
        let text = "int total;\nvoid add(int n) {\n    total += n; total++;\n}\nint other;\n" as NSString
        let function = CodeSymbol(id: 1, name: "add", kind: .function,
                                  range: NSRange(location: 11, length: 44), line: 2, preview: "", fileURL: url)
        let entry = CodeSymbol(id: 0, name: "a.c", kind: .file, range: NSRange(location: 0, length: text.length),
                               line: 1, preview: "", fileURL: url)
        let file = OccurrenceFile(url: url, fileURL: url, entry: entry, symbols: [entry, function])
        let found = OccurrenceSearch.find("total", in: text, file: file)
        #expect(found.count == 2)  // line 1, and line 3 once (twice on it)
        #expect(found[0].line.line == 1 && found[0].page.kind == .lines)  // in no symbol: the lines around it
        #expect(found[1].line.line == 3 && found[1].page.name == "add")
        #expect(found[1].lineInPage == 1)  // the function's second line
    }
}

struct BlameLabelTests {
    private let now = Date(timeIntervalSince1970: 1_000_000_000)

    private func hunk(_ author: String, ago seconds: TimeInterval, boundary: Bool = false) -> GitBlameHunk {
        GitBlameHunk(startLine: 1, lineCount: 3, commitID: "abc", author: author,
                     date: now.addingTimeInterval(-seconds), isBoundary: boundary)
    }

    @Test func authorsFirstNameAndHowLongAgo() {
        #expect(CodeBlameView.label(for: hunk("Kim Lee", ago: 3 * 365 * 86_400 + 5), now: now) == "Kim · 3y")
        #expect(CodeBlameView.label(for: hunk("ann", ago: 2 * 86_400), now: now) == "ann · 2d")
        #expect(CodeBlameView.label(for: hunk("Bo", ago: 30), now: now) == "Bo · now")
    }

    @Test func beforeTheDownloadedHistoryIsOlder() {
        #expect(CodeBlameView.label(for: hunk("Kim", ago: 60, boundary: true), now: now) == "Kim · older")
    }

    @Test func aHunksLines() {
        #expect(hunk("Kim", ago: 0).lines == 1...3)
    }
}
