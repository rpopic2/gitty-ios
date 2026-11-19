import Foundation
import Testing
@testable import gitty

struct UnifiedDiffTests {
    let patch = """
    diff --git a/Sources/main.c b/Sources/main.c
    index 3b18e51..a1b2c3d 100644
    --- a/Sources/main.c
    +++ b/Sources/main.c
    @@ -10,4 +10,5 @@ int main(void)
     int a = 1;
    -int b = 2;
    +int b = 3;
    +int c = 4;
     return a;
    \\ No newline at end of file

    """

    @Test func headersAreLeftOutAndLinesNumbered() {
        let diff = UnifiedDiff(patch)
        #expect(diff.lines.map(\.kind) == [.hunk, .context, .removed, .added, .added, .context, .note])
        #expect(diff.lines[1] == .init(kind: .context, text: "int a = 1;", oldNumber: 10, newNumber: 10))
        #expect(diff.lines[2] == .init(kind: .removed, text: "int b = 2;", oldNumber: 11))
        #expect(diff.lines[3] == .init(kind: .added, text: "int b = 3;", newNumber: 11))
        #expect(diff.lines[4].newNumber == 12)
        #expect(diff.lines[5] == .init(kind: .context, text: "return a;", oldNumber: 12, newNumber: 13))
        #expect(diff.added == 2)
        #expect(diff.removed == 1)
    }

    @Test func binaryFilesAreANote() {
        let diff = UnifiedDiff("diff --git a/x.png b/x.png\nindex 1..2 100644\nBinary files a/x.png and b/x.png differ\n")
        #expect(diff.lines == [.init(kind: .note, text: "Binary files a/x.png and b/x.png differ")])
    }

    @Test func emptyPatchHasNoLines() {
        #expect(UnifiedDiff("").lines.isEmpty)
    }
}
