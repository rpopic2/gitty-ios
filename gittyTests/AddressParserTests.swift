import Foundation
import Testing
@testable import gitty

struct AddressParserTests {
    private func url(_ input: String) -> String? {
        guard case .url(let url) = AddressParser.parse(input) else { return nil }
        return url.absoluteString
    }

    @Test func rawLinksOpenAsTyped() {
        let raw = "https://raw.githubusercontent.com/rpopic2/allang/refs/heads/main/alc/main.c"
        #expect(url(raw) == raw)
        #expect(url("  \(raw)\n") == raw)  // pasted with whitespace
    }

    @Test func githubFileLinksBecomeRaw() {
        #expect(url("https://github.com/rpopic2/allang/blob/main/alc/main.c")
                == "https://raw.githubusercontent.com/rpopic2/allang/main/alc/main.c")
        #expect(url("https://github.com/o/r/raw/v1.2/src/a.c")
                == "https://raw.githubusercontent.com/o/r/v1.2/src/a.c")
        // Line anchors and query items from the GitHub page are dropped.
        #expect(url("https://www.github.com/o/r/blob/main/a.c?plain=1#L10")
                == "https://raw.githubusercontent.com/o/r/main/a.c")
    }

    @Test func otherGitHubPagesLoadAsTyped() {
        #expect(url("https://github.com/o/r") == "https://github.com/o/r")
        #expect(url("https://github.com/o/r/tree/main/src") == "https://github.com/o/r/tree/main/src")
    }

    @Test func otherSitesLoadAsTyped() {
        #expect(url("https://example.com/index.html") == "https://example.com/index.html")
    }

    @Test func rejectsTextThatIsNotAURL() {
        for input in ["", "hello world", "example.com/a.c", "https://", "mailto:a@b.c", "ftp://example.com/a"] {
            #expect(AddressParser.parse(input) == .invalid(AddressParser.notAURL), "\(input)")
        }
    }

    @Test func rejectsPlainHTTP() {
        #expect(AddressParser.parse("http://example.com/a.c") == .invalid(AddressParser.notSecure))
    }

    @Test func readsSharedLinks() {
        // As built by gittyShare's ShareViewController.appLink(for:).
        let link = URL(string: "gitty://open?url=https%3A%2F%2Fexample.com%2Fa.c%3Fx%3D1%26y%3D2")!
        #expect(AddressParser.sharedAddress(in: link) == "https://example.com/a.c?x=1&y=2")
        #expect(AddressParser.sharedAddress(in: URL(string: "gitty://other?url=x")!) == nil)
        #expect(AddressParser.sharedAddress(in: URL(string: "https://open?url=x")!) == nil)
    }

    @Test func displayNames() {
        #expect(URL(string: "https://example.com/dir/main.c")!.displayFileName == "main.c")
        #expect(URL(string: "https://example.com/")!.displayFileName == "example.com")
        #expect(URL(string: "https://example.com/dir/main.c")!.displayLocation == "example.com/dir/main.c")
    }
}

struct RecentFilesStoreTests {
    let defaults: UserDefaults
    let store: RecentFilesStore
    let a = URL(string: "https://example.com/a.c")!
    let b = URL(string: "https://example.com/b.c")!

    init() {
        let suite = "RecentFilesStoreTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        store = RecentFilesStore(defaults: defaults)
    }

    @Test func newestFirstWithoutDuplicates() {
        store.add(a)
        store.add(b)
        store.add(a)
        #expect(store.urls() == [a, b])
    }

    @Test func keepsAtMostTheLimit() {
        for i in 0..<(RecentFilesStore.limit + 5) {
            store.add(URL(string: "https://example.com/\(i).c")!)
        }
        #expect(store.urls().count == RecentFilesStore.limit)
        #expect(store.urls().first == URL(string: "https://example.com/\(RecentFilesStore.limit + 4).c"))
    }

    @Test func removes() {
        store.add(a)
        store.add(b)
        store.remove(a)
        #expect(store.urls() == [b])
    }
}
