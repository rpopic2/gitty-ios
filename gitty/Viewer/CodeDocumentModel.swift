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

        var isReady: Bool {
            if case .ready = self { true } else { false }
        }
    }

    let url: URL
    var fileName: String { url.displayFileName }

    private(set) var phase: Phase = .loading
    /// The loaded text as plain text, for the Code level: one object per version, so views
    /// holding it redraw only when the text changes.
    @ObservationIgnored private(set) var plainText: NSString?
    /// The definitions for Symbols mode and symbol search: the open file's, then (once asked for
    /// with `loadProjectSymbols()`) those of the project's other downloaded files.
    private(set) var symbolIndex: SymbolIndex = .indexing
    /// The project's other files have been indexed (or the file isn't in a project).
    private(set) var projectSymbolsLoaded = false
    /// The symbol search's matches so far, best first (every symbol, in order, without a search).
    /// They fill in while `isSearching`; see `search(_:)`.
    private(set) var searchResults: [CodeSymbol] = []
    /// The search `searchResults` are for.
    private(set) var resultsQuery = ""
    /// A search is still going through the symbols.
    private(set) var isSearching = false
    /// The project the open file is in (once the project's symbols are loaded), whose Symbols
    /// order `symbolSorting` is. `nil` for a file that isn't in a project.
    private(set) var symbolsProjectID: String?
    /// The order of the project's other files in Symbols (the open file always comes first;
    /// each file's symbols stay in file order).
    private(set) var symbolSorting = ListSorting()
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
    /// The open file's own entry in the list, before its symbols.
    @ObservationIgnored private var ownFileEntry: CodeSymbol?
    @ObservationIgnored private var otherFiles: [ProjectSymbolIndex.FileSymbols] = []
    @ObservationIgnored private var isLoadingProjectSymbols = false
    /// The symbols' names, prepared for searching (built in the background for each new list).
    @ObservationIgnored private var searchIndex: SymbolSearch.Index?
    @ObservationIgnored private var indexTask: Task<Void, Never>?
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    /// The latest search asked for, run again when the symbols change.
    @ObservationIgnored private var wantedQuery = ""
    /// When files were last opened, for recently opened order.
    @ObservationIgnored private var openDates: [String: Date] = [:]
    /// The project filter the other files were indexed with.
    @ObservationIgnored private var loadedFilter: FileFilter?
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

    /// Pull to refresh on a file's page: downloads that file again. Another project file's
    /// page shows the new text once it's loaded, and its symbols are indexed again.
    func refresh(file: URL?) async {
        guard let file, file != url else { return await refresh() }
        do {
            _ = try await store.fetch(file)
            await FileTextCache.shared.forget(file)
            otherTexts[file] = nil
            textOrder.removeAll { $0 == file }
            loadedFilter = nil  // index the project's files again (only the changed one is redone)
            loadProjectSymbols()
        } catch {
            refreshError = error.localizedDescription
        }
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
        plainText = rendered.attributedString.string as NSString
        phase = .loaded(rendered, version: version)
        await indexSymbols(of: rendered, version: version)
    }

    /// Parses the text off the main thread once per version. A few ms for a typical file.
    private func indexSymbols(of rendered: RenderedText, version: UUID) async {
        let fileExtension = url.pathExtension
        let name = fileName
        let (outcome, fileEntry) = await Task.detached(priority: .utility) {
            let text = rendered.attributedString.string
            return (SymbolIndexer.index(text, fileExtension: fileExtension),
                    SymbolIndexer.fileEntry(named: name, text: text))
        }.value
        guard case .loaded(_, let current) = phase, current == version else { return }  // newer text arrived
        ownSymbols = outcome
        ownFileEntry = fileEntry
        publishSymbols()
    }

    /// Indexes the project's other downloaded files that its filter lets through: once per
    /// opened file, and again if the filter has changed since. Only when Symbols or a search
    /// needs them, so reading a file costs nothing extra. The open file is always included.
    func loadProjectSymbols() {
        guard !isLoadingProjectSymbols else { return }
        isLoadingProjectSymbols = true
        Task {
            let projects = await ProjectStore.shared.projects()
            let project = ProjectSymbolIndex.project(containing: url, in: projects)
            if let project, symbolsProjectID != project.id {
                symbolsProjectID = project.id
                symbolSorting = ListSortingStore.standard.sorting(for: .symbols, projectID: project.id)
            }
            openDates = await OpenHistory.shared.snapshot()
            let filter = project.map { ProjectFilterStore.standard.filter(for: $0.id) } ?? .none
            if projectSymbolsLoaded, filter == loadedFilter {
                isLoadingProjectSymbols = false
                return
            }
            if let project {
                otherFiles = await ProjectSymbolIndex.shared.symbols(in: project, excluding: url, matching: filter)
            }
            loadedFilter = filter
            isLoadingProjectSymbols = false
            projectSymbolsLoaded = true
            publishSymbols()
        }
    }

    /// One flat list: the open file's entry and its symbols in file order, then each other
    /// file's entry and symbols, in path order. Ids are positions in this list.
    private func publishSymbols() {
        guard let ownSymbols else { return }
        var combined: [CodeSymbol] = []
        // Each file's entry, then its symbols. A file without symbols (a README, a web page,
        // another language) is just its entry: its page is the whole file.
        var own: [CodeSymbol] = []
        if case .symbols(let symbols) = ownSymbols { own = symbols }
        combined = ((ownFileEntry.map { [$0] } ?? []) + own).enumerated().map { $1.moved(to: $0, file: nil) }
        let files = symbolSorting.arrange(otherFiles, key: { $0.url.absoluteString },
                                          name: { $0.url.absoluteString }, history: openDates)
        for file in files {
            combined.append(file.file.moved(to: combined.count, file: file.url))
            for symbol in file.symbols {
                combined.append(symbol.moved(to: combined.count, file: file.url))
            }
        }
        symbolIndex = .ready(combined)
        prepareSearch(for: combined)
    }

    /// The sort button in Symbols: reorders the project's other files and saves the choice for
    /// the project.
    func setSymbolSorting(_ sorting: ListSorting) {
        guard sorting != symbolSorting else { return }
        symbolSorting = sorting
        if let symbolsProjectID {
            ListSortingStore.standard.save(sorting, for: .symbols, projectID: symbolsProjectID)
        }
        publishSymbols()
    }

    // MARK: - Symbol search

    /// Searches the symbols in the background. Matches fill `searchResults` as they're found
    /// (the open file's first, since its symbols come first), and a newer search replaces this
    /// one, which stops. An empty search shows every symbol at once.
    func search(_ query: String) {
        wantedQuery = query
        searchTask?.cancel()
        searchTask = nil
        guard let index = searchIndex else { return }  // runs once the index is built
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            searchResults = index.symbols
            resultsQuery = query
            isSearching = false
            return
        }
        isSearching = true
        searchTask = Task {
            for await snapshot in SymbolSearch.stream(query, in: index) {
                guard !Task.isCancelled else { return }
                searchResults = snapshot
                resultsQuery = query
            }
            guard !Task.isCancelled else { return }
            isSearching = false
        }
    }

    /// Builds the search index for a new list of symbols, away from the main thread, then runs
    /// the current search on it.
    private func prepareSearch(for symbols: [CodeSymbol]) {
        indexTask?.cancel()
        indexTask = Task {
            let index = await Task.detached(priority: .userInitiated) { SymbolSearch.Index(symbols) }.value
            guard !Task.isCancelled else { return }
            searchIndex = index
            search(wantedQuery)
        }
    }

    /// The text of one symbol, styled like the file. `nil` while another file's text is loading.
    /// A file's own entry gets the file's text object itself, the same one until it's refreshed.
    func text(of symbol: CodeSymbol) -> NSAttributedString? {
        guard let full = fullText(of: symbol.fileURL), NSMaxRange(symbol.range) <= full.length else { return nil }
        if symbol.range == NSRange(location: 0, length: full.length) { return full }
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
            // Pages show a few files at a time; keep the last few, not the whole project. (The
            // Code level has its own cache: `FileTextCache`.)
            textOrder.removeAll { $0 == file }
            textOrder.append(file)
            if textOrder.count > 8 { otherTexts[textOrder.removeFirst()] = nil }
            otherTexts[file] = rendered.attributedString
        }
    }

    // MARK: - Bottom bar

    /// The reader tapped the collapsed bar.
    func expandBarFromTap() {
        barTapCount += 1
        setBarCollapsed(false)
    }

    /// Not animated here: the bar animates itself (`CodeScreen`). An animation around this
    /// change would run through the whole screen, the scrolling list included, and stop a fling.
    func setBarCollapsed(_ collapsed: Bool) {
        guard collapsed != isBarCollapsed else { return }
        isBarCollapsed = collapsed
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
