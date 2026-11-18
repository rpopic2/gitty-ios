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

    @Test func removeForgetsThePosition() {
        store.save(ReadingPosition(characterIndex: 10, lineOffset: 0), for: url)
        store.remove(for: url)
        #expect(store.position(for: url) == nil)
    }

    @Test func laterSaveReplacesEarlier() {
        store.save(ReadingPosition(characterIndex: 10, lineOffset: 0), for: url)
        store.save(.top, for: url)
        #expect(store.position(for: url) == .top)
    }

    // MARK: Symbols list

    private func symbol(_ id: Int, _ name: String, at location: Int) -> CodeSymbol {
        CodeSymbol(id: id, name: name, kind: .function, range: NSRange(location: location, length: 10),
                   line: id + 1, preview: "")
    }

    @Test func symbolsPositionIsSavedPerFileAndRemovedWithIt() {
        let position = SymbolsPosition(name: "main", characterIndex: 120)
        store.saveSymbolsPosition(position, for: url)
        #expect(ReadingPositionStore(defaults: defaults).symbolsPosition(for: url) == position)
        #expect(store.symbolsPosition(for: URL(string: "https://example.com/other.c")!) == nil)
        store.remove(for: url)
        #expect(store.symbolsPosition(for: url) == nil)
    }

    @Test func symbolsPositionDoesNotTouchTheFilePosition() {
        store.save(ReadingPosition(characterIndex: 10, lineOffset: 0), for: url)
        store.saveSymbolsPosition(SymbolsPosition(name: "main", characterIndex: 0), for: url)
        #expect(store.position(for: url)?.characterIndex == 10)
    }

    @Test func symbolsPositionFindsTheSameSymbolAfterTheFileChanged() {
        let saved = SymbolsPosition(symbol(1, "draw", at: 100))
        // Code was added above: `draw` moved down and is now the third symbol.
        let changed = [symbol(0, "init", at: 0), symbol(1, "helper", at: 90), symbol(2, "draw", at: 180)]
        #expect(saved.symbolID(in: changed) == 2)
    }

    @Test func symbolsPositionPicksTheNearestOfTheSameName() {
        let saved = SymbolsPosition(name: "draw", characterIndex: 500)
        let symbols = [symbol(0, "draw", at: 10), symbol(1, "other", at: 480), symbol(2, "draw", at: 520)]
        #expect(saved.symbolID(in: symbols) == 2)
    }

    @Test func symbolsPositionFallsBackToTheNearestSymbol() {
        let saved = SymbolsPosition(name: "removed", characterIndex: 300)
        let symbols = [symbol(0, "a", at: 0), symbol(1, "b", at: 280), symbol(2, "c", at: 600)]
        #expect(saved.symbolID(in: symbols) == 1)
        #expect(saved.symbolID(in: []) == nil)
    }
}
