import Foundation
import SwiftUI

/// State for one file on screen: its text, the Safari-style progress line and the bottom bar.
@MainActor @Observable
final class CodeDocumentModel {
    enum Phase {
        case loading
        case loaded(RenderedText, version: UUID)
        case failed(message: String)
    }

    enum SymbolIndex {
        case indexing
        case ready([CodeSymbol])
        case unsupportedLanguage
    }

    let url: URL
    var fileName: String { url.displayFileName }

    private(set) var phase: Phase = .loading
    /// The definitions for Symbols mode and symbol search: the open file's, then (once asked for
    /// with `loadProjectSymbols()`) those of the project's other downloaded files.
    private(set) var symbolIndex: SymbolIndex = .indexing
    /// The project's other files have been indexed (or the file isn't in a project).
    private(set) var projectSymbolsLoaded = false
    /// Other files' text, for their symbols' pages. Loaded when a page needs it; a few are kept.
    private var otherTexts: [URL: NSAttributedString] = [:]
    /// The download is a web page (raw HTML), so the viewer offers to open it in the browser.
    private(set) var isWebPage = false
    private(set) var isBarCollapsed = false
    /// Goes up each time the reader taps the collapsed bar, so the text view can stop a fling.
    private(set) var barTapCount = 0

    /// 0...1. Drawn with `scaleEffect`, so animating it never re-lays out the bar.
    private(set) var progressFraction: Double = 0
    private(set) var isProgressVisible = false

    /// Set when a pull-to-refresh fails while text is on screen.
    var refreshError: String?

    private let store: DocumentStore
    @ObservationIgnored private var isFetching = false
    @ObservationIgnored private var progressToken = 0
    @ObservationIgnored private var trickleTask: Task<Void, Never>?
    @ObservationIgnored private var ownSymbols: SymbolIndexer.Outcome?
    @ObservationIgnored private var otherFiles: [ProjectSymbolIndex.FileSymbols] = []
    @ObservationIgnored private var isLoadingProjectSymbols = false
    @ObservationIgnored private var loadingTexts: Set<URL> = []
    @ObservationIgnored private var textOrder: [URL] = []

    init(url: URL, store: DocumentStore) {
        self.url = url
        self.store = store
    }

    // MARK: - Loading

    /// Shows the saved copy without touching the network. Downloads only if there is none.
    func load() async {
        guard case .loading = phase else { return }
        if let cached = await store.cached(url) {
            await show(cached)
        } else {
            await download(isRefresh: false)
        }
    }

    /// Pull-to-refresh: the only way a saved file is ever downloaded again.
    func refresh() async {
        await download(isRefresh: true)
    }

    func retry() async {
        phase = .loading
        await download(isRefresh: false)
    }

    private func download(isRefresh: Bool) async {
        guard !isFetching else { return }
        isFetching = true
        defer { isFetching = false }

        let token = beginProgress()
        do {
            let result = try await store.fetch(url) { [weak self] fraction in
                Task { @MainActor [weak self] in self?.reportProgress(fraction, token: token) }
            }
            finishProgress(token)
            switch result {
            case .updated(let document):
                await show(document)
            case .notModified(let document):
                // Normally the text is already on screen and nothing changes.
                if case .loaded = phase {} else { await show(document) }
            }
        } catch {
            finishProgress(token)
            if isRefresh, case .loaded = phase {
                refreshError = error.localizedDescription  // keep the text on screen
            } else {
                phase = .failed(message: error.localizedDescription)
            }
        }
    }

    private func show(_ document: StoredDocument) async {
        // Decoding and styling happen off the main thread; the text view then lays it out.
        let rendered = await Task.detached(priority: .userInitiated) {
            RawTextStyle.render(document)
        }.value
        let version = UUID()
        isWebPage = WebPageDetector.isWebPage(contentType: document.metadata.contentType, data: document.data)
        phase = .loaded(rendered, version: version)
        await indexSymbols(of: rendered, version: version)
    }

    /// Parses the text off the main thread once per version. A few ms for a typical file.
    private func indexSymbols(of rendered: RenderedText, version: UUID) async {
        let fileExtension = url.pathExtension
        let outcome = await Task.detached(priority: .utility) {
            SymbolIndexer.index(rendered.attributedString.string, fileExtension: fileExtension)
        }.value
        guard case .loaded(_, let current) = phase, current == version else { return }  // newer text arrived
        ownSymbols = outcome
        publishSymbols()
    }

    /// Indexes the project's other downloaded files, once per opened file. Only when Symbols or
    /// a search needs them, so reading a file costs nothing extra.
    func loadProjectSymbols() {
        guard !projectSymbolsLoaded, !isLoadingProjectSymbols else { return }
        isLoadingProjectSymbols = true
        Task {
            let projects = await ProjectStore.shared.projects()
            if let project = ProjectSymbolIndex.project(containing: url, in: projects) {
                otherFiles = await ProjectSymbolIndex.shared.symbols(in: project, excluding: url)
            }
            isLoadingProjectSymbols = false
            projectSymbolsLoaded = true
            publishSymbols()
        }
    }

    /// One flat list: the open file's symbols in file order, then each other file's, in path
    /// order. Ids are positions in this list.
    private func publishSymbols() {
        guard let ownSymbols else { return }
        var combined: [CodeSymbol] = []
        if case .symbols(let own) = ownSymbols { combined = own }
        for file in otherFiles {
            for symbol in file.symbols {
                combined.append(symbol.moved(to: combined.count, file: file.url))
            }
        }
        if case .unsupportedLanguage = ownSymbols, combined.isEmpty {
            symbolIndex = .unsupportedLanguage
        } else {
            symbolIndex = .ready(combined)
        }
    }

    /// The text of one symbol, styled like the file. `nil` while another file's text is loading.
    func text(of symbol: CodeSymbol) -> NSAttributedString? {
        guard let full = fullText(of: symbol.fileURL), NSMaxRange(symbol.range) <= full.length else { return nil }
        return full.attributedSubstring(from: symbol.range)
    }

    /// The whole text of the open file (`nil` or its URL) or of another project file. Another
    /// file's text is loaded on first use: this returns `nil` until it's ready.
    func fullText(of file: URL?) -> NSAttributedString? {
        guard let file, file != url else {
            guard case .loaded(let rendered, _) = phase else { return nil }
            return rendered.attributedString
        }
        if let text = otherTexts[file] { return text }
        loadText(of: file)
        return nil
    }

    private func loadText(of file: URL) {
        guard !loadingTexts.contains(file) else { return }
        loadingTexts.insert(file)
        Task {
            defer { loadingTexts.remove(file) }
            guard let document = await store.cached(file) else { return }
            let rendered = await Task.detached(priority: .userInitiated) {
                RawTextStyle.render(document)
            }.value
            // Pages show a few files at a time; keep the last few, not the whole project.
            textOrder.removeAll { $0 == file }
            textOrder.append(file)
            if textOrder.count > 6 { otherTexts[textOrder.removeFirst()] = nil }
            otherTexts[file] = rendered.attributedString
        }
    }

    // MARK: - Bottom bar

    /// The reader tapped the collapsed bar.
    func expandBarFromTap() {
        barTapCount += 1
        setBarCollapsed(false)
    }

    func setBarCollapsed(_ collapsed: Bool) {
        guard collapsed != isBarCollapsed else { return }
        withAnimation(.smooth(duration: 0.3)) { isBarCollapsed = collapsed }
    }

    // MARK: - Progress line (Safari-style)

    private func beginProgress() -> Int {
        progressToken += 1
        let token = progressToken
        trickleTask?.cancel()

        var reset = Transaction()
        reset.disablesAnimations = true
        withTransaction(reset) { progressFraction = 0.1 }
        withAnimation(.easeOut(duration: 0.15)) { isProgressVisible = true }

        // While the size is unknown, creep toward 90% the way Safari does. Runs only while loading.
        trickleTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, !Task.isCancelled, self.progressToken == token else { return }
                withAnimation(.linear(duration: 0.25)) {
                    self.progressFraction += (0.9 - self.progressFraction) * 0.08
                }
            }
        }
        return token
    }

    private func reportProgress(_ fraction: Double?, token: Int) {
        guard token == progressToken, let fraction else { return }
        let target = 0.1 + 0.8 * min(max(fraction, 0), 1)
        guard target > progressFraction else { return }  // never moves backward
        withAnimation(.easeOut(duration: 0.2)) { progressFraction = target }
    }

    private func finishProgress(_ token: Int) {
        guard token == progressToken else { return }
        trickleTask?.cancel()
        trickleTask = nil
        withAnimation(.easeOut(duration: 0.2)) { progressFraction = 1 }
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard let self, self.progressToken == token else { return }
            withAnimation(.easeOut(duration: 0.3)) { self.isProgressVisible = false }
        }
    }
}
