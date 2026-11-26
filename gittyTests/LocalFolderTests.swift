import Foundation
import Testing
@testable import gitty

struct LocalFolderTests {
    @Test func projectsSavedBeforeLocalFoldersStillRead() throws {
        let saved = #"{"link":{"owner":"o","repo":"r","treePath":[]},"ref":"main","folder":"","addedAt":0}"#
        let project = try JSONDecoder().decode(ProjectInfo.self, from: Data(saved.utf8))
        #expect(project.link == RepoLink(owner: "o", repo: "r"))
        #expect(project.id == "o/r")
        #expect(project.rawURL(for: "a.c")?.absoluteString == "https://raw.githubusercontent.com/o/r/main/a.c")
    }

    @Test func aLocalFolderKeepsItsSourceAndAddresses() throws {
        let folder = LocalFolder(id: UUID(), name: "Game", bookmark: Data([1, 2, 3]))
        let project = ProjectInfo(source: .local(folder), ref: nil, folder: "", addedAt: .now)
        let again = try JSONDecoder().decode(ProjectInfo.self, from: JSONEncoder().encode(project))
        #expect(again.localFolder == folder)
        #expect(again.link == nil)
        #expect(again.title == "Game")
        // The same address whatever is checked out (no ref in it).
        let prefix = LocalFolderAccess.prefix(of: folder.id)
        #expect(project.rawURL(for: "")?.absoluteString == prefix)
        #expect(project.rawURL(for: "Scripts/Player.cs")?.absoluteString == prefix + "Scripts/Player.cs")
    }

    @Test func aRepositorysFilesLeaveOutWhatGitIgnores() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try GitRepository.create(at: root, remote: URL(string: "https://example.com/r.git")!)
        func write(_ path: String, _ text: String = "x") throws {
            let file = root.appending(path: path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: file)
        }
        try write(".gitignore", "build/\n*.log\n")
        try write("main.c")
        try write("src/a.c")
        try write("build/out.o")
        try write("debug.log")
        let paths = LocalFiles.list(at: root, repository: repository).map(\.path)
        #expect(paths == [".gitignore", "main.c", "src/a.c"])
    }

    @Test func aPlainFolderListsEverythingButGit() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appending(path: "notes"), withIntermediateDirectories: true)
        try Data("a".utf8).write(to: root.appending(path: "notes/todo.md"))
        try Data("b".utf8).write(to: root.appending(path: "README.md"))
        let tree = LocalFiles.tree(of: LocalFiles.list(at: root, repository: nil))
        #expect(tree.entries.filter { $0.kind == .file }.map(\.path) == ["README.md", "notes/todo.md"])
        #expect(tree.entries.contains { $0.kind == .folder && $0.path == "notes" })
    }
}
