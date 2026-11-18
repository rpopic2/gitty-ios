import Foundation
import Testing
@testable import gitty

/// Serialized because the stub's handler is shared.
@Suite(.serialized)
struct GitHubAuthTests {
    private let start = Date(timeIntervalSince1970: 1_000_000)

    private func makeAuth(store: MemoryCredentialStore = MemoryCredentialStore(), clientID: String = "Iv23test",
                          now: Date? = nil, sleeps: SleepLog = SleepLog()) -> GitHubAuth {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AuthStubURLProtocol.self]
        let fixedNow = now ?? start
        return GitHubAuth(store: store, configuration: configuration, clientID: clientID,
                          sleep: { sleeps.append($0) }, now: { fixedNow })
    }

    private static func json(_ request: URLRequest, _ body: String, status: Int = 200) -> (HTTPURLResponse, Data) {
        (HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                         headerFields: ["Content-Type": "application/json"])!, Data(body.utf8))
    }

    private let deviceCode = DeviceCode(deviceCode: "dc", userCode: "ABCD-1234",
                                        verificationURI: URL(string: "https://github.com/login/device")!,
                                        expiresIn: 900, interval: 5)

    // MARK: Device flow

    @Test func startSignInReturnsTheCodeToShow() async throws {
        AuthStubURLProtocol.reset { request in
            #expect(request.url?.absoluteString == "https://github.com/login/device/code")
            #expect(request.httpMethod == "POST")
            #expect(AuthStubURLProtocol.body(of: request) == "client_id=Iv23test")
            return Self.json(request, #"{"device_code":"dc","user_code":"ABCD-1234","verification_uri":"https://github.com/login/device","expires_in":900,"interval":5}"#)
        }
        let code = try await makeAuth().startSignIn()
        #expect(code == deviceCode)
    }

    @Test func signInNeedsTheAppsClientID() async {
        await #expect(throws: GitHubAuthError.notConfigured) { try await makeAuth(clientID: "").startSignIn() }
    }

    @Test func waitsWhilePendingSlowsDownWhenToldAndSavesTheToken() async throws {
        let answers = Answers([
            #"{"error":"authorization_pending"}"#,
            #"{"error":"slow_down","interval":10}"#,
            #"{"access_token":"ghu_abc","token_type":"bearer"}"#,
        ])
        AuthStubURLProtocol.reset { request in
            if request.url?.host() == "api.github.com" {
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer ghu_abc")
                return Self.json(request, #"{"login":"octocat"}"#)
            }
            #expect(AuthStubURLProtocol.body(of: request)?.contains("grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Adevice_code") == true)
            return Self.json(request, answers.next())
        }
        let store = MemoryCredentialStore()
        let sleeps = SleepLog()
        let auth = makeAuth(store: store, sleeps: sleeps)

        let credential = try await auth.finishSignIn(deviceCode)
        #expect(credential.accessToken == "ghu_abc")
        #expect(credential.login == "octocat")
        #expect(credential.expiresAt == nil)  // the app's tokens don't expire
        #expect(sleeps.durations == [.seconds(5), .seconds(5), .seconds(10)])
        #expect(store.saved == credential)
        #expect(await auth.token() == "ghu_abc")
        #expect(await auth.login == "octocat")
    }

    @Test func expiredOrDeniedCodesStop() async {
        AuthStubURLProtocol.reset { Self.json($0, #"{"error":"expired_token"}"#) }
        await #expect(throws: GitHubAuthError.codeExpired) { try await makeAuth().finishSignIn(deviceCode) }

        AuthStubURLProtocol.reset { Self.json($0, #"{"error":"access_denied"}"#) }
        await #expect(throws: GitHubAuthError.denied) { try await makeAuth().finishSignIn(deviceCode) }
    }

    @Test func savesExpiryWhenTheAppsTokensExpire() async throws {
        AuthStubURLProtocol.reset { request in
            request.url?.host() == "api.github.com"
                ? Self.json(request, #"{"login":"octocat"}"#)
                : Self.json(request, #"{"access_token":"a","expires_in":28800,"refresh_token":"r","refresh_token_expires_in":15897600}"#)
        }
        let credential = try await makeAuth().finishSignIn(deviceCode)
        #expect(credential.expiresAt == start.addingTimeInterval(28_800))
        #expect(credential.refreshToken == "r")
        #expect(credential.refreshExpiresAt == start.addingTimeInterval(15_897_600))
    }

    // MARK: Using the token

    @Test func theTokenGoesOnlyToGitHubsAPIAndRawFiles() async {
        let store = MemoryCredentialStore(GitHubCredential(accessToken: "t"))
        let auth = makeAuth(store: store)
        #expect(await auth.authorization(for: URL(string: "https://api.github.com/repos/o/r")!) == "Bearer t")
        #expect(await auth.authorization(for: URL(string: "https://raw.githubusercontent.com/o/r/main/a.c")!) == "Bearer t")
        #expect(await auth.authorization(for: URL(string: "https://github.com/o/r")!) == nil)
        #expect(await auth.authorization(for: URL(string: "https://example.com/a.c")!) == nil)
        #expect(await auth.authorization(for: URL(string: "http://api.github.com/repos/o/r")!) == nil)
    }

    @Test func signedOutSendsNothing() async {
        let auth = makeAuth()
        #expect(await auth.isSignedIn == false)
        #expect(await auth.authorization(for: URL(string: "https://api.github.com/repos/o/r")!) == nil)
    }

    @Test func anExpiredTokenIsRefreshed() async {
        AuthStubURLProtocol.reset { request in
            #expect(AuthStubURLProtocol.body(of: request)?.contains("grant_type=refresh_token") == true)
            #expect(AuthStubURLProtocol.body(of: request)?.contains("refresh_token=r1") == true)
            return Self.json(request, #"{"access_token":"new","expires_in":28800,"refresh_token":"r2","refresh_token_expires_in":15897600}"#)
        }
        let old = GitHubCredential(accessToken: "old", expiresAt: start.addingTimeInterval(-1), refreshToken: "r1",
                                   refreshExpiresAt: start.addingTimeInterval(1_000), login: "octocat")
        let store = MemoryCredentialStore(old)
        let auth = makeAuth(store: store)
        #expect(await auth.token() == "new")
        #expect(store.saved?.refreshToken == "r2")
        #expect(store.saved?.login == "octocat")  // kept
    }

    @Test func aTokenThatCantBeRefreshedSignsYouOut() async {
        AuthStubURLProtocol.reset { Self.json($0, #"{"error":"bad_refresh_token"}"#) }
        let store = MemoryCredentialStore(GitHubCredential(accessToken: "old", expiresAt: start.addingTimeInterval(-1),
                                                           refreshToken: "r1", refreshExpiresAt: nil))
        let auth = makeAuth(store: store)
        #expect(await auth.token() == nil)
        #expect(store.saved == nil)
        #expect(await auth.isSignedIn == false)
    }

    @Test func rejectedTokensAreForgotten() async {
        let store = MemoryCredentialStore(GitHubCredential(accessToken: "t"))
        let auth = makeAuth(store: store)
        await auth.tokenRejected()
        #expect(store.saved == nil)
        #expect(await auth.token() == nil)
    }

    @Test func formEncodingEscapesReservedCharacters() {
        #expect(GitHubAuth.formEncoded(["b": "a b", "a": "x:y/z+1"]) == "a=x%3Ay%2Fz%2B1&b=a%20b")
    }
}

// MARK: - Helpers

nonisolated final class MemoryCredentialStore: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var credential: GitHubCredential?

    init(_ credential: GitHubCredential? = nil) { self.credential = credential }

    var saved: GitHubCredential? { lock.withLock { credential } }

    func load() -> GitHubCredential? { saved }
    func save(_ credential: GitHubCredential) { lock.withLock { self.credential = credential } }
    func delete() { lock.withLock { credential = nil } }
}

nonisolated final class SleepLog: @unchecked Sendable {
    private let lock = NSLock()
    private var log: [Duration] = []

    var durations: [Duration] { lock.withLock { log } }
    func append(_ duration: Duration) { lock.withLock { log.append(duration) } }
}

/// Answers to give one after another (the last one repeats).
nonisolated final class Answers: @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: [String]

    init(_ answers: [String]) { remaining = answers }

    func next() -> String {
        lock.withLock { remaining.count > 1 ? remaining.removeFirst() : remaining[0] }
    }
}

/// Like `StubURLProtocol`, with its own handler so these tests don't race the document store's.
nonisolated final class AuthStubURLProtocol: URLProtocol {
    typealias Handler = @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)

    private static let lock = NSLock()
    nonisolated(unsafe) private static var handler: Handler?

    static func reset(handler: @escaping Handler) {
        lock.withLock { self.handler = handler }
    }

    /// URLSession moves a request's body into a stream before a protocol sees it.
    static func body(of request: URLRequest) -> String? {
        if let data = request.httpBody { return String(decoding: data, as: UTF8.self) }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return String(decoding: data, as: UTF8.self)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let handler = Self.lock.withLock { Self.handler }
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
