import Foundation

/// The file to open when you move from a project chosen in the sidebar to the symbol levels
/// (Files, Symbols, Code), which list the open file's project: when the open file is in
/// another one, one of this project's files takes its place.
nonisolated enum ProjectStartFile {
    /// - Returns: `nil` when `current` is already in the project (nothing to change), or the
    ///   project has no file to open.
    static func find(projectID: String, current: URL?) async -> URL? {
        guard !projectID.isEmpty, let project = await ProjectStore.shared.project(id: projectID) else {
            return nil
        }
        let filter = ProjectFilterStore.standard.filter(for: projectID)
        // Where its files start is known once its list has been fetched.
        if let prefix = ProjectSymbolIndex.prefix(of: project) {
            if let current, current.absoluteString.hasPrefix(prefix) { return nil }
            let history = await OpenHistory.shared.snapshot()
            let saved = await DocumentStore.shared.savedDocuments().map(\.url)
            if let url = choose(prefix: prefix, filter: filter, history: history, saved: saved, treeFiles: []) {
                return url
            }
        }
        // Nothing opened or downloaded yet: a file from its list (saved, or fetched now),
        // which opening downloads.
        guard let fetched = try? await ProjectStore.shared.tree(for: projectID) else { return nil }
        let (listed, tree) = fetched
        guard let prefix = ProjectSymbolIndex.prefix(of: listed) else { return nil }
        if let current, current.absoluteString.hasPrefix(prefix) { return nil }
        let files = tree.directories(under: listed.folder ?? "", matching: filter)
            .flatMap(\.files)
            .compactMap { listed.rawURL(for: $0.path) }
        return choose(prefix: prefix, filter: filter, history: [:], saved: [], treeFiles: files)
    }

    /// The project's file you opened last; else its first downloaded file, in path order; else
    /// its README, or else the first file in the Project tab's order (`treeFiles`). Only files
    /// the project's filter lets through.
    static func choose(prefix: String, filter: FileFilter, history: [String: Date], saved: [URL],
                       treeFiles: [URL]) -> URL? {
        func passes(_ address: String) -> Bool {
            guard address.hasPrefix(prefix) else { return false }
            guard !filter.isEmpty else { return true }
            let relative = String(address.dropFirst(prefix.count))
            return filter.matches(relative.removingPercentEncoding ?? relative)
        }
        if let last = history.filter({ passes($0.key) }).max(by: { $0.value < $1.value }),
           let url = URL(string: last.key) {
            return url
        }
        if let first = saved.filter({ passes($0.absoluteString) })
            .min(by: { $0.absoluteString.localizedStandardCompare($1.absoluteString) == .orderedAscending }) {
            return first
        }
        let listed = treeFiles.filter { passes($0.absoluteString) }
        let topLevel = listed.filter { !$0.absoluteString.dropFirst(prefix.count).contains("/") }
        return topLevel.first { $0.lastPathComponent.lowercased().hasPrefix("readme") } ?? listed.first
    }
}
