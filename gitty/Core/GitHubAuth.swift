import Foundation
import Security

/// gitty's GitHub App, registered once on github.com (see the README). Neither value is a secret:
/// the device flow needs only the app's public Client ID.
nonisolated enum GitHubAppConfig {
    /// The app's Client ID (`Iv23…`), from its settings page on GitHub.
    static let clientID = ""
    /// The app's URL name: the part after `github.com/apps/`.
    static let slug = ""

    /// Where you pick which repositories the app (and so gitty) can read.
    static var installURL: URL {
        URL(string: "https://github.com/apps/\(slug)/installations/new") ?? URL(string: "https://github.com/settings/installations")!
    }

    /// Where you can revoke gitty's access. Revoking from the app needs the client secret.
    static let authorizationsURL = URL(string: "https://github.com/settings/apps/authorizations")!
}

/// A signed-in GitHub account's token, as saved in the Keychain.
nonisolated struct GitHubCredential: Codable, Equatable, Sendable {
    var accessToken: String
    /// `nil` when the app's tokens don't expire.
    var expiresAt: Date?
    var refreshToken: String?
    var refreshExpiresAt: Date?
    /// The account name, for showing who's signed in.
    var login: String?
}

/// The code to enter on github.com/login/device, and how to wait for it.
nonisolated struct DeviceCode: Equatable, Sendable {
    let deviceCode: String
    let userCode: String
    let verificationURI: URL
    let expiresIn: Int
    /// Seconds to wait between checks.
    let interval: Int
}

nonisolated enum GitHubAuthError: LocalizedError, Equatable {
    case notConfigured
    case codeExpired
    case denied
    case badStatus(Int)
    case github(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: "gitty's GitHub app isn't set up yet: add its Client ID to GitHubAppConfig."
        case .codeExpired: "The code expired before it was entered."
        case .denied: "Sign-in was cancelled on GitHub."
        case .badStatus(let code): "GitHub responded with status \(code)."
        case .github(let message): message
        }
    }
}

// MARK: - Keychain

/// Where the credential is kept. A protocol so tests can use memory instead of the Keychain.
nonisolated protocol CredentialStore: Sendable {
    func load() -> GitHubCredential?
    func save(_ credential: GitHubCredential)
    func delete()
}

/// One generic-password Keychain item, readable after the first unlock and never synced or
/// restored to another device.
nonisolated struct KeychainCredentialStore: CredentialStore {
    var service = "gitty.github"

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: "github"]
    }

    func load() -> GitHubCredential? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data
        else { return nil }
        return try? JSONDecoder().decode(GitHubCredential.self, from: data)
    }

    func save(_ credential: GitHubCredential) {
        guard let data = try? JSONEncoder().encode(credential) else { return }
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            SecItemAdd(query.merging(attributes) { $1 } as CFDictionary, nil)
        }
    }

    func delete() {
        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - Requests

/// Adds the GitHub token to requests that need it. `ProjectStore` and `DocumentStore` use it.
nonisolated protocol RequestAuthorizer: Sendable {
    /// The `Authorization` header for `url`, or `nil` (signed out, or not a GitHub host).
    func authorization(for url: URL) async -> String?
    /// GitHub answered 401 to a request with the token: it was revoked or has expired.
    func tokenRejected() async
}

// MARK: - Sign-in

/// Sign in with GitHub through the device flow, the token in the Keychain, and the
/// `Authorization` header for GitHub's hosts.
///
/// The token is only ever sent to `api.github.com` and `raw.githubusercontent.com`. It's a
/// GitHub App token: it can read (not change) only the repositories you install the app on. The
/// same token works as the password for `git clone` over HTTPS (`x-access-token` as the user name).
actor GitHubAuth: RequestAuthorizer {
    static let shared = GitHubAuth()

    /// The hosts the token is sent to. Nothing else ever sees it.
    nonisolated static let tokenHosts: Set<String> = ["api.github.com", "raw.githubusercontent.com"]

    private let store: any CredentialStore
    private let session: URLSession
    private let clientID: String
    private let sleep: @Sendable (Duration) async throws -> Void
    private let now: @Sendable () -> Date

    private var credential: GitHubCredential?
    private var didLoad = false
    private var refreshTask: Task<GitHubCredential?, Never>?

    init(store: any CredentialStore = KeychainCredentialStore(),
         configuration: URLSessionConfiguration = .ephemeral,
         clientID: String = GitHubAppConfig.clientID,
         sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
         now: @escaping @Sendable () -> Date = { .now }) {
        self.store = store
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        self.session = URLSession(configuration: configuration)
        self.clientID = clientID
        self.sleep = sleep
        self.now = now
    }

    var isSignedIn: Bool { loadCredential() != nil }

    /// The signed-in account's name, if known.
    var login: String? { loadCredential()?.login }

    /// A current access token, refreshed first if it has expired. `nil` when signed out, or when
    /// it expired and couldn't be refreshed (then you're signed out). libgit2's credential
    /// callback can use this too.
    func token() async -> String? {
        guard let credential = loadCredential() else { return nil }
        guard let expiresAt = credential.expiresAt, expiresAt <= now().addingTimeInterval(60) else {
            return credential.accessToken
        }
        // Several downloads can find it expired at once: refresh only once.
        if refreshTask == nil {
            refreshTask = Task { await self.refresh(credential) }
        }
        let refreshed = await refreshTask?.value
        refreshTask = nil
        return refreshed?.accessToken
    }

    func authorization(for url: URL) async -> String? {
        guard url.scheme == "https", let host = url.host()?.lowercased(), Self.tokenHosts.contains(host)
        else { return nil }
        return await token().map { "Bearer " + $0 }
    }

    func tokenRejected() {
        signOut()
    }

    /// Forgets the token. Saved files stay. (Revoking it is done on GitHub: `authorizationsURL`.)
    func signOut() {
        store.delete()
        credential = nil
        didLoad = true
    }

    /// Step 1: asks GitHub for a code to show.
    func startSignIn() async throws -> DeviceCode {
        guard !clientID.isEmpty else { throw GitHubAuthError.notConfigured }
        nonisolated struct Response: Decodable {
            let device_code: String
            let user_code: String
            let verification_uri: String
            let expires_in: Int
            let interval: Int?
        }
        let data = try await post("https://github.com/login/device/code", ["client_id": clientID])
        let response = try JSONDecoder().decode(Response.self, from: data)
        guard let uri = URL(string: response.verification_uri) else { throw GitHubAuthError.badStatus(0) }
        return DeviceCode(deviceCode: response.device_code, userCode: response.user_code,
                          verificationURI: uri, expiresIn: response.expires_in,
                          interval: response.interval ?? 5)
    }

    /// Step 2: waits until the code is entered on GitHub, then saves the token. Stops when the
    /// calling task is cancelled.
    func finishSignIn(_ code: DeviceCode) async throws -> GitHubCredential {
        let deadline = now().addingTimeInterval(TimeInterval(code.expiresIn))
        var interval = max(code.interval, 1)
        while true {
            try await sleep(.seconds(interval))
            guard now() < deadline else { throw GitHubAuthError.codeExpired }
            let response = try await requestToken([
                "client_id": clientID,
                "device_code": code.deviceCode,
                "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
            ])
            switch response.error {
            case nil:
                guard var credential = response.credential(now: now()) else {
                    throw GitHubAuthError.badStatus(0)
                }
                credential.login = await fetchLogin(token: credential.accessToken)
                save(credential)
                return credential
            case "authorization_pending":
                continue
            case "slow_down":
                interval = response.interval ?? interval + 5
            case "expired_token":
                throw GitHubAuthError.codeExpired
            case "access_denied":
                throw GitHubAuthError.denied
            case let error?:
                throw GitHubAuthError.github(response.error_description ?? error)
            }
        }
    }

    // MARK: Private

    private func loadCredential() -> GitHubCredential? {
        if !didLoad {
            credential = store.load()
            didLoad = true
        }
        return credential
    }

    private func save(_ credential: GitHubCredential) {
        store.save(credential)
        self.credential = credential
        didLoad = true
    }

    /// Trades the refresh token for a new token. Signs out if that isn't possible.
    private func refresh(_ old: GitHubCredential) async -> GitHubCredential? {
        guard let refreshToken = old.refreshToken,
              (old.refreshExpiresAt ?? .distantFuture) > now()
        else {
            signOut()
            return nil
        }
        let response = try? await requestToken([
            "client_id": clientID,
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
        ])
        guard let response, response.error == nil, var credential = response.credential(now: now()) else {
            signOut()
            return nil
        }
        credential.login = old.login
        save(credential)
        return credential
    }

    nonisolated private struct TokenResponse: Decodable {
        let access_token: String?
        let expires_in: Int?
        let refresh_token: String?
        let refresh_token_expires_in: Int?
        let error: String?
        let error_description: String?
        let interval: Int?

        func credential(now: Date) -> GitHubCredential? {
            guard let access_token else { return nil }
            return GitHubCredential(
                accessToken: access_token,
                expiresAt: expires_in.map { now.addingTimeInterval(TimeInterval($0)) },
                refreshToken: refresh_token,
                refreshExpiresAt: refresh_token_expires_in.map { now.addingTimeInterval(TimeInterval($0)) },
                login: nil
            )
        }
    }

    private func requestToken(_ form: [String: String]) async throws -> TokenResponse {
        let data = try await post("https://github.com/login/oauth/access_token", form)
        return try JSONDecoder().decode(TokenResponse.self, from: data)
    }

    private func fetchLogin(token: String) async -> String? {
        nonisolated struct User: Decodable { let login: String }
        var request = URLRequest(url: URL(string: "https://api.github.com/user")!)
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard let result = try? await session.data(for: request),
              (result.1 as? HTTPURLResponse)?.statusCode == 200
        else { return nil }
        return try? JSONDecoder().decode(User.self, from: result.0).login
    }

    /// A form POST that asks for JSON back. GitHub answers 200 even for "not yet" (in `error`).
    private func post(_ address: String, _ form: [String: String]) async throws -> Data {
        var request = URLRequest(url: URL(string: address)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(Self.formEncoded(form).utf8)
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw GitHubAuthError.badStatus(status) }
        return data
    }

    nonisolated static func formEncoded(_ form: [String: String]) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        return form.sorted { $0.key < $1.key }
            .map { key, value in
                (key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key) + "="
                    + (value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)
            }
            .joined(separator: "&")
    }
}
