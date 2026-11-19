import Foundation
import Testing
@testable import gitty

struct OpenHistoryTests {
    private let start = Date(timeIntervalSince1970: 1_000_000)

    @Test func openHistoryIsSavedAndKeepsTheLatestOpen() async {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let url = URL(string: "https://raw.githubusercontent.com/o/r/main/a.c")!
        let history = OpenHistory(directory: directory)
        await history.recordOpen(url, at: start)
        await history.recordOpen(url, at: start.addingTimeInterval(60))
        #expect(await history.snapshot() == [url.absoluteString: start.addingTimeInterval(60)])
        // A new instance (the next launch) reads it back.
        #expect(await OpenHistory(directory: directory).snapshot()[url.absoluteString] == start.addingTimeInterval(60))
        await history.remove(url)
        #expect(await history.snapshot().isEmpty)
    }
}
