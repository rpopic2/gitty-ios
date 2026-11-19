import Foundation
import Testing
@testable import gitty

@MainActor
struct CollapsedCodeStoreTests {
    private let open = URL(string: "https://raw.githubusercontent.com/o/r/main/a.c")!
    private let other = URL(string: "https://raw.githubusercontent.com/o/r/main/b.c")!

    private func symbol(_ name: String, kind: CodeSymbol.Kind = .function, in file: URL? = nil,
                        at location: Int = 0) -> CodeSymbol {
        CodeSymbol(id: 0, name: name, kind: kind, range: NSRange(location: location, length: 1), line: 1,
                   preview: "", fileURL: file)
    }

    @Test func aSymbolStaysCollapsedWhereverItMovesAndIsSaved() throws {
        let defaults = try #require(UserDefaults(suiteName: "CollapsedCodeStoreTests-\(UUID().uuidString)"))
        let store = CollapsedCodeStore(defaults: defaults)
        store.toggle(symbol("main"), openFile: open)
        #expect(store.isCollapsed(symbol("main", at: 400), openFile: open))  // moved in its file
        #expect(!store.isCollapsed(symbol("main", in: other), openFile: open))  // another file's
        #expect(CollapsedCodeStore(defaults: defaults).isCollapsed(symbol("main"), openFile: open))
    }

    @Test func aCollapsedFileHidesItsSymbolsButNotItsTitle() throws {
        let defaults = try #require(UserDefaults(suiteName: "CollapsedCodeStoreTests-\(UUID().uuidString)"))
        let store = CollapsedCodeStore(defaults: defaults)
        let file = symbol("b.c", kind: .file, in: other)
        store.toggle(file, openFile: open)
        #expect(store.isFileCollapsed(other))
        #expect(store.isHidden(symbol("b1", in: other), openFile: open))
        #expect(!store.isHidden(file, openFile: open))
        #expect(!store.isHidden(symbol("main"), openFile: open))
        store.reveal(symbol("b1", in: other), openFile: open)
        #expect(!store.isFileCollapsed(other))
    }
}
