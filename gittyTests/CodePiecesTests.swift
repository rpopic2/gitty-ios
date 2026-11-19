import Foundation
import Testing
@testable import gitty

struct CodePiecesTests {
    @Test func shortTextIsOnePiece() {
        #expect(CodePieces.ranges(in: "a\nb\nc", linesPerPiece: 5) == [NSRange(location: 0, length: 5)])
        #expect(CodePieces.ranges(in: "", linesPerPiece: 5) == [NSRange(location: 0, length: 0)])
    }

    @Test func piecesLeaveOutTheNewlineBetweenThem() {
        let text = "1\n2\n3\n4\n5" as NSString
        let pieces = CodePieces.ranges(in: text, linesPerPiece: 2).map { text.substring(with: $0) }
        #expect(pieces == ["1\n2", "3\n4", "5"])
    }

    @Test func aTrailingNewlineDoesNotMakeAnEmptyPiece() {
        let text = "1\n2\n" as NSString
        #expect(CodePieces.ranges(in: text, linesPerPiece: 2).map { text.substring(with: $0) } == ["1\n2\n"])
    }

    @Test func trailingWhitespaceIsTrimmed() {
        #expect(CodePieces.trimmingTrailingWhitespace("class A {\n    \n\n") == "class A {")
        #expect(CodePieces.trimmingTrailingWhitespace("  ") == "")
    }
}

struct CodeTextTests {
    @Test func piecesKeepTheirColorsAndLines() {
        let code = "int a = 1; // x\nint b;\nint c;"
        let texts = CodePieces.texts(code, fileExtension: "c", highlighted: true)
        #expect(texts.count == 1)
        #expect(texts[0].string == code)
        #expect(texts[0].runs.contains { $0.category == .comment })
        #expect(texts[0].runs.allSatisfy { $0.category != nil && NSMaxRange($0.range) <= (code as NSString).length })
    }

    @Test func plainHasNoRuns() {
        #expect(CodePieces.texts("int a;", fileExtension: "c", highlighted: false)[0].runs.isEmpty)
    }
}
