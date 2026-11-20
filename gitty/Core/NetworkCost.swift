import Foundation
import Network

/// Whether the network costs: cellular, a personal hotspot, or Low Data Mode. Big Git downloads
/// ask first then (`DownloadGuard`).
nonisolated final class NetworkCost: @unchecked Sendable {
    static let shared = NetworkCost()

    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    private var path: NWPath?

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            lock.withLock { self.path = path }
        }
        monitor.start(queue: DispatchQueue(label: "NetworkCost"))
    }

    /// Known a moment after the app starts (`false` until then).
    var isExpensive: Bool {
        lock.withLock { path.map { $0.isExpensive || $0.isConstrained } ?? false }
    }
}
