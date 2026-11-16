import Foundation
import Testing
@testable import gitty

struct ReadingPositionStoreTests {
    let defaults: UserDefaults
    let store: ReadingPositionStore
    let url = URL(string: "https://example.com/main.c")!

    init() {
        let suite = "ReadingPositionStoreTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        store = ReadingPositionStore(defaults: defaults)
    }

    @Test func nothingSavedMeansNoPosition() {
        #expect(store.position(for: url) == nil)
    }

    @Test func savedPositionSurvivesANewStore() {
        let position = ReadingPosition(characterIndex: 4_242, lineOffset: 3.5)
        store.save(position, for: url)
        #expect(ReadingPositionStore(defaults: defaults).position(for: url) == position)
    }

    @Test func positionsAreKeptPerFile() {
        let other = URL(string: "https://example.com/other.c")!
        store.save(ReadingPosition(characterIndex: 10, lineOffset: 0), for: url)
        store.save(ReadingPosition(characterIndex: 20, lineOffset: 0), for: other)
        #expect(store.position(for: url)?.characterIndex == 10)
        #expect(store.position(for: other)?.characterIndex == 20)
    }

    @Test func laterSaveReplacesEarlier() {
        store.save(ReadingPosition(characterIndex: 10, lineOffset: 0), for: url)
        store.save(.top, for: url)
        #expect(store.position(for: url) == .top)
    }
}
