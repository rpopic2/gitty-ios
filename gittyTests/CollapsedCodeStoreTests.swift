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

    @Test func aNewProjectStartsWithItsFoldersFoldedOnce() throws {
        let (store, defaults) = try store()
        store.startFolded(scope: scope)
        #expect(store.areAllFilesFolded(scope: scope))
        #expect(store.areAllFoldersFolded(scope: scope))
        // Unfolded since: shown again, it stays as it was left.
        store.setAllFoldersFolded(false, scope: scope)
        let reopened = CollapsedCodeStore(defaults: defaults)
        reopened.startFolded(scope: scope)
        #expect(!reopened.areAllFoldersFolded(scope: scope))
    }

    @Test func anAlbumFoldsOnItsOwn() throws {
        let defaults = try #require(UserDefaults(suiteName: "CollapsedCodeStoreTests-\(UUID().uuidString)"))
        let project = CollapsedCodeStore(defaults: defaults)
        let album = CollapsedCodeStore(defaults: defaults, namespace: "album.x.")
        let main = symbol("main", in: open)
        album.toggle(main, openFile: open, scope: scope)
        album.setAllFilesFolded(true, scope: scope)
        #expect(album.isCollapsed(main, openFile: open, scope: scope))
        #expect(!project.isCollapsed(main, openFile: open, scope: scope))  // the project's stay
        #expect(!project.areAllFilesFolded(scope: scope))
        // Saved under its own names.
        let reopened = CollapsedCodeStore(defaults: defaults, namespace: "album.x.")
        #expect(reopened.isCollapsed(main, openFile: open, scope: scope))
        #expect(reopened.areAllFilesFolded(scope: scope))
        #expect(!CollapsedCodeStore(defaults: defaults).isCollapsed(main, openFile: open, scope: scope))
    }

    @Test func aGroupStartsClosedAndStaysOpenOnceOpened() throws {
        let (store, defaults) = try store()
        #expect(!store.isGroupOpen("drivers", scope: scope))
        store.toggleGroup("drivers", scope: scope)
        #expect(store.isGroupOpen("drivers", scope: scope))
        #expect(CollapsedCodeStore(defaults: defaults).isGroupOpen("drivers", scope: scope))
        #expect(!store.isGroupOpen("drivers", scope: "https://elsewhere/"))  // its scope only
    }

    @Test func aFolderWithMoreThanFiftyFoldersUnderItIsAGroup() throws {
        func group(_ path: String, files: Int = 1) -> FolderGroup { FolderGroup(path: path, symbols: [], fileCount: files) }
        // drivers/ has 51 folders under it (gpu, and 50 inside it); fs/ has 2.
        let deep = (0..<50).map { group("drivers/gpu/d\($0)") }
        let tree = FolderTree([group("", files: 3), group("drivers/gpu")] + deep + [group("fs"), group("fs/ext4"), group("fs/nfs")])
        #expect(tree.root.isGroup)  // 54 folders with files under it
        #expect(tree.root.children == ["drivers", "fs"])
        #expect(tree.root.fileCount == 3 + 51 + 3)
        let drivers = try #require(tree.node("drivers"))
        #expect(drivers.isGroup)
        #expect(drivers.group == nil)  // only folders in it
        #expect(drivers.children == ["drivers/gpu"])
        #expect(tree.node("drivers/gpu")?.isGroup == false)  // 50 under it: not more than 50
        #expect(tree.node("fs")?.isGroup == false)
        #expect(tree.node("fs")?.below.map(\.path) == ["fs/ext4", "fs/nfs"])
    }

    @Test func aProjectWithFoldsFromBeforeKeepsThem() throws {
        let (store, _) = try store()
        store.setAllCollapsed(true, scope: scope)  // Collapse All, before scopes were kept
        store.startFolded(scope: scope)
        #expect(!store.areAllFoldersFolded(scope: scope))
        #expect(store.areAllCollapsed(scope: scope))
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

    @Test func hunksWithTheSameTitleFoldOnTheirOwn() throws {
        let (store, _) = try store()
        func hunk(at line: Int) -> CodeSymbol {
            CodeSymbol(id: line, name: "int main(void)", kind: .hunk, range: NSRange(location: 0, length: 0),
                       line: line, preview: "", fileURL: other)
        }
        store.toggle(hunk(at: 3), openFile: open, scope: scope)
        #expect(store.isCollapsed(hunk(at: 3), openFile: open, scope: scope))
        #expect(!store.isCollapsed(hunk(at: 40), openFile: open, scope: scope))
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

    @Test func expandAllInAFileUnfoldsItAndShowsItsCode() throws {
        let (store, _) = try store()
        store.setAllCollapsed(true, scope: scope)
        store.setAllFilesFolded(true, scope: scope)
        let symbols = [symbol("b1", in: other), symbol("b2", in: other)]
        store.expandAll(in: other, symbols, openFile: open, scope: scope)
        #expect(!store.isFileCollapsed(other, scope: scope))
        #expect(symbols.allSatisfy { !store.isCollapsed($0, openFile: open, scope: scope) })
        #expect(store.isFileCollapsed(open, scope: scope))  // the other files stay folded
        // A file without symbols just unfolds (its text shows).
        let readme = URL(string: "https://raw.githubusercontent.com/o/r/main/README.md")!
        store.expandAll(in: readme, [], openFile: open, scope: scope)
        #expect(!store.isFileCollapsed(readme, scope: scope))
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
