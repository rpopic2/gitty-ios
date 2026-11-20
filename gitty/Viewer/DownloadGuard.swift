import SwiftUI

/// Git downloads that may be big ask first on a network that costs (cellular, a hotspot, Low
/// Data Mode): over `limit`, or when the size can't be told. Git can't say beforehand how much
/// a fetch downloads, so the size is an estimate: the files', before compression.
@MainActor @Observable
final class DownloadGuard {
    static let limit: Int64 = 50_000_000

    struct Pending: Identifiable {
        let id = UUID()
        /// `nil`: couldn't be told.
        let bytes: Int64?
        let action: @MainActor (_ estimate: Int64?) -> Void
    }

    var pending: Pending?

    /// Runs `action` now, or asks first (see the type), passing it the estimate. On Wi-Fi it
    /// estimates only when `isCheap` (no request needed), and doesn't ask.
    func run(estimate: @escaping @MainActor () async -> Int64?, isCheap: Bool = false,
             action: @escaping @MainActor (_ estimate: Int64?) -> Void) async {
        guard NetworkCost.shared.isExpensive else {
            let bytes: Int64? = if isCheap { await estimate() } else { nil }
            action(bytes)
            return
        }
        let bytes = await estimate()
        if let bytes, bytes <= Self.limit {
            action(bytes)
        } else {
            pending = Pending(bytes: bytes, action: action)
        }
    }

    /// What's downloaded so far: "3.2 MB", or "3.2 MB / ~48 MB" with an estimate (the files'
    /// size, so the download usually ends below it).
    static func progressText(_ progress: FetchProgress, estimate: Int64?) -> String {
        let received = Int64(progress.receivedBytes).formatted(.byteCount(style: .file))
        guard let estimate, estimate > 0 else { return received }
        return received + " / ~" + estimate.formatted(.byteCount(style: .file))
    }

    /// What Clone downloads, roughly: the whole repository's files, from the project's saved
    /// file list.
    static func cloneEstimate(projectID: String) async -> Int64? {
        guard let tree = try? await ProjectStore.shared.tree(for: projectID).1, !tree.truncated else { return nil }
        let bytes = tree.entries.reduce(Int64(0)) { $0 + Int64($1.size ?? 0) }
        return bytes > 0 ? bytes : nil
    }
}

extension View {
    /// Asks before a download `downloads` holds back.
    func downloadConfirmation(_ downloads: DownloadGuard) -> some View {
        modifier(DownloadConfirmation(downloads: downloads))
    }
}

private struct DownloadConfirmation: ViewModifier {
    let downloads: DownloadGuard

    func body(content: Content) -> some View {
        content.confirmationDialog(
            "Download on a mobile network?",
            isPresented: Binding(get: { downloads.pending != nil }, set: { if !$0 { downloads.pending = nil } }),
            titleVisibility: .visible, presenting: downloads.pending
        ) { pending in
            Button("Download") { pending.action(pending.bytes) }
            Button("Cancel", role: .cancel) {}
        } message: { pending in
            if let bytes = pending.bytes {
                Text("This downloads up to \(bytes.formatted(.byteCount(style: .file))) (usually less: Git compresses it).")
            } else {
                Text("How much this downloads couldn’t be told.")
            }
        }
    }
}
