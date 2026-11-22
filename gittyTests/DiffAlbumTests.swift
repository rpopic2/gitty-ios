import Foundation
import Testing
@testable import gitty

struct DiffAlbumTests {
    /// Two hunks: one changes line 3 (`b` → `B`), one adds a line after line 10.
    private let patch = """
        diff --git a/x.c b/x.c
        --- a/x.c
        +++ b/x.c
        @@ -2,3 +2,3 @@ int main(void)
         a
        -b
        +B
         c
        @@ -10,2 +10,3 @@
         j
        +k
         l
        """

    @Test func hunksAreSplitAndTitled() {
        let hunks = DiffAlbumContents.hunks(of: UnifiedDiff(patch))
        #expect(hunks.count == 2)
        #expect(DiffAlbumContents.title(of: hunks[0]) == "int main(void)")  // the code it's in
        #expect(DiffAlbumContents.title(of: hunks[1]) == CodeSymbol.linesLabel(10, 12))  // no context: its lines
    }

    @Test func aHunksLinesFindTheirPlaceInTheWholeFile() {
        let hunks = DiffAlbumContents.hunks(of: UnifiedDiff(patch))
        let first = DiffPart(change: .modified, path: "x.c", lines: hunks[0].lines)
        // The whole file's diff: its header, then lines 1, 2, -b, +B, 4…
        #expect(first.wholeDiffLine(of: 1) == 3)  // -b: after the header and lines 1 and 2
        #expect(first.wholeDiffLine(of: 2) == 4)  // +B: after -b
        #expect(first.firstChange == 1)
        // The second hunk comes after one removed line and one added one.
        let second = DiffPart(change: .modified, path: "x.c", lines: hunks[1].lines, addedBefore: 1, removedBefore: 1)
        #expect(second.wholeDiffLine(of: 1) == 12)  // +k, new line 11: 10 lines before it, -b, and the header
    }
}
