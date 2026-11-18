import Foundation

/// The decoded text of downloaded files, for the Code level: each symbol's code is asked for
/// once and kept, so loading one file's text redraws only that symbol.
/// Recently used files are kept (least recently used go first), decoded the same way the
/// symbols were indexed, so their ranges match.
actor FileTextCache {
    static let shared = FileTextCache()

    /// Files kept in memory.
    static let capacity = 64

    private let store: DocumentStore
    private var texts: [URL: String] = [:]
    private var order: [URL] = []

    init(store: DocumentStore = .shared) {
        self.store = store
    }

    /// A symbol's code in a downloaded file, tabs expanded, worked out away from the main
    /// thread and alongside other requests (only reading the file's text goes through here,
    /// once per file). `nil` if the file isn't saved.
    nonisolated func code(of range: NSRange, in file: URL, priority: TaskPriority) async -> String? {
        guard let text = await text(of: file) else { return nil }
        return await Task.detached(priority: priority) {
            let utf16 = text as NSString
            return NSMaxRange(range) <= utf16.length ? TabExpansion.expand(utf16.substring(with: range)) : nil
        }.value
    }

    /// Forgets a file's text (it was downloaded again).
    func forget(_ file: URL) {
        texts[file] = nil
        reading[file] = nil
        order.removeAll { $0 == file }
    }

    /// A file's text, decoded once: requests that arrive while it's being read share that read.
    func text(of file: URL) async -> String? {
        if let text = texts[file] {
            touch(file)
            return text
        }
        if let reading = reading[file] { return await reading.value }
        let store = store
        let read = Task.detached(priority: .userInitiated) { () -> String? in
            guard let document = await store.cached(file) else { return nil }
            return RawTextDecoder.decode(document.data, contentType: document.metadata.contentType)
        }
        reading[file] = read
        let text = await read.value
        reading[file] = nil
        if let text {
            texts[file] = text
            touch(file)
            while order.count > Self.capacity { texts[order.removeFirst()] = nil }
        }
        return text
    }

    /// Files being read now.
    private var reading: [URL: Task<String?, Never>] = [:]

    private func touch(_ file: URL) {
        order.removeAll { $0 == file }
        order.append(file)
    }
}
