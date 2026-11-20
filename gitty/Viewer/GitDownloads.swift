import SwiftUI

/// The Git downloads going on (Clone, Pull, pull down, a branch), by project, for the whole app:
/// switching to another project doesn't stop one, and coming back shows how far it's got.
@MainActor @Observable
final class GitDownloads {
    static let shared = GitDownloads()

    struct Download {
        let id = UUID()
        let title: String
        /// Roughly how much it downloads, when known.
        let estimate: Int64?
        var progress = FetchProgress.start
    }

    /// Changes ten times a second while one goes on: read it only where its progress shows.
    private(set) var downloads: [String: Download] = [:]
    /// The projects downloading: changes only as one starts or ends (the sidebar's marks).
    private(set) var active: Set<String> = []
    /// Up each time one of a project's downloads ends (done, failed or cancelled), so its view
    /// (perhaps a new one) shows what it did.
    private(set) var finished: [String: Int] = [:]
    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]

    func download(for projectID: String) -> Download? {
        downloads[projectID]
    }

    /// Runs `work` (replacing the project's download, if one is going on). Its error, unless
    /// it was cancelled, goes to `onError`.
    func start(projectID: String, title: String, estimate: Int64?,
               work: @escaping @MainActor (_ progress: @escaping @Sendable (FetchProgress) -> Void) async throws -> Void,
               onError: @escaping @MainActor (any Error) async -> Void) {
        tasks[projectID]?.cancel()
        let shown = Download(title: title, estimate: estimate)
        downloads[projectID] = shown
        active.insert(projectID)
        let (updates, continuation) = AsyncStream.makeStream(of: FetchProgress.self, bufferingPolicy: .bufferingNewest(1))
        Task {
            // Not after it's finished (a last update can arrive late).
            for await update in updates where downloads[projectID]?.id == shown.id {
                downloads[projectID]?.progress = update
            }
        }
        tasks[projectID] = Task {
            do {
                try await work { continuation.yield($0) }
            } catch {
                if !Task.isCancelled { await onError(error) }
            }
            continuation.finish()
            if downloads[projectID]?.id == shown.id {
                downloads[projectID] = nil
                tasks[projectID] = nil
                active.remove(projectID)
            }
            finished[projectID, default: 0] += 1
        }
    }

    func cancel(projectID: String) {
        tasks[projectID]?.cancel()
    }
}
