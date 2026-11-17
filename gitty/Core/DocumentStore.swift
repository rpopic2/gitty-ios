import CryptoKit
import Foundation

/// A downloaded file and what the server told us about it.
nonisolated struct StoredDocument: Sendable {
    let url: URL
    let data: Data
    let metadata: DocumentMetadata
}

nonisolated struct DocumentMetadata: Codable, Sendable, Equatable {
    var url: URL
    var etag: String?
    var lastModified: String?
    var contentType: String?
    var fetchedAt: Date
}

nonisolated enum FetchResult: Sendable {
    /// The server sent new bytes; they are saved and returned.
    case updated(StoredDocument)
    /// The server said the saved copy is still current (HTTP 304).
    case notModified(StoredDocument)
}

nonisolated enum DocumentStoreError: LocalizedError, Equatable {
    case notHTTP
    case badStatus(Int)

    var errorDescription: String? {
        switch self {
        case .notHTTP:
            "The server sent an unexpected response."
        case .badStatus(let code):
            "The server responded with status \(code) (\(HTTPURLResponse.localizedString(forStatusCode: code)))."
        }
    }
}

/// Keeps downloaded files forever and only goes to the network when asked.
///
/// - Files live in Application Support, which iOS never purges (unlike Caches/tmp).
/// - Nothing here refreshes on its own: no timers, no launch checks, no HTTP cache.
/// - `fetch` is a conditional GET when a copy exists, so an unchanged file costs a 304.
actor DocumentStore {
    static let shared = DocumentStore()

    static let defaultDirectory: URL = URL.applicationSupportDirectory
        .appending(path: "Documents", directoryHint: .isDirectory)

    private let directory: URL
    private let session: URLSession
    private var directoryReady = false

    init(directory: URL = DocumentStore.defaultDirectory,
         configuration: URLSessionConfiguration = .ephemeral) {
        self.directory = directory
        // Our saved copy is the only cache. Never let URLSession keep (or consult) another one.
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        self.session = URLSession(configuration: configuration)
    }

    /// The saved copy, read from disk only. Never touches the network.
    func cached(_ url: URL) -> StoredDocument? {
        let paths = paths(for: url)
        guard let metadataBytes = try? Data(contentsOf: paths.metadata),
              let metadata = try? JSONDecoder().decode(DocumentMetadata.self, from: metadataBytes),
              let data = try? Data(contentsOf: paths.data, options: .mappedIfSafe)
        else { return nil }
        return StoredDocument(url: url, data: data, metadata: metadata)
    }

    /// What's saved on the device, newest download first. Reads the small metadata files only.
    func savedDocuments() -> [DocumentMetadata] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { try? JSONDecoder().decode(DocumentMetadata.self, from: Data(contentsOf: $0)) }
            .sorted { $0.fetchedAt > $1.fetchedAt }
    }

    /// Deletes the saved copy of `url`, if there is one. Opening it again downloads it.
    func delete(_ url: URL) {
        let paths = paths(for: url)
        try? FileManager.default.removeItem(at: paths.metadata)
        try? FileManager.default.removeItem(at: paths.data)
    }

    /// Downloads `url`. If a copy exists, asks the server whether it changed first.
    /// On any failure the saved copy is left untouched.
    ///
    /// - Parameter progress: called with the download fraction, or `nil` while the size is unknown.
    func fetch(_ url: URL, progress: (@Sendable (Double?) -> Void)? = nil) async throws -> FetchResult {
        let existing = cached(url)

        var request = URLRequest(url: url)
        if let existing {
            if let etag = existing.metadata.etag {
                request.setValue(etag, forHTTPHeaderField: "If-None-Match")
            }
            if let lastModified = existing.metadata.lastModified {
                request.setValue(lastModified, forHTTPHeaderField: "If-Modified-Since")
            }
        }

        let delegate = progress.map(ProgressTaskDelegate.init(onProgress:))
        let (data, response) = try await session.data(for: request, delegate: delegate)
        guard let http = response as? HTTPURLResponse else { throw DocumentStoreError.notHTTP }

        switch http.statusCode {
        case 304:
            guard let existing else { throw DocumentStoreError.badStatus(304) }
            return .notModified(existing)
        case 200:
            let metadata = DocumentMetadata(
                url: url,
                etag: http.value(forHTTPHeaderField: "ETag"),
                lastModified: http.value(forHTTPHeaderField: "Last-Modified"),
                contentType: http.value(forHTTPHeaderField: "Content-Type"),
                fetchedAt: .now
            )
            try save(data, metadata: metadata, for: url)
            return .updated(StoredDocument(url: url, data: data, metadata: metadata))
        default:
            throw DocumentStoreError.badStatus(http.statusCode)
        }
    }

    // MARK: - Disk

    private func save(_ data: Data, metadata: DocumentMetadata, for url: URL) throws {
        try ensureDirectory()
        let paths = paths(for: url)
        try data.write(to: paths.data, options: .atomic)
        try JSONEncoder().encode(metadata).write(to: paths.metadata, options: .atomic)
    }

    private func ensureDirectory() throws {
        guard !directoryReady else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Files can be downloaded again, so keep them out of iCloud backups (Apple's guideline).
        // This does not make them purgeable.
        var directory = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
        directoryReady = true
    }

    private func paths(for url: URL) -> (data: URL, metadata: URL) {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined()
        return (directory.appending(path: name + ".data"),
                directory.appending(path: name + ".json"))
    }
}

/// Reports a task's download progress through KVO on `URLSessionTask.progress`.
nonisolated private final class ProgressTaskDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let onProgress: @Sendable (Double?) -> Void
    private let lock = NSLock()
    private var observation: NSKeyValueObservation?
    private var lastReported: Double?

    init(onProgress: @escaping @Sendable (Double?) -> Void) {
        self.onProgress = onProgress
    }

    func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
        let observation = task.progress.observe(\.fractionCompleted, options: [.initial, .new]) { [weak self] progress, _ in
            let fraction = progress.totalUnitCount > 0 ? progress.fractionCompleted : nil
            self?.report(fraction)
        }
        lock.withLock { self.observation = observation }
    }

    /// Drops updates smaller than 2% so the main thread hears about only a handful per download.
    private func report(_ fraction: Double?) {
        let shouldReport: Bool = lock.withLock {
            switch (lastReported, fraction) {
            case (nil, nil):
                return false
            case (let last?, let new?) where new < 1 && abs(new - last) < 0.02:
                return false
            default:
                lastReported = fraction
                return true
            }
        }
        if shouldReport { onProgress(fraction) }
    }
}
