import Foundation
import Testing
@testable import gitty

@MainActor
struct CollapsedCodeStoreTests {
    private let scope = "https://raw.githubusercontent.com/o/r/main/"
    private let open = URL(string: "https://raw.githubusercontent.com/o/r/main/a.c")!
    private let other = URL(string: "https://raw.githubusercontent.com/o/r/main/b.c")!

    private func symbol(_ name: String, kind: CodeSymbol.Kind = .function, in file: URL? = nil,
                        at location: Int = 0) -> CodeSymbol {
        CodeSymbol(id: 0, name: name, kind: kind, range: NSRange(location: location, length: 1), line: 1,
                   preview: "", fileURL: file)
    }

    private func store() throws -> (CollapsedCodeStore, UserDefaults) {
        let defaults = try #require(UserDefaults(suiteName: "CollapsedCodeStoreTests-\(UUID().uuidString)"))
        return (CollapsedCodeStore(defaults: defaults), defaults)
    }

    @Test func aSymbolStaysCollapsedWhereverItMovesAndIsSaved() throws {
        let (store, defaults) = try store()
        store.toggle(symbol("main"), openFile: open, scope: scope)
        #expect(store.isCollapsed(symbol("main", at: 400), openFile: open, scope: scope))  // moved in its file
        #expect(!store.isCollapsed(symbol("main", in: other), openFile: open, scope: scope))  // another file's
        #expect(CollapsedCodeStore(defaults: defaults).isCollapsed(symbol("main"), openFile: open, scope: scope))
    }

    @Test func aCollapsedFileHidesItsSymbolsButNotItsTitle() throws {
        let (store, _) = try store()
        let file = symbol("b.c", kind: .file, in: other)
        store.toggle(file, openFile: open, scope: scope)
        #expect(store.isFileCollapsed(other, scope: scope))
        #expect(store.isHidden(symbol("b1", in: other), openFile: open, scope: scope))
        #expect(!store.isHidden(file, openFile: open, scope: scope))
        #expect(!store.isHidden(symbol("main"), openFile: open, scope: scope))
        store.reveal(symbol("b1", in: other), openFile: open, scope: scope)
        #expect(!store.isFileCollapsed(other, scope: scope))
    }

    @Test func collapseAllThenTapOneOpen() throws {
        let (store, defaults) = try store()
        store.toggle(symbol("b.c", kind: .file, in: other), openFile: open, scope: scope)
        store.setAllCollapsed(true, scope: scope)
        #expect(store.isCollapsed(symbol("main"), openFile: open, scope: scope))
        #expect(!store.isFileCollapsed(other, scope: scope))  // the outline shows every title
        #expect(!store.isCollapsed(symbol("main"), openFile: open, scope: "https://elsewhere/"))  // its scope only
        store.toggle(symbol("main"), openFile: open, scope: scope)
        #expect(!store.isCollapsed(symbol("main"), openFile: open, scope: scope))
        #expect(store.isCollapsed(symbol("helper"), openFile: open, scope: scope))
        #expect(CollapsedCodeStore(defaults: defaults).isCollapsed(symbol("helper"), openFile: open, scope: scope))
        store.setAllCollapsed(false, scope: scope)
        #expect(!store.isCollapsed(symbol("helper"), openFile: open, scope: scope))
        #expect(!store.isCollapsed(symbol("main"), openFile: open, scope: scope))  // tapped ones start over
    }

    @Test func aFilesMenuCollapsesItsSymbols() throws {
        let (store, _) = try store()
        let symbols = [symbol("b1", in: other), symbol("b2", in: other)]
        store.setCollapsed(true, symbols, openFile: open, scope: scope)
        #expect(symbols.allSatisfy { store.isCollapsed($0, openFile: open, scope: scope) })
        #expect(!store.isCollapsed(symbol("main"), openFile: open, scope: scope))
        store.setCollapsed(false, symbols, openFile: open, scope: scope)
        #expect(store.flipped.isEmpty)
    }

    @Test func pinchingInOnTheOutlineFoldsEveryFile() throws {
        let (store, defaults) = try store()
        store.setAllCollapsed(true, scope: scope)
        store.setAllFilesFolded(true, scope: scope)
        #expect(store.areAllFilesFolded(scope: scope))
        #expect(store.isHidden(symbol("b1", in: other), openFile: open, scope: scope))
        #expect(!store.isHidden(symbol("b1", in: other), openFile: open, scope: "https://elsewhere/"))
        // Unfold one: the others stay folded.
        store.toggle(symbol("b.c", kind: .file, in: other), openFile: open, scope: scope)
        #expect(!store.isFileCollapsed(other, scope: scope))
        #expect(store.isFileCollapsed(open, scope: scope))
        #expect(CollapsedCodeStore(defaults: defaults).isFileCollapsed(open, scope: scope))
        // Pinching out: back to the outline, every file unfolded, symbols still collapsed.
        store.setAllFilesFolded(false, scope: scope)
        #expect(!store.isFileCollapsed(open, scope: scope) && !store.isFileCollapsed(other, scope: scope))
        #expect(store.isCollapsed(symbol("main"), openFile: open, scope: scope))
        // Expand All unfolds the files too.
        store.setAllFilesFolded(true, scope: scope)
        store.setAllCollapsed(false, scope: scope)
        #expect(!store.areAllFilesFolded(scope: scope) && !store.isFileCollapsed(open, scope: scope))
    }

    @Test func foldersFoldAndAreSaved() throws {
        let (store, defaults) = try store()
        store.toggleFolder("src", scope: scope)
        #expect(store.isFolderFolded("src", scope: scope))
        #expect(!store.isFolderFolded("src/lib", scope: scope))
        #expect(CollapsedCodeStore(defaults: defaults).isFolderFolded("src", scope: scope))
        store.toggleFolder("src", scope: scope)
        #expect(!store.isFolderFolded("src", scope: scope))
    }

    @Test func pinchingInOnTheFoldersFoldsThemAll() throws {
        let (store, defaults) = try store()
        store.setAllFoldersFolded(true, scope: scope)
        #expect(store.isFolderFolded("src", scope: scope) && store.isFolderFolded("", scope: scope))
        store.toggleFolder("src", scope: scope)  // one unfolded: the others stay folded
        #expect(!store.isFolderFolded("src", scope: scope) && store.isFolderFolded("lib", scope: scope))
        #expect(CollapsedCodeStore(defaults: defaults).isFolderFolded("lib", scope: scope))
        store.setAllFoldersFolded(false, scope: scope)
        #expect(!store.isFolderFolded("src", scope: scope) && !store.isFolderFolded("lib", scope: scope))
        // Expand All starts the folders over too.
        store.setAllFoldersFolded(true, scope: scope)
        store.setAllCollapsed(false, scope: scope)
        #expect(!store.areAllFoldersFolded(scope: scope))
    }

    @Test func theOldSavedFormIsKept() throws {
        let defaults = try #require(UserDefaults(suiteName: "CollapsedCodeStoreTests-\(UUID().uuidString)"))
        defaults.set([CollapsedCodeStore.key(for: symbol("main"), openFile: open),
                      CollapsedCodeStore.key(forFile: other)], forKey: "collapsedCode")
        let store = CollapsedCodeStore(defaults: defaults)
        #expect(store.isCollapsed(symbol("main"), openFile: open, scope: scope))
        #expect(store.isFileCollapsed(other, scope: scope))
    }

    @Test func aTemporaryStoreIgnoresTheSavedFoldsAndKeepsItsOwnToItself() throws {
        let (saved, _) = try store()
        saved.setAllFilesFolded(true, scope: scope)
        let temporary = CollapsedCodeStore.temporary()
        #expect(!temporary.isHidden(symbol("main", in: other), openFile: open, scope: scope))
        temporary.setAllFilesFolded(true, scope: scope)
        #expect(temporary.isHidden(symbol("main", in: other), openFile: open, scope: scope))
        #expect(!CollapsedCodeStore.temporary().areAllFilesFolded(scope: scope))
    }
}
