import Foundation
import Testing
@testable import gitty

/// The sidebar's order of projects: new ones first, then as they're dragged.
struct ProjectOrderTests {
    private func store() -> (ProjectStore, URL) {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        return (ProjectStore(directory: directory, authorizer: nil), directory)
    }

    @Test func newProjectsComeFirst() async {
        let (store, _) = store()
        await store.add(RepoLink(owner: "a", repo: "one"))
        await store.add(RepoLink(owner: "a", repo: "two"))
        #expect(await store.projects().map(\.title) == ["two", "one"])
    }

    @Test func keepsTheOrderItsGiven() async {
        let (store, _) = store()
        for name in ["one", "two", "three"] { await store.add(RepoLink(owner: "a", repo: name)) }
        await store.setOrder(["a/one", "a/three", "a/two"])
        #expect(await store.projects().map(\.title) == ["one", "three", "two"])
        await store.add(RepoLink(owner: "a", repo: "four"))
        #expect(await store.projects().map(\.title) == ["four", "one", "three", "two"])
    }

    @Test func readsTheOldListNewestFirst() async throws {
        let (store, directory) = store()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let old = [
            ProjectInfo(link: RepoLink(owner: "a", repo: "older"), ref: nil, folder: nil, addedAt: Date(timeIntervalSince1970: 1)),
            ProjectInfo(link: RepoLink(owner: "a", repo: "newer"), ref: nil, folder: nil, addedAt: Date(timeIntervalSince1970: 2)),
        ]
        try JSONEncoder().encode(old).write(to: directory.appending(path: "projects.json"))
        #expect(await store.projects().map(\.title) == ["newer", "older"])
        await store.setOrder(["a/older", "a/newer"])
        #expect(await store.projects().map(\.title) == ["older", "newer"])
        #expect(!FileManager.default.fileExists(atPath: directory.appending(path: "projects.json").path))
    }
}
