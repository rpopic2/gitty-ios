import SwiftUI
import UIKit

/// The open file and its project, with a Safari-style bar and the Photos-style selector at the
/// bottom, which switches between the levels (`ViewMode`): the project's files, then its symbols
/// as rows, as cards, and as whole code. A file's own page (tap its entry) is the whole file.
struct CodeScreen: View {
    @State private var model: CodeDocumentModel
    @Environment(\.openURL) private var openURL
    /// For the pager's zoom transition, which closes it with a pinch or a swipe down. No view in
    /// the list is marked as its source (that tracking cost scrolling), so it zooms from the
    /// middle of the screen.
    @Namespace private var pagerNamespace
    /// The reader closed the "This is a web page." banner for this file.
    @State private var isWebPageBannerDismissed = false
    /// Tapping the bar edits the address; the editor covers the screen while it's open.
    @Binding var isEditingAddress: Bool
    /// A shared link that couldn't be opened: the editor starts with it and says why.
    let rejectedAddress: String?
    let onOpen: @MainActor (URL) -> Void
    let onPasteAndGo: @MainActor () -> Void
    /// An album chosen in the Project tab.
    let onOpenAlbum: @MainActor (UUID) -> Void
    /// The Project tab's project row: the whole project (out of an album).
    let onShowProject: @MainActor () -> Void
    @Binding var mode: ViewMode
    /// The project chosen in the sidebar ("" for Files), shown in Project mode.
    let projectID: String
    /// Just opened: the list starts at the file's own entry, not where it was left.
    let opensAtFile: Bool
    /// The album chosen in the sidebar: the levels show only what's in it (when it's of the
    /// open file's project).
    let albumID: UUID?

    /// The cards and search results pushed over the Code level (`CardRoute`).
    @Binding var cardPath: [CardRoute]
    /// The cards in `cardPath`. Ones no longer in it are dropped when the next card opens (not
    /// when they close: they're still on screen while they zoom away).
    @State private var stackedCards: [UUID: StackedCard] = [:]
    /// The occurrences pages in `cardPath`.
    @State private var stackedOccurrences: [UUID: OccurrenceSearch] = [:]
    /// The identifier highlighted on pages: Occurrences highlights what it looks for.
    @Environment(HighlightState.self) private var highlights: HighlightState?
    /// The search results pages in `cardPath`, each with its own search (like Occurrences').
    @State private var stackedSearches: [UUID: StackSearch] = [:]
    /// Tapping the bar shows Project with a search field, like Safari's start page (`mode` is
    /// `.project` while it's open): the first letters typed open a results page, as Search on
    /// a card does, the typing going on in its field.
    @State private var browseQuery = ""
    /// The symbol on screen in each card.
    @State private var cardPlaces = CardPlaces()
    /// The stack's symbols, in a sheet (tap a page's stack icon).
    @State private var isShowingStack = false
    /// The card to go back to once that sheet has gone (a symbol tapped in it).
    @State private var stackJump: CardRoute?
    /// A commit tapped in the blame (the peek's second stop): its files and diffs, in a sheet.
    @State private var blameCommit: BlameCommit?

    private struct BlameCommit: Identifiable {
        let projectID: String
        let commit: GitCommit
        var id: String { commit.id }
    }

    /// What's folded in that sheet: its own, not the Code level's.
    @State private var stackSheetFolds = CollapsedCodeStore.temporary()
    /// Brings a symbol into view in the Code list (the open file's entry, chosen in Project).
    @State private var listScrollRequest: SymbolScrollRequest?
    /// Collapse All or Expand All, from the bar's menu.
    @State private var collapseRequest: CollapseRequest?
    /// The file whose info and history are showing (Show History in the Code level's menu).
    @State private var historyFile: HistoryFile?
    /// Pull or Load More History failed, for a diff album.
    @State private var diffAlbumError: String?
    @State private var historyDetent: PresentationDetent = .large
    /// Delete Album chosen in the bar's menu, waiting to be confirmed.
    @State private var albumToDelete: Album?

    private struct HistoryFile: Identifiable {
        let url: URL
        /// The symbol it was asked from (`nil`: a file's title), for Open Whole File.
        var symbol: CodeSymbol? = nil
        var id: URL { url }
    }
    /// The list hasn't started yet: when `opensAtFile`, it starts at the file's own entry.
    @State private var startsAtFile: Bool
    /// Project has been shown at least once (it's kept from then on).
    @State private var hasShownProject = false
    /// The project chosen in the sidebar, for the bar in Project mode (`nil` for Files).
    @State private var project: ProjectInfo?
    /// The review that Comment adds to.
    @Environment(ReviewDraft.self) private var review
    @AppStorage("reviewFormat") private var reviewFormat: ReviewFormat = .compact
    /// The code font: when it changes, the pages' text is styled again.
    @Environment(\.codeTextStyle) private var codeTextStyle
    @Environment(AlbumNaming.self) private var albumNaming: AlbumNaming?

    init(url: URL, mode: Binding<ViewMode>, projectID: String, opensAtFile: Bool = false, albumID: UUID? = nil,
         cardPath: Binding<[CardRoute]>, isEditingAddress: Binding<Bool>, rejectedAddress: String? = nil,
         onOpen: @escaping @MainActor (URL) -> Void, onPasteAndGo: @escaping @MainActor () -> Void,
         onOpenAlbum: @escaping @MainActor (UUID) -> Void = { _ in },
         onShowProject: @escaping @MainActor () -> Void = {},
         store: DocumentStore = .shared) {
        _model = State(initialValue: CodeDocumentModel(url: url, store: store))
        _mode = mode
        _cardPath = cardPath
        self.projectID = projectID
        self.opensAtFile = opensAtFile
        self.albumID = albumID
        _startsAtFile = State(initialValue: opensAtFile)
        _isEditingAddress = isEditingAddress
        self.rejectedAddress = rejectedAddress
        self.onOpen = onOpen
        self.onPasteAndGo = onPasteAndGo
        self.onOpenAlbum = onOpenAlbum
        self.onShowProject = onShowProject
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            content
            // Only the bar (and the banner) animate when it collapses or expands: the list keeps
            // scrolling undisturbed.
            bottom
                .animation(.smooth(duration: 0.3), value: model.isBarCollapsed)
        }
        .overlay(alignment: .top) {
            webPageBanner
                .animation(.smooth(duration: 0.3), value: model.isBarCollapsed)
        }
        .overlay(alignment: .top) { StatusBarBackdrop() }
        .toolbar(.hidden, for: .navigationBar)
        .task { await model.load() }
        .task(id: projectID) {
            project = projectID.isEmpty ? nil : await ProjectStore.shared.project(id: projectID)
        }
        .onChange(of: mode) { old, _ in
            model.setBarCollapsed(false)
            if mode != .project { browseQuery = "" }
            // Back from Project, where the filter may have changed: index again if it did.
            if mode.showsSymbols, model.symbolIndex.isReady { model.loadProjectSymbols() }
            // …and where files may have been added to the album.
            if old == .project, mode.showsSymbols { model.refreshAlbumFiles() }
        }
        .onChange(of: AlbumStore.shared.album(id: albumID), initial: true) { _, album in
            model.show(album: album)
        }
        .onChange(of: AlbumStore.shared.downloadCount) { model.refreshAlbumFiles() }
        .onChange(of: mode, initial: true) {
            if mode == .project { hasShownProject = true }
        }
        // The levels list the whole project, so its files are indexed right away.
        .onChange(of: model.symbolIndex.isReady, initial: true) {
            if model.symbolIndex.isReady { model.loadProjectSymbols() }
        }
        .onChange(of: codeTextStyle) { Task { await model.restyle() } }
        .onChange(of: browseQuery) { _, query in
            let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
            // An address being typed (or pasted) stays here, for Return.
            guard !text.isEmpty, !Self.mayBeAddress(text) else { return }
            browseQuery = ""
            searchFromBar(query)
        }
        .navigationDestination(for: CardRoute.self) { route in
            switch route {
            case .card(let id):
                if let card = stackedCards[id] { cardView(card, id: id, route: route) }
            case .results(let id):
                if let search = stackedSearches[id] { resultsView(search, route: route) }
            case .occurrences(let id):
                if let search = stackedOccurrences[id] { occurrencesView(search, route: route) }
            }
        }
        .sheet(isPresented: $isShowingStack, onDismiss: {
            if let jump = stackJump {
                stackJump = nil
                goBack(to: jump)
            }
        }) {
            stackSheet
        }
        .sheet(item: $blameCommit) { item in
            NavigationStack {
                CommitFilesView(projectID: item.projectID, commit: item.commit)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { blameCommit = nil }
                        }
                    }
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .sheet(item: $historyFile) { file in
            // All the way up, for the history: it can be pulled down to half.
            FileInfoView(url: file.url, onOpenWholeFile: file.symbol.map { symbol in { openWholeFile(from: symbol) } })
                .presentationDetents([.medium, .large], selection: $historyDetent)
                .presentationDragIndicator(.visible)
        }
        // Delete Album in the bar's menu: asked first, like Photos.
        .confirmationDialog(albumToDelete.map { "Delete “\($0.name)”?" } ?? "",
                            isPresented: Binding(get: { albumToDelete != nil }, set: { if !$0 { albumToDelete = nil } }),
                            titleVisibility: .visible, presenting: albumToDelete) { album in
            Button("Delete Album", role: .destructive) { delete(album) }
        } message: { _ in
            Text("What’s in it stays in the project.")
        }
        .alert("Couldn’t Refresh", isPresented: refreshAlertIsPresented, presenting: model.refreshError) { _ in
            Button("OK", role: .cancel) {}
        } message: { message in
            Text(message)
        }
        .alert("Couldn’t Download", isPresented: Binding(get: { diffAlbumError != nil },
                                                          set: { if !$0 { diffAlbumError = nil } }),
               presenting: diffAlbumError) { _ in
            Button("OK", role: .cancel) {}
        } message: { message in
            Text(message)
        }
    }

    private var content: some View {
        ZStack {
            document
                .accessibilityHidden(mode == .project)
            // Project lists files, so it doesn't depend on this file loading (or failing with a 404).
            // Built on first use, then kept (hidden) like the symbols, so switching back is
            // instant: it doesn't read and group the project's files again.
            if hasShownProject {
                let isShowingProject = mode == .project
                ProjectView(projectID: projectID, currentURL: model.url, isActive: isShowingProject,
                            currentAlbumID: albumID, onOpenAlbum: onOpenAlbum,
                            onShowProject: onShowProject) { url in
                    open(url)
                }
                .equatable()  // hidden, its big list mustn't redraw each time this screen does
                .opacity(isShowingProject ? 1 : 0)
                .allowsHitTesting(isShowingProject)
                .accessibilityHidden(!isShowingProject)
            }
        }
        // The source for pages opened at the lines tapped (see `screenSourceID`).
        .matchedTransitionSource(id: Self.screenSourceID, in: pagerNamespace)
    }

    /// The open file's symbol levels: loading, loaded, or the reason it couldn't load.
    @ViewBuilder
    private var document: some View {
        switch model.phase {
        case .loading:
            // A blank page while the progress line runs, as in Safari.
            Color(uiColor: RawTextStyle.backgroundColor)
                .ignoresSafeArea()
        case .loaded:
            // Kept alive while Project covers it, so it keeps its exact scroll position.
            symbols
                .opacity(mode.showsSymbols ? 1 : 0)
                .allowsHitTesting(mode.showsSymbols)
                .accessibilityHidden(!mode.showsSymbols)
        case .failed(let message):
            ContentUnavailableView {
                Label("Couldn’t Load File", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") { Task { await model.retry() } }
            }
        }
    }

    @ViewBuilder
    private var symbols: some View {
        switch model.symbolIndex {
        case _ where !model.projectSymbolsLoaded && !opensAtFile:
            // The project's other files are being indexed, and the place to come back to may be
            // in one of them. (A file just opened starts at its own entry: it shows right away,
            // and the other files fill in after it.)
            placeholder { ProgressView() }
        case .indexing:
            placeholder { ProgressView() }
        case .ready(let symbols) where symbols.isEmpty:
            placeholder {
                ContentUnavailableView(
                    "No Symbols",
                    systemImage: "function",
                    description: Text("No definitions were found in this file or the project’s downloaded files.")
                )
            }
        case .ready where model.activeAlbum != nil && model.albumSymbols.isEmpty:
            placeholder {
                ContentUnavailableView(
                    model.activeAlbum?.name ?? "",
                    systemImage: "rectangle.stack",
                    description: Text("Nothing in this album yet. To add a symbol or a file, touch and hold it, then choose Add to Album; on a page, select lines.")
                )
            }
        case .ready:
            SymbolsView(
                symbols: model.listSymbols,
                query: "",
                isActive: mode.showsSymbols,
                ownText: ownText,
                scrollRequest: listScrollRequest,
                collapseRequest: collapseRequest,
                initialID: { savedListSymbolID() },
                onCenteredSymbolChange: { saveListPosition($0) },
                isBarCollapsed: { model.isBarCollapsed },
                barTapCount: model.barTapCount,
                openFile: model.url,
                collapseScope: model.collapseScope,
                rootFolderName: model.symbolsProjectTitle ?? model.fileName,
                onOpen: { openPager(at: $0, anchor: nil) },
                onOpenAt: { openPager(at: $0, anchor: $1) },
                onBarCollapsedChange: { model.setBarCollapsed($0) },
                albumContext: albumContext,
                onShowHistory: { url, symbol in
                    historyDetent = .large
                    historyFile = HistoryFile(url: url, symbol: symbol)
                },
                onDownloadFile: { model.download(file: $0) },
                downloadingFiles: model.downloadingFiles,
                // The whole list's folders, built with it (an album's are grouped by the list).
                folders: model.activeAlbum == nil ? model.folderGroups : nil,
                onNeedsSymbols: { model.needsSymbols(of: $0) },
                onOpenURL: { onOpen($0) },
                // Each album folds on its own (the whole project's are the shared ones).
                collapsed: CollapsedCodeStore.forAlbum(model.activeAlbum?.id),
                onShowCommit: { showBlameCommit(projectID: $0, id: $1) },
                showsWholeFiles: true,
                textActions: codeTextActions(from: nil),
                // New lists (the project's symbols being read) wait until it stops.
                onScrollingChange: { model.setListScrolling($0) }
            )
            // The bar collapsing redraws this screen, not the list.
            .equatable()
            // A diff album that can't show its cards yet says why, over the empty list.
            .overlay { diffAlbumNote }
            // A fresh list for each album, and once the project's files are in, when the open file
            // showed alone before them (the list finds its symbol by name). Searches go on results pages: this list is never filtered.
            .id([model.activeAlbum?.id.uuidString ?? "", model.projectSymbolsLoaded ? "project" : "file"])
        case .unsupportedLanguage:
            placeholder {
                ContentUnavailableView(
                    "No Symbols for This File Type",
                    systemImage: "doc.questionmark",
                    description: Text("Symbols are available for C, C# and Swift files for now.")
                )
            }
        }
    }

    /// The whole screen, as the zoom's source for a page opened at the lines tapped: zooming
    /// from a frame the size of the page looks like a quick fade.
    private static let screenSourceID = AnyHashable("codeScreen")

    private func openPager(at symbol: CodeSymbol, anchor: PageAnchor?) {
        if let diff = symbol.diff { return openDiffPage(at: symbol, diff, anchor: anchor) }
        let id = UUID()
        // Where its code was tapped, the page opens at those lines and fades in over them
        // (zooming from the whole screen) instead of zooming from the middle.
        stackedCards = [id: StackedCard(symbols: model.listSymbols,
                                        initialID: symbol.id, anchor: anchor,
                                        zoomSource: anchor == nil ? AnyHashable(symbol.id) : Self.screenSourceID,
                                        depth: 1)]
        closeSearches()
        cardPlaces.current = [:]
        cardPath = [.card(id)]
    }

    /// A diff album's card: its file's whole diff, full screen, at the hunk (at the line tapped,
    /// where it was on screen), paging through the album's other files.
    private func openDiffPage(at symbol: CodeSymbol, _ diff: DiffPart, anchor: PageAnchor?) {
        let files = model.listSymbols.filter { $0.kind == .file && $0.diff != nil }
        guard let entry = files.first(where: { $0.diff?.path == diff.path }) else { return }
        let line = symbol.kind == .hunk ? diff.wholeDiffLine(of: anchor?.line ?? diff.firstChange) : 0
        let id = UUID()
        stackedCards = [id: StackedCard(symbols: files, initialID: entry.id,
                                        anchor: PageAnchor(line: line, screenY: anchor?.screenY ?? 160),
                                        zoomSource: anchor == nil ? AnyHashable(symbol.id) : Self.screenSourceID,
                                        depth: 1)]
        closeSearches()
        cardPlaces.current = [:]
        cardPath = [.card(id)]
    }

    /// A diff album that can't show its cards (yet): comparing, a side isn't downloaded (Pull
    /// it), its history is too short, or no changes.
    @ViewBuilder
    private var diffAlbumNote: some View {
        if let state = model.diffAlbumState {
            Group {
                switch state {
                case .loading:
                    ProgressView("Comparing…")
                case .notDownloaded(let side):
                    ContentUnavailableView {
                        Label("“\(side)” Isn’t Downloaded", systemImage: "icloud.and.arrow.down")
                    } description: {
                        Text("This album compares it as the clone has it. Pull downloads its latest commit (nothing is checked out).")
                    } actions: {
                        Button("Pull \(side)") { Task { await runDiffAlbumAction { try await model.pullDiffAlbumSide(side) } } }
                            .buttonStyle(.borderedProminent)
                    }
                case .historyTooShort:
                    ContentUnavailableView {
                        Label("Where They Split Isn’t Downloaded", systemImage: "clock.arrow.circlepath")
                    } description: {
                        Text("The clone’s history doesn’t go back far enough to compare them.")
                    } actions: {
                        Button("Load More History") {
                            Task { await runDiffAlbumAction { try await model.loadMoreDiffAlbumHistory() } }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                case .failed(let message):
                    ContentUnavailableView("Couldn’t Show the Changes", systemImage: "exclamationmark.triangle",
                                           description: Text(message))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(uiColor: .systemGroupedBackground))
        } else if model.activeAlbum?.diff != nil, model.listSymbols.isEmpty {
            ContentUnavailableView("No Changes", systemImage: "checkmark",
                                   description: Text("The two sides have the same files now."))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(uiColor: .systemGroupedBackground))
        }
    }

    /// Pull or Load More History for the diff album, its error shown if it fails.
    private func runDiffAlbumAction(_ action: @escaping @MainActor () async throws -> Void) async {
        do {
            try await action()
        } catch {
            if !Task.isCancelled { diffAlbumError = error.localizedDescription }
        }
    }

    /// A card in the stack: the one opened from the list, or one opened from search results.
    private func cardView(_ card: StackedCard, id: UUID, route: CardRoute) -> some View {
        let places = cardPlaces
        return SymbolPager(
            symbols: card.symbols,
            initialID: card.initialID,
            initialAnchor: card.anchor,
            currentID: Binding(get: { places.current[id] }, set: { places.current[id] = $0 }),
            text: model.text(of:),
            // The list behind stays where it was, whatever you page to: following the card
            // (to land on the symbol you were reading) took you somewhere unexpected at times.
            onPage: { _ in },
            onWillClose: { _ in },
            openFile: model.url,
            onRefresh: { await model.refresh(file: $0) },
            symbolSearchTerm: { symbolSearchTerm(forSelection: $0) },
            onSearchSymbols: { searchInStack(for: $0, from: route) },
            onFindOccurrences: { findOccurrences(of: $0, from: route) },
            onOpenWholeFile: { openWholeFile(from: $0) },
            pageAnchors: card.pageAnchors,
            // The page shows the symbol's own text, which starts where the symbol does.
            onComment: { symbol, range in
                // A diff page's text is the diff: the comment is on its lines.
                if symbol.diff != nil {
                    comment(onDiff: model.diffSelection(for: symbol, range: range))
                    return
                }
                comment(on: NSRange(location: symbol.range.location + range.location, length: range.length),
                        inFile: symbol.fileURL)
            },
            firstLine: { model.firstLine(of: $0) },
            albumMenu: albumMenuAction,
            stackDepth: card.depth,
            stackActions: stackActions
        )
        // A results page stacked on it zooms out of it.
        .matchedTransitionSource(id: AnyHashable(route), in: pagerNamespace)
        .navigationTransition(.zoom(sourceID: card.zoomSource, in: pagerNamespace))
    }

    /// A results page, stacked over the card it was searched from: the latest search's results,
    /// or an older page coming back (it searches again).
    /// A search's results page: like Occurrences', each one keeps its own search and results,
    /// so coming back to it is instant.
    private func resultsView(_ search: StackSearch, route: CardRoute) -> some View {
        let openFile = model.url
        let scope = model.collapseScope
        return StackResultsView(search: search, stackDepth: cardPath.firstIndex(of: route).map { $0 + 1 } ?? 1,
                                stackActions: stackActions,
                                shownCount: { results in
                                    results.filter { !search.collapsed.isHidden($0, openFile: openFile, scope: scope) }.count
                                }) { symbols, query, bar in
            resultsList(search, symbols: symbols, query: query, bar: bar)
        }
        // Its cards zoom out of it; it zooms out of (and back into) its card.
        .matchedTransitionSource(id: AnyHashable(route), in: pagerNamespace)
        .navigationTransition(.zoom(sourceID: search.source, in: pagerNamespace))
    }

    /// Every search page is gone (a new stack starts).
    private func closeSearches() {
        for search in stackedSearches.values { search.cancel() }
        stackedSearches = [:]
    }

    /// A search's results as code blocks, like the Code level's: tap one for its card.
    private func resultsList(_ search: StackSearch, symbols: [CodeSymbol], query: String,
                             bar: ResultsBar) -> some View {
        SymbolsView(
            symbols: symbols,
            query: query,
            isActive: true,
            ownText: ownText,
            scrollRequest: nil,
            collapseRequest: nil,
            onCenteredSymbolChange: { _ in },
            // Whether the capsule is hidden now: without it, the list thought it never was, so
            // scrolling up never brought it back.
            isBarCollapsed: bar.isHidden,
            barTapCount: 0,
            openFile: model.url,
            collapseScope: model.collapseScope,
            rootFolderName: model.symbolsProjectTitle ?? model.fileName,
            onOpen: { openStackedCard(at: $0, anchor: nil, from: search) },
            onOpenAt: { openStackedCard(at: $0, anchor: $1, from: search) },
            onBarCollapsedChange: bar.setHidden,
            albumContext: albumContext,
            onShowHistory: { url, symbol in
                historyDetent = .large
                historyFile = HistoryFile(url: url, symbol: symbol)
            },
            onDownloadFile: { model.download(file: $0) },
            downloadingFiles: model.downloadingFiles,
            onNeedsSymbols: { model.needsSymbols(of: $0) },
            onOpenURL: { onOpen($0) },
            collapsed: search.collapsed,
            onShowCommit: { showBlameCommit(projectID: $0, id: $1) },
            textActions: codeTextActions(from: .results(search.id))
        )
        .equatable()
    }

    // MARK: The stack's symbols

    /// Each card's symbol as it is now, bottom card first, with the card to go back to (the
    /// topmost one showing it, when two cards show the same symbol).
    private func stackedSymbols() -> [(symbol: CodeSymbol, card: CardRoute)] {
        var result: [(symbol: CodeSymbol, card: CardRoute)] = []
        var places: [Int: Int] = [:]
        for route in cardPath {
            guard case .card(let id) = route, let card = stackedCards[id] else { continue }
            let current = cardPlaces.current[id] ?? card.initialID
            guard let symbol = card.symbols.first(where: { $0.id == current }) else { continue }
            if let place = places[symbol.id] {
                result[place].card = route
            } else {
                places[symbol.id] = result.count
                result.append((symbol, route))
            }
        }
        return result
    }

    /// A page's stack icon: tap for the stack's symbols, touch and hold to add them to an album.
    private var stackActions: StackActions {
        let openFile = model.url
        return StackActions(
            show: { isShowingStack = true },
            albumItems: { stackedSymbols().map { AlbumItem($0.symbol, openFile: openFile) } },
            albumContext: albumContext
        )
    }

    /// A symbol's hold menu (`SymbolsView.textActions`): its Search and Occurrences pages go on
    /// top of the page it's on (`nil`: the Code level, the first page).
    private func codeTextActions(from page: CardRoute?) -> CodeTextActions {
        CodeTextActions(onSearch: { searchInStack(for: $0, from: page) },
                        onFindOccurrences: { findOccurrences(of: $0, from: page) },
                        onComment: { range, file, text in comment(on: range, inFile: file, text: text) },
                        onCommentOnFile: { comment(onPathOf: $0, folder: nil) },
                        onCommentOnFolder: { path in
                            // Folders are named from where the project's files start.
                            if let scope = URL(string: model.collapseScope) { comment(onPathOf: scope, folder: path) }
                        },
                        onCommentOnDiff: { comment(onDiff: model.diffSelection(forHunk: $0)) })
    }

    /// The stack's symbols, as code blocks: tap one to go back to its card.
    private var stackSheet: some View {
        let entries = stackedSymbols()
        let cards = Dictionary(entries.map { ($0.symbol.id, $0.card) }, uniquingKeysWith: { $1 })
        let jump: @MainActor (CodeSymbol) -> Void = { symbol in
            stackJump = cards[symbol.id]
            isShowingStack = false
        }
        return StackSheet(actions: stackActions) {
            SymbolsView(
                symbols: entries.map(\.symbol),
                query: "",
                isActive: true,
                ownText: ownText,
                scrollRequest: nil,
                collapseRequest: nil,
                onCenteredSymbolChange: { _ in },
                isBarCollapsed: { false },
                barTapCount: 0,
                openFile: model.url,
                collapseScope: model.collapseScope,
                rootFolderName: model.symbolsProjectTitle ?? model.fileName,
                onOpen: jump,
                onOpenAt: { symbol, _ in jump(symbol) },
                onBarCollapsedChange: { _ in },
                downloadingFiles: model.downloadingFiles,
                onNeedsSymbols: { model.needsSymbols(of: $0) },
                collapsed: stackSheetFolds
            )
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    /// A commit tapped in the blame: looked up in the clone, then shown.
    private func showBlameCommit(projectID: String, id: String) {
        Task {
            guard let commit = try? await CloneStore.shared.commit(projectID: projectID, id: id) else { return }
            blameCommit = BlameCommit(projectID: projectID, commit: commit)
        }
    }

    /// Back to a card of the stack: everything above it closes.
    private func goBack(to card: CardRoute) {
        guard let index = cardPath.firstIndex(of: card), index < cardPath.count - 1 else { return }
        cardPath = Array(cardPath.prefix(through: index))
    }

    /// The bar's search (over Project): a results page, the first in the stack, zooming out of
    /// the screen, its field focused with what was typed. Swipe down goes back to the code.
    private func searchFromBar(_ query: String) {
        let search = StackSearch(query: query, source: Self.screenSourceID, startsEditing: true, model: model)
        stackedCards = [:]
        closeSearches()
        stackedSearches = [search.id: search]
        // Straight in, not zoomed out of the screen: the page's field, on the keyboard, would
        // zoom with it and jump into place after (the keyboard stays up: the bar's field hands
        // it over).
        KeyboardHandOff.hold()
        var instant = Transaction()
        instant.disablesAnimations = true
        withTransaction(instant) { cardPath = [.results(search.id)] }
        // Under it, the Code level it was searched from (not Project, whose field it was typed
        // in): closing it goes back to the code, as Occurrences' page does.
        mode = .code
    }

    /// The start of an https:// (or http://) address, or one.
    private static func mayBeAddress(_ text: String) -> Bool {
        let lower = text.lowercased()
        return ["https://", "http://"].contains { $0.hasPrefix(lower) || lower.hasPrefix($0) }
    }

    /// Open Whole File (a symbol's details): its file's card on top of the stack (the first, from
    /// the Code level), opened at the symbol.
    private func openWholeFile(from symbol: CodeSymbol) {
        let file = symbol.fileURL ?? model.url
        guard let entry = indexedSymbols.first(where: { $0.kind == .file && ($0.fileURL ?? model.url) == file })
        else { return }
        pruneStack()
        let id = UUID()
        stackedCards[id] = StackedCard(symbols: [entry], initialID: entry.id,
                                       anchor: PageAnchor(line: max(0, symbol.line - 1), screenY: 160),
                                       zoomSource: cardPath.last.map { AnyHashable($0) } ?? Self.screenSourceID,
                                       depth: cardPath.count + 1)
        cardPath.append(.card(id))
    }

    /// Search on a card: its results go on top of it. Older results pages stay where they are,
    /// keeping only their query.
    /// - Parameter card: `nil`: from the Code level (a symbol's hold menu), the first page.
    private func searchInStack(for query: String, from card: CardRoute?) {
        pruneStack()
        let source = card.map { AnyHashable($0) } ?? Self.screenSourceID
        let search = StackSearch(query: query, source: source, model: model)
        stackedSearches[search.id] = search
        cardPath.append(.results(search.id))
    }

    /// Cards and results pages that have closed since are gone for good. (Not as they close:
    /// they're still on screen while they zoom away.)
    private func pruneStack() {
        stackedCards = stackedCards.filter { cardPath.contains(.card($0.key)) }
        for (id, search) in stackedSearches where !cardPath.contains(.results(id)) {
            search.cancel()
            stackedSearches[id] = nil
        }
        for (id, search) in stackedOccurrences where !cardPath.contains(.occurrences(id)) {
            search.cancel()
            stackedOccurrences[id] = nil
        }
    }

    // MARK: Occurrences

    /// Occurrences on a card: where the selection is used, as a whole word, in the project's
    /// downloaded files that pass its filter, on a page over the card. The pages highlight it.
    /// - Parameter card: `nil`: from the Code level (a symbol's hold menu), the first page.
    private func findOccurrences(of query: OccurrenceTerm, from card: CardRoute?) {
        pruneStack()
        var files: [OccurrenceFile] = []
        var skipped = 0
        let symbols = indexedSymbols
        var start = 0
        while start < symbols.count {
            var end = start + 1
            while end < symbols.count, symbols[end].kind != .file { end += 1 }
            let entry = symbols[start]
            if entry.kind == .file {
                if entry.isDownloaded {
                    files.append(OccurrenceFile(url: entry.fileURL ?? model.url, fileURL: entry.fileURL,
                                                entry: entry, symbols: Array(symbols[start..<end])))
                } else {
                    skipped += 1
                }
            }
            start = end
        }
        let search = OccurrenceSearch(query: query, source: card.map { AnyHashable($0) } ?? Self.screenSourceID,
                                      files: files, skippedFiles: skipped)
        stackedOccurrences[search.id] = search
        // The pages highlight it: of its kind, with Same Kind; any identifier of the name otherwise.
        let term = query.text
        if let identifier = query.identifier {
            highlights?.current = identifier
        } else if term.unicodeScalars.allSatisfy({ $0.value > 127 || Occurrences.isWordCharacter(unichar($0.value)) }) {
            highlights?.current = IdentifierHighlight(name: term, kind: nil, language: nil)
        }
        cardPath.append(.occurrences(search.id))
    }

    private func occurrencesView(_ search: OccurrenceSearch, route: CardRoute) -> some View {
        // The same page as a search's: the word in the capsule, edited there to look again.
        StackResultsView(search: search, stackDepth: cardPath.firstIndex(of: route).map { $0 + 1 } ?? 1,
                         stackActions: stackActions, shownCount: { _ in search.count }) { entries, query, bar in
            SymbolsView(
                symbols: entries,
                query: query,
                isActive: true,
                ownText: ownText,
                scrollRequest: nil,
                collapseRequest: nil,
                onCenteredSymbolChange: { _ in },
                isBarCollapsed: bar.isHidden,
                barTapCount: 0,
                openFile: model.url,
                collapseScope: model.collapseScope,
                rootFolderName: model.symbolsProjectTitle ?? model.fileName,
                onOpen: { openOccurrence($0, anchor: nil, in: search, route: route) },
                onOpenAt: { openOccurrence($0, anchor: $1, in: search, route: route) },
                onBarCollapsedChange: bar.setHidden,
                albumContext: albumContext,
                onShowHistory: { url, symbol in
                    historyDetent = .large
                    historyFile = HistoryFile(url: url, symbol: symbol)
                },
                downloadingFiles: model.downloadingFiles,
                onNeedsSymbols: { model.needsSymbols(of: $0) },
                collapsed: search.collapsed,
                textActions: codeTextActions(from: route)
            )
            .equatable()
            .environment(\.codeMark, query)  // what it found, marked
        }
        // Its cards zoom out of it; it zooms out of (and back into) its card.
        .matchedTransitionSource(id: AnyHashable(route), in: pagerNamespace)
        .navigationTransition(.zoom(sourceID: search.source, in: pagerNamespace))
    }

    /// An occurrence's card: the symbol it's in (or the lines around it), at its line, paging
    /// through the other occurrences, each at its own line. A file's title opens the file.
    private func openOccurrence(_ symbol: CodeSymbol, anchor: PageAnchor?, in search: OccurrenceSearch,
                                route: CardRoute) {
        pruneStack()
        let id = UUID()
        let depth = cardPath.count + 1
        guard let place = search.places[symbol.id] else {
            guard symbol.kind == .file else { return }
            stackedCards[id] = StackedCard(symbols: [symbol], initialID: symbol.id, anchor: nil,
                                           zoomSource: AnyHashable(route), depth: depth)
            cardPath.append(.card(id))
            return
        }
        // Tapped on its code: that line stays where it was on screen. Otherwise, a little way
        // down, like each of the other pages.
        let screenY: CGFloat = 220
        let first = anchor.map { PageAnchor(line: place.line + $0.line, screenY: $0.screenY) }
            ?? PageAnchor(line: place.line, screenY: screenY)
        let others = search.pageLines.mapValues { PageAnchor(line: $0, screenY: screenY) }
        stackedCards[id] = StackedCard(symbols: search.pages, initialID: place.page, anchor: first,
                                       zoomSource: AnyHashable(route), depth: depth, pageAnchors: others)
        cardPath.append(.card(id))
    }

    /// A result's card, on top of the results, paging through them.
    private func openStackedCard(at symbol: CodeSymbol, anchor: PageAnchor?, from search: StackSearch) {
        pruneStack()
        let id = UUID()
        // `SomeFile.c:980`: a file's title opens it at the line.
        let anchor = symbol.kind == .file
            ? search.lineQuery.map { PageAnchor(line: $0.line - 1, screenY: 160) } ?? anchor
            : anchor
        stackedCards[id] = StackedCard(symbols: search.results, initialID: symbol.id, anchor: anchor,
                                       zoomSource: AnyHashable(CardRoute.results(search.id)),
                                       depth: cardPath.count + 1)
        cardPath.append(.card(id))
    }

    /// The open file's text, for its symbols' code at the Code level (the same object until
    /// it's refreshed).
    private var ownText: NSString? {
        guard case .loaded = model.phase else { return nil }
        return model.plainText
    }

    private var indexedSymbols: [CodeSymbol] {
        if case .ready(let symbols) = model.symbolIndex { symbols } else { [] }
    }

    /// For Add to Album in the menus: the open file's project, and the album shown.
    private var albumContext: AlbumMenuContext? {
        model.symbolsProjectID.map { AlbumMenuContext(projectID: $0, shownAlbumID: model.activeAlbum?.id) }
    }

    /// Add to Album in a page's text menu: the selected lines of the symbol's file.
    private var albumMenuAction: (@MainActor (CodeSymbol, NSRange) -> UIMenu?)? {
        guard let projectID = model.symbolsProjectID else { return nil }
        let naming = albumNaming
        return { symbol, range in
            guard let full = model.fullText(of: symbol.fileURL) else { return nil }
            let text = full.string as NSString
            let inFile = NSRange(location: symbol.range.location + range.location, length: range.length)
            guard inFile.length > 0, NSMaxRange(inFile) <= text.length else { return nil }
            let lines = ReviewText.lines(of: inFile, in: text)
            let item = AlbumItem.lines(AlbumLines(file: symbol.fileURL ?? model.url, start: lines.start, end: lines.end))
            return AlbumTextMenu.menu(for: item, projectID: projectID, naming: naming)
        }
    }


    /// Where the list starts: the file's own entry when it was just opened, otherwise where it
    /// was left last time this file was open.
    private func savedListSymbolID() -> Int? {
        if startsAtFile {
            // Until the project's files are in: the list starts again with them (see `.id`).
            if model.projectSymbolsLoaded { startsAtFile = false }
            return ownEntryID
        }
        // Each album keeps its own place, like a Safari tab.
        if let album = model.activeAlbum {
            return ReadingPositionStore.standard.symbolsPosition(forAlbum: album.id)?.symbolID(in: model.listSymbols)
        }
        return ReadingPositionStore.standard.symbolsPosition(for: model.url)?.symbolID(in: model.listSymbols)
    }

    /// Saves the card in the middle of the Symbols list, like File saves its place. It changes
    /// only when another card reaches the middle (a few times a second at most), and the save is
    /// a few bytes. (Searches go on results pages, so this list is always the whole one.)
    private func saveListPosition(_ symbol: CodeSymbol) {
        if let album = model.activeAlbum {
            ReadingPositionStore.standard.saveSymbolsPosition(SymbolsPosition(symbol), forAlbum: album.id)
        } else {
            ReadingPositionStore.standard.saveSymbolsPosition(SymbolsPosition(symbol), for: model.url)
        }
    }

    /// Full-screen, opaque, so the hidden file text never shows through.
    private func placeholder<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(uiColor: .systemGroupedBackground))
    }

    /// The address editor while editing, otherwise the bar. At the
    /// symbol levels, tapping the bar opens a search (a results page) instead of editing the
    /// address.
    @ViewBuilder
    private var bottom: some View {
        if isEditingAddress {
            AddressEditor(
                initialText: rejectedAddress ?? barAddress,
                showsInitialError: rejectedAddress != nil,
                onOpen: onOpen,
                onCancel: { isEditingAddress = false }
            )
            .id(rejectedAddress)  // a new rejected share restarts the editor with it
        } else if mode == .project {
            // Like Safari's address field over its start page: Project shows until you type, then
            // the symbols found. Return opens an https:// address; Cancel or a swipe down goes back.
            SymbolSearchEditor(query: $browseQuery,
                               placeholder: String(localized: "Search or Enter Address"),
                               onClose: { mode = .code }, onSubmit: submitBrowse, onCancel: { mode = .code })
        } else {
            BottomBarStack(
                title: barTitle,
                isCollapsed: model.isBarCollapsed,
                progressFraction: model.progressFraction,
                isProgressVisible: model.isProgressVisible,
                onExpand: { model.expandBarFromTap() },
                onEdit: { mode = .project },
                copyText: barAddress,
                onPasteAndGo: onPasteAndGo,
                onOpenInBrowser: openInBrowserAction,
                searchQuery: "",  // tapping it searches
                onCollapseAll: collapseAllAction(true),
                onExpandAll: collapseAllAction(false),
                onDeleteAlbum: deleteAlbumAction,
                // In an album: its icon before its name.
                titleIcon: model.activeAlbum != nil ? "rectangle.stack" : nil,
                swipe: albumSwipe
            )
        }
    }

    /// The bar's Delete Album: an album shown (the whole project can't be deleted).
    private var deleteAlbumAction: (@MainActor () -> Void)? {
        guard let album = model.activeAlbum else { return nil }
        return { albumToDelete = album }
    }

    /// Deletes the album shown, going to the one before it (the whole project, from the first),
    /// like closing a Safari tab.
    private func delete(_ album: Album) {
        let albums = AlbumStore.shared.albums(inProject: album.projectID)
        if let index = albums.firstIndex(where: { $0.id == album.id }), index > 0 {
            onOpenAlbum(albums[index - 1].id)
        } else {
            onShowProject()
        }
        AlbumStore.shared.delete(album.id)
    }

    /// Swiping the bar sideways, like Safari's tabs: through the project's albums, the whole
    /// project first. Past the last, a new empty album.
    private var albumSwipe: BarSwipe? {
        guard let projectID = model.symbolsProjectID else { return nil }
        let albums = AlbumStore.shared.albums(inProject: projectID)
        // 0: the whole project; then each album, as Project lists them.
        let index = model.activeAlbum.flatMap { album in albums.firstIndex { $0.id == album.id } }.map { $0 + 1 } ?? 0
        let whole = BarSwipe.Neighbour(title: model.symbolsProjectTitle ?? model.fileName, icon: nil)
        let neighbour = { (place: Int) -> BarSwipe.Neighbour in
            place == 0 ? whole : BarSwipe.Neighbour(title: albums[place - 1].name, icon: "rectangle.stack")
        }
        let previous: BarSwipe.Neighbour? = index > 0 ? neighbour(index - 1) : nil
        let next = index < albums.count ? neighbour(index + 1)
            : BarSwipe.Neighbour(title: AlbumStore.shared.untitledName(projectID: projectID), icon: "plus")
        let showProject = onShowProject, openAlbum = onOpenAlbum
        return BarSwipe(previous: previous, next: next) { forward in
            let place = forward ? index + 1 : index - 1
            if place <= 0 {
                showProject()
            } else if place <= albums.count {
                openAlbum(albums[place - 1].id)
            } else {
                openAlbum(AlbumStore.shared.createUntitled(projectID: projectID).id)
            }
        }
    }

    /// The album shown, or the open file's project, or (outside projects) the file.
    private var barTitle: String {
        model.activeAlbum?.name ?? model.symbolsProjectTitle ?? model.fileName
    }

    /// Return in the bar's field: an https:// address opens; anything else just puts the
    /// keyboard away, leaving the results.
    private func submitBrowse() {
        if case .url(let url) = AddressParser.parse(browseQuery) {
            onOpen(url)
        } else {
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        }
    }

    private var barAddress: String {
        guard mode == .project, let address = project?.link.webURL?.absoluteString else {
            return model.url.absoluteString
        }
        return address
    }

    /// "This is a web page." at the top of the symbol levels, until dismissed. Like the bottom
    /// bar, it slides away while you scroll down and comes back when the bar expands.
    @ViewBuilder
    private var webPageBanner: some View {
        if model.isWebPage, mode.showsSymbols, !isWebPageBannerDismissed, !isEditingAddress,
           !model.isBarCollapsed {
            WebPageBanner(
                onOpenInBrowser: { openInBrowser() },
                onDismiss: { withAnimation(.smooth(duration: 0.25)) { isWebPageBannerDismissed = true } }
            )
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    /// The bar menu's Open in Browser: only for web pages.
    private var openInBrowserAction: (@MainActor () -> Void)? {
        guard model.isWebPage else { return nil }
        return { openInBrowser() }
    }

    /// Whether tapping the bar searches symbols: at the symbol levels, once the file has loaded.
    /// Otherwise (Project, a failed load) it edits the address, so there's always a way to open
    /// something else.
    private var barSearchesSymbols: Bool {
        guard mode.showsSymbols, case .loaded = model.phase else { return false }
        return true
    }

    /// Search in the text menu: what to search for, for any selection.
    private func symbolSearchTerm(forSelection selection: String) -> String? {
        SymbolSearch.query(fromSelection: selection)
    }

    /// Comment on lines of a diff album's change: the commit, the file, both sides' line numbers
    /// and the change (`ReviewDiffSelection`), at the end of the project's review.
    private func comment(onDiff selection: ReviewDiffSelection?) {
        guard let selection, let projectID = model.symbolsProjectID else { return }
        let format = reviewFormat
        let review = review
        Task {
            let repository = await ProjectStore.shared.project(id: projectID).map { project in
                ReviewRepository(name: project.link.owner + "/" + project.link.repo, ref: project.ref,
                                 commit: CloneIndex.shared.record(forProject: projectID)?.commit)
            }
            review.add(selection, format: format, repository: repository, projectID: projectID, overSheet: false)
        }
    }

    /// Comment on a whole file or folder: its path (as the review names files) at the end of the
    /// review, without its code, and open the review.
    /// - Parameters:
    ///   - url: the file; for a folder, where the project's files start.
    ///   - folder: the folder's path from there ("" for the top), or `nil` for the file.
    private func comment(onPathOf url: URL, folder: String?) {
        let format = reviewFormat
        let review = review
        Task {
            let projects = await ProjectStore.shared.projects()
            var path = ReviewText.location(for: url, projects: projects)
            if let folder {
                if !path.isEmpty, !path.hasSuffix("/") { path += "/" }
                path += folder.isEmpty ? "" : folder + "/"
                if path.isEmpty { path = "/" }  // the repository's top
            }
            let project = ProjectSymbolIndex.project(containing: url, in: projects)
            let commit = project.flatMap { CloneIndex.shared.record(forProject: $0.id)?.commit }
            let repository = project.map { project in
                ReviewRepository(name: project.link.owner + "/" + project.link.repo, ref: project.ref, commit: commit)
            }
            review.add(path: path, format: format, repository: repository, projectID: project?.id ?? "")
        }
    }

    /// Comment on a range of the file: add it to the end of the review and open the review.
    /// - Parameter file: the file the range is in, when it isn't the open file (a symbol's page
    ///   from elsewhere in the project).
    private func comment(on range: NSRange, inFile file: URL?) {
        guard let full = model.fullText(of: file) else { return }
        comment(on: range, inFile: file, text: full.string as NSString)
    }

    /// - Parameter text: the file's.
    private func comment(on range: NSRange, inFile file: URL?, text: NSString) {
        guard range.length > 0, NSMaxRange(range) <= text.length else { return }
        let lines = ReviewText.lines(of: range, in: text)
        let code = text.substring(with: range)
        let url = file ?? model.url
        let format = reviewFormat
        let review = review
        Task {
            let projects = await ProjectStore.shared.projects()
            // A cloned project's file is at a known commit: the comment says which.
            let commit = CloneIndex.shared.location(of: url)?.record.commit
            let selection = ReviewSelection(
                location: ReviewText.location(for: url, projects: projects),
                startLine: lines.start, endLine: lines.end, code: code,
                language: ReviewText.language(for: url), commit: commit
            )
            let project = ProjectSymbolIndex.project(containing: url, in: projects)
            let repository = project.map { project in
                ReviewRepository(name: project.link.owner + "/" + project.link.repo, ref: project.ref, commit: commit)
            }
            // Each project has its review ("" for files outside projects).
            review.add(selection, format: format, repository: repository, projectID: project?.id ?? "")
        }
    }

    /// Opening a file from Project: the Code level, at the file's own entry. The open file just
    /// scrolls there; another file opens (and becomes the open one).
    private func open(_ url: URL) {
        guard url == model.url else { return onOpen(url) }
        withAnimation(.smooth(duration: 0.3)) { mode = .code }
        if let ownEntryID { listScrollRequest = SymbolScrollRequest(ownEntryID) }
    }

    /// The open file's own entry in the list (in path order among the project's files).
    private var ownEntryID: Int? {
        model.listSymbols.first { $0.kind == .file && $0.fileURL == nil }?.id
    }

    /// The bar menu's Collapse All and Expand All, at the Code level once the list shows.
    private func collapseAllAction(_ collapses: Bool) -> (@MainActor () -> Void)? {
        guard barSearchesSymbols, model.symbolIndex.isReady else { return nil }
        return { collapseRequest = CollapseRequest(collapses: collapses) }
    }

    /// Hands the URL to the default browser.
    private func openInBrowser() {
        openURL(model.url)
    }

    private var refreshAlertIsPresented: Binding<Bool> {
        Binding(
            get: { model.refreshError != nil },
            set: { if !$0 { model.refreshError = nil } }
        )
    }
}

/// iOS 18 Safari tints the status bar area with bar material. iOS 26 uses the scroll views'
/// edge effect instead.
private struct StatusBarBackdrop: View {
    var body: some View {
        if #available(iOS 26.0, *) {
            EmptyView()
        } else {
            Color.clear
                .frame(height: 0)
                .background(.bar, ignoresSafeAreaEdges: .top)
        }
    }
}
