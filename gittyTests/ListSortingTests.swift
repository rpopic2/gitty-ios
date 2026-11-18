import Foundation
import Testing
@testable import gitty

struct ListSortingTests {
    private let names = ["a.c", "b.c", "c.c", "d.c"]
    private let start = Date(timeIntervalSince1970: 1_000_000)

    private func arrange(_ sorting: ListSorting, opened: [String: TimeInterval]) -> [String] {
        let history = opened.mapValues { start.addingTimeInterval($0) }
        return sorting.arrange(names, key: { $0 }, name: { $0 }, history: history)
    }

    @Test func nameOrderKeepsTheListOrReversesIt() {
        #expect(arrange(ListSorting(), opened: ["c.c": 5]) == names)
        #expect(arrange(ListSorting(order: .name, isReversed: true), opened: [:]) == names.reversed())
    }

    @Test func recentlyOpenedFirstThenTheRestByName() {
        let sorting = ListSorting(order: .recentlyOpened)
        #expect(arrange(sorting, opened: ["c.c": 10, "a.c": 20]) == ["a.c", "c.c", "b.c", "d.c"])
    }

    @Test func reversedRecentlyOpenedPutsTheOldestFirstAndStillTheRestAfter() {
        let sorting = ListSorting(order: .recentlyOpened, isReversed: true)
        #expect(arrange(sorting, opened: ["c.c": 10, "a.c": 20]) == ["c.c", "a.c", "b.c", "d.c"])
    }

    @Test func neverOpenedSortLikeFinder() {
        let sorting = ListSorting(order: .recentlyOpened)
        let files = ["file10.c", "file2.c", "File1.c"]
        #expect(sorting.arrange(files, key: { $0 }, name: { $0 }, history: [:]) == ["File1.c", "file2.c", "file10.c"])
    }

    @Test func eachProjectAndTabKeepsItsOwnSorting() {
        let defaults = UserDefaults(suiteName: "ListSortingTests")!
        defaults.removePersistentDomain(forName: "ListSortingTests")
        let store = ListSortingStore(defaults: defaults)
        let recent = ListSorting(order: .recentlyOpened, isReversed: true)
        store.save(recent, for: .project, projectID: "o/r")
        #expect(store.sorting(for: .project, projectID: "o/r") == recent)
        #expect(store.sorting(for: .symbols, projectID: "o/r") == ListSorting())
        #expect(store.sorting(for: .project, projectID: "o/other") == ListSorting())
        store.save(ListSorting(), for: .project, projectID: "o/r")
        #expect(store.sorting(for: .project, projectID: "o/r") == ListSorting())
    }

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
