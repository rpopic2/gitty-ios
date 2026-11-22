import SwiftUI

/// Fetch Older, at the end of a history: a shallow clone's oldest commits are where its
/// downloaded history starts, and older ones come from GitHub only when asked (the history
/// shows what's in the clone, offline). `CloneStore.historyStep` commits at a time, with their
/// progress and Cancel.
@MainActor @Observable
final class OlderCommitsFetch {
    /// While fetching.
    private(set) var progress: FetchProgress?
    private(set) var errorMessage: String?
    @ObservationIgnored private var task: Task<Void, Never>?

    /// Fetches older commits of the project's checked-out branch or tag, then `done` (to list
    /// them). Cancel stops it, and isn't an error.
    func start(projectID: String, then done: @escaping @MainActor () async -> Void) {
        guard task == nil else { return }
        errorMessage = nil
        progress = .start
        task = Task {
            let (updates, continuation) = AsyncStream.makeStream(of: FetchProgress.self,
                                                                 bufferingPolicy: .bufferingNewest(1))
            let listener = Task {
                for await update in updates where self.progress != nil { self.progress = update }
            }
            var fetched = false
            do {
                try await CloneStore.shared.loadMoreHistory(projectID: projectID) { continuation.yield($0) }
                fetched = true
            } catch {
                if !Task.isCancelled { errorMessage = error.localizedDescription }
            }
            continuation.finish()
            listener.cancel()
            progress = nil
            task = nil
            if fetched { await done() }
        }
    }

    func cancel() {
        task?.cancel()
    }
}

/// The last row of a history whose clone has older commits on GitHub: Fetch Older, or while
/// fetching, how far it's got and Cancel.
struct OlderCommitsRow: View {
    let fetch: OlderCommitsFetch
    let action: @MainActor () -> Void

    var body: some View {
        if let progress = fetch.progress {
            HStack {
                ProgressView(value: progress.fraction)
                Text(DownloadGuard.progressText(progress, estimate: nil))
                    .font(.footnote)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Button("Cancel", systemImage: "xmark.circle.fill") { fetch.cancel() }
                    .labelStyle(.iconOnly)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .buttonStyle(.borderless)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Fetching older commits")
        } else {
            Button(action: action) {
                HStack {
                    Label("Fetch Older", systemImage: "arrow.down.circle")
                    Spacer()
                    Text("\(CloneStore.historyStep) commits")
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityHint(Text("Downloads \(CloneStore.historyStep) older commits from GitHub"))
        }
    }
}
