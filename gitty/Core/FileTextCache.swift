import Foundation

/// The decoded text of downloaded files, for the Code level's blocks: each block asks for its
/// symbol's code once and keeps it, so loading one file's text redraws only its blocks.
/// Recently used files are kept (least recently used go first), decoded the same way the
/// symbols were indexed, so their ranges match.
actor FileTextCache {
    static let shared = FileTextCache()

    /// Files kept in memory.
    static let capacity = 64

    private let store: DocumentStore
    private var texts: [URL: NSString] = [:]
    private var order: [URL] = []

    init(store: DocumentStore = .shared) {
        self.store = store
    }

    /// A symbol's code in a downloaded file, tabs expanded. `nil` if the file isn't saved.
    func code(of range: NSRange, in file: URL) async -> String? {
        guard let text = await text(of: file) else { return nil }
        guard NSMaxRange(range) <= text.length else { return nil }
        return TabExpansion.expand(text.substring(with: range))
    }

    /// Forgets a file's text (it was downloaded again).
    func forget(_ file: URL) {
        texts[file] = nil
        order.removeAll { $0 == file }
    }

    private func text(of file: URL) async -> NSString? {
        if let text = texts[file] {
            touch(file)
            return text
        }
        guard let document = await store.cached(file) else { return nil }
        let text = RawTextDecoder.decode(document.data, contentType: document.metadata.contentType) as NSString
        texts[file] = text
        touch(file)
        while order.count > Self.capacity { texts[order.removeFirst()] = nil }
        return text
    }

    private func touch(_ file: URL) {
        order.removeAll { $0 == file }
        order.append(file)
    }
}
