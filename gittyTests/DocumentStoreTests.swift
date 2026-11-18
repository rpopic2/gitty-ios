import Foundation
import Testing
@testable import gitty

/// Serialized because the stub's handler is shared.
@Suite(.serialized)
struct DocumentStoreTests {
    let url = URL(string: "https://example.com/main.c")!
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "DocumentStoreTests-\(UUID().uuidString)", directoryHint: .isDirectory)

    private func makeStore() -> DocumentStore {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return DocumentStore(directory: directory, configuration: configuration, authorizer: nil)
    }

    private func ok(_ body: String, etag: String = "\"v1\"") -> StubURLProtocol.Handler {
        { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                           headerFields: ["ETag": etag, "Content-Type": "text/plain; charset=utf-8"])!
            return (response, Data(body.utf8))
        }
    }

    @Test func nothingSavedMeansNoCopy() async {
        #expect(await makeStore().cached(url) == nil)
    }

    @Test func firstFetchSavesForever() async throws {
        StubURLProtocol.reset(handler: ok("hello"))
        guard case .updated(let document) = try await makeStore().fetch(url) else {
            Issue.record("expected .updated"); return
        }
        #expect(document.data == Data("hello".utf8))

        // A new store (like a relaunch) reads it from disk without any request.
        StubURLProtocol.reset(handler: { _ in throw URLError(.notConnectedToInternet) })
        let cached = try #require(await makeStore().cached(url))
        #expect(cached.data == Data("hello".utf8))
        #expect(cached.metadata.etag == "\"v1\"")
        #expect(cached.metadata.contentType == "text/plain; charset=utf-8")
        #expect(StubURLProtocol.requests.isEmpty)
    }

    @Test func refreshSendsConditionalRequestAnd304KeepsCopy() async throws {
        StubURLProtocol.reset(handler: ok("hello"))
        let store = makeStore()
        _ = try await store.fetch(url)

        StubURLProtocol.reset { request in
            #expect(request.value(forHTTPHeaderField: "If-None-Match") == "\"v1\"")
            return (HTTPURLResponse(url: request.url!, statusCode: 304, httpVersion: "HTTP/1.1", headerFields: [:])!, Data())
        }
        guard case .notModified(let document) = try await store.fetch(url) else {
            Issue.record("expected .notModified"); return
        }
        #expect(document.data == Data("hello".utf8))
        #expect(StubURLProtocol.requests.count == 1)
    }

    @Test func changedFileReplacesCopy() async throws {
        StubURLProtocol.reset(handler: ok("hello"))
        let store = makeStore()
        _ = try await store.fetch(url)

        StubURLProtocol.reset(handler: ok("world", etag: "\"v2\""))
        _ = try await store.fetch(url)
        let cached = try #require(await store.cached(url))
        #expect(cached.data == Data("world".utf8))
        #expect(cached.metadata.etag == "\"v2\"")
    }

    @Test func listsSavedDocumentsNewestFirst() async throws {
        let other = URL(string: "https://example.com/other.c")!
        StubURLProtocol.reset(handler: ok("hello"))
        let store = makeStore()
        _ = try await store.fetch(url)
        try await Task.sleep(for: .milliseconds(10))  // distinct fetchedAt
        _ = try await store.fetch(other)
        #expect(await store.savedDocuments().map(\.url) == [other, url])
    }

    @Test func deleteRemovesTheSavedCopy() async throws {
        StubURLProtocol.reset(handler: ok("hello"))
        let store = makeStore()
        _ = try await store.fetch(url)
        #expect(await store.savedDocuments().map(\.url) == [url])  // read once, then kept
        await store.delete(url)
        #expect(await store.cached(url) == nil)
        #expect(await store.savedDocuments().isEmpty)
        _ = try await store.fetch(url)
        #expect(await store.savedDocuments().map(\.url) == [url])
        await store.deleteAll()
        #expect(await store.savedDocuments().isEmpty)
    }

    @Test func failedRefreshKeepsCopy() async throws {
        StubURLProtocol.reset(handler: ok("hello"))
        let store = makeStore()
        _ = try await store.fetch(url)

        StubURLProtocol.reset(handler: { _ in throw URLError(.notConnectedToInternet) })
        await #expect(throws: URLError.self) { try await store.fetch(url) }
        #expect(await store.cached(url)?.data == Data("hello".utf8))

        StubURLProtocol.reset { request in
            (HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: "HTTP/1.1", headerFields: [:])!, Data("oops".utf8))
        }
        await #expect(throws: DocumentStoreError.badStatus(500)) { try await store.fetch(url) }
        #expect(await store.cached(url)?.data == Data("hello".utf8))
    }

    // MARK: GitHub token

    private func makeStore(authorizer: FakeAuthorizer) -> DocumentStore {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return DocumentStore(directory: directory, configuration: configuration, authorizer: authorizer)
    }

    @Test func sendsTheTokenWhereTheAuthorizerSaysSo() async throws {
        let store = makeStore(authorizer: FakeAuthorizer(header: "Bearer t"))
        StubURLProtocol.reset(handler: ok("secret"))
        _ = try await store.fetch(url)
        #expect(StubURLProtocol.requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer t")

        let none = makeStore(authorizer: FakeAuthorizer(header: nil))
        StubURLProtocol.reset(handler: ok("public"))
        _ = try await none.fetch(URL(string: "https://example.com/other.c")!)
        #expect(StubURLProtocol.requests.first?.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func aRejectedTokenIsForgottenAndTheFileFetchedWithoutIt() async throws {
        let authorizer = FakeAuthorizer(header: "Bearer revoked")
        let store = makeStore(authorizer: authorizer)
        StubURLProtocol.reset { request in
            let status = request.value(forHTTPHeaderField: "Authorization") == nil ? 200 : 401
            return (HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: [:])!,
                    Data("public".utf8))
        }
        _ = try await store.fetch(url)
        #expect(StubURLProtocol.requests.count == 2)
        #expect(await store.cached(url)?.data == Data("public".utf8))
        #expect(authorizer.rejections == 1)
    }
}

nonisolated final class FakeAuthorizer: RequestAuthorizer, @unchecked Sendable {
    private let lock = NSLock()
    private let header: String?
    private var rejected = 0

    init(header: String?) { self.header = header }

    var rejections: Int { lock.withLock { rejected } }

    func authorization(for url: URL) async -> String? { header }
    func tokenRejected() async { lock.withLock { rejected += 1 } }
}

nonisolated final class StubURLProtocol: URLProtocol {
    typealias Handler = @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)

    private static let lock = NSLock()
    nonisolated(unsafe) private static var handler: Handler?
    nonisolated(unsafe) private static var recorded: [URLRequest] = []

    static var requests: [URLRequest] { lock.withLock { recorded } }

    static func reset(handler: @escaping Handler) {
        lock.withLock {
            self.handler = handler
            recorded = []
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let handler = Self.lock.withLock {
            Self.recorded.append(request)
            return Self.handler
        }
        do {
            guard let handler else { throw URLError(.unknown) }
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
