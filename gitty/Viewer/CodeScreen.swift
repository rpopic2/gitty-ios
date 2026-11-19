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
    /// The results pages in `cardPath`.
    @State private var stackedResults: [UUID: StackedResults] = [:]
    /// The search of the latest results page shown: the only one that keeps its results.
    @State private var stackSearch: StackSearch?
    /// The symbol on screen in the card opened from the list.
    @State private var pagerSymbolID: Int?
    /// Brings a symbol into view in the Code list (the pager closing on another symbol).
    @State private var listScrollRequest: SymbolScrollRequest?
    /// Collapse All or Expand All, from the bar's menu.
    @State private var collapseRequest: CollapseRequest?
    /// The file whose info and history are showing (Show History in the Code level's menu).
    @State private var historyFile: HistoryFile?
    @State private var historyDetent: PresentationDetent = .large

    private struct HistoryFile: Identifiable {
        let url: URL
        var id: URL { url }
    }
    /// Symbol search. Stays until it's cleared or another file is opened.
    @State private var symbolQuery = ""
    @State private var isSearchingSymbols = false
    /// The list hasn't started yet: when `opensAtFile`, it starts at the file's own entry.
    @State private var startsAtFile: Bool
    /// Project has been shown at least once (it's kept from then on).
    @State private var hasShownProject = false
    /// The project chosen in the sidebar, for the bar in Project mode (`nil` for Files).
    @State private var project: ProjectInfo?
    /// The Project tab's order for that project (the sort button beside the mode selector).
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
            if mode == .project { isSearchingSymbols = false }
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
        .onChange(of: symbolQuery, initial: true) { model.search(symbolQuery) }
        .onChange(of: codeTextStyle) { Task { await model.restyle() } }
        .navigationDestination(for: CardRoute.self) { route in
            switch route {
            case .card(let id):
                if let card = stackedCards[id] { cardView(card, route: route) }
            case .results(let id):
                if let entry = stackedResults[id] { resultsPage(id: id, entry: entry, route: route) }
            }
        }
        .sheet(item: $historyFile) { file in
            // All the way up, for the history: it can be pulled down to half.
            FileInfoView(url: file.url)
                .presentationDetents([.medium, .large], selection: $historyDetent)
                .presentationDragIndicator(.visible)
        }
        .alert("Couldn’t Refresh", isPresented: refreshAlertIsPresented, presenting: model.refreshError) { _ in
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
                ProjectView(projectID: projectID, currentURL: model.url, isActive: mode == .project,
                            sorting: ListSorting(), currentAlbumID: albumID, onOpenAlbum: onOpenAlbum,
                            onShowProject: onShowProject) { url in
                    open(url)
                }
                .equatable()  // hidden, its big list mustn't redraw each time this screen does
                .opacity(mode == .project ? 1 : 0)
                .allowsHitTesting(mode == .project)
                .accessibilityHidden(mode != .project)
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
        case .ready where shownSymbols.isEmpty && isSearchPending:
            placeholder { ProgressView() }  // nothing found yet
        case .ready where shownSymbols.isEmpty:
            placeholder { ContentUnavailableView.search(text: symbolQuery) }
        case .ready:
            SymbolsView(
                symbols: shownSymbols,
                query: shownQuery,
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
                onCloseSearch: closeSearchAction,
                albumContext: albumContext,
                onShowHistory: {
                    historyDetent = .large
                    historyFile = HistoryFile(url: $0)
                },
                onDownloadFile: { model.download(file: $0) },
                downloadingFiles: model.downloadingFiles,
                onOpenURL: { onOpen($0) }
            )
            // The bar collapsing redraws this screen, not the list.
            .equatable()
            // A fresh list for each search's results, for the full list after, and for each order
            // (ids are places in the list, so they move; the list finds its symbol by name).
            // (and once the project's files are in, when the open file showed alone before them).
            // While searching, a fresh list for each set of matches too: diffing one set into the
            // next hung the main thread (see `CodeDocumentModel.resultsVersion`).
            .id([shownQuery, model.activeAlbum?.id.uuidString ?? "", model.projectSymbolsLoaded ? "project" : "file",
                 hasSymbolQuery ? String(model.resultsVersion) : ""])
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
        let id = UUID()
        // Where its code was tapped, the page opens at those lines and fades in over them
        // (zooming from the whole screen) instead of zooming from the middle.
        stackedCards = [id: StackedCard(symbols: shownSymbols,  // page through the search results only
                                        initialID: symbol.id, anchor: anchor,
                                        zoomSource: anchor == nil ? AnyHashable(symbol.id) : Self.screenSourceID,
                                        isBase: true, depth: 1)]
        stackedResults = [:]
        stackSearch = nil
        pagerSymbolID = symbol.id
        cardPath = [.card(id)]
    }

    /// A card in the stack: the one opened from the list, or one opened from search results.
    private func cardView(_ card: StackedCard, route: CardRoute) -> some View {
        SymbolPager(
            symbols: card.symbols,
            initialID: card.initialID,
            initialAnchor: card.anchor,
            currentID: card.isBase ? $pagerSymbolID : .constant(nil),
            text: model.text(of:),
            // Once you page, the list (hidden behind) follows, so going back lands on the
            // symbol you were reading.
            onPage: { id in if card.isBase { listScrollRequest = SymbolScrollRequest(id) } },
            // Closing leaves the list where it is: a card tapped near the top or bottom
            // doesn't jump to the middle. (After paging, the list has followed already.)
            onWillClose: { _ in },
            openFile: model.url,
            onRefresh: { await model.refresh(file: $0) },
            symbolSearchTerm: { symbolSearchTerm(forSelection: $0) },
            onSearchSymbols: { searchInStack(for: $0, from: route) },
            // The page shows the symbol's own text, which starts where the symbol does.
            onComment: { symbol, range in
                comment(on: NSRange(location: symbol.range.location + range.location, length: range.length),
                        inFile: symbol.fileURL)
            },
            firstLine: { model.firstLine(of: $0) },
            albumMenu: albumMenuAction,
            stackDepth: card.depth
        )
        // A results page stacked on it zooms out of it.
        .matchedTransitionSource(id: AnyHashable(route), in: pagerNamespace)
        .navigationTransition(.zoom(sourceID: card.zoomSource, in: pagerNamespace))
    }

    /// A results page, stacked over the card it was searched from: the latest search's results,
    /// or an older page coming back (it searches again).
    private func resultsPage(id: UUID, entry: StackedResults, route: CardRoute) -> some View {
        Group {
            if let search = stackSearch, search.id == id {
                resultsView(search)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(uiColor: .systemGroupedBackground))
                    .toolbar(.hidden, for: .navigationBar)
                    .onAppear { reviveSearch(id) }
            }
        }
        // Its cards zoom out of it; it zooms out of (and back into) its card. Outside the `if`, so
        // they stay the same while it searches again.
        .matchedTransitionSource(id: AnyHashable(route), in: pagerNamespace)
        .navigationTransition(.zoom(sourceID: AnyHashable(entry.source), in: pagerNamespace))
    }

    /// An older results page is back on screen: it's the latest one now, searching again.
    private func reviveSearch(_ id: UUID) {
        guard stackSearch?.id != id, let entry = stackedResults[id] else { return }
        keepQuery()
        stackSearch = StackSearch(id: id, query: entry.query, source: entry.source, model: model)
    }

    /// The live search's query, changed on its page, for when that page comes back.
    private func keepQuery() {
        if let search = stackSearch { stackedResults[search.id]?.query = search.query }
    }

    /// The latest search's results.
    private func resultsView(_ search: StackSearch) -> some View {
        StackResultsView(search: search, stackDepth: stackedResults[search.id]?.depth ?? 2) { symbols, query, onScrollDown in
            SymbolsView(
                symbols: symbols,
                query: query,
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
                onOpen: { openStackedCard(at: $0, anchor: nil, from: search) },
                onOpenAt: { openStackedCard(at: $0, anchor: $1, from: search) },
                onBarCollapsedChange: onScrollDown,
                albumContext: albumContext,
                onShowHistory: {
                    historyDetent = .large
                    historyFile = HistoryFile(url: $0)
                },
                onDownloadFile: { model.download(file: $0) },
                downloadingFiles: model.downloadingFiles,
                onOpenURL: { onOpen($0) }
            )
            .equatable()
        }
    }

    /// Search on a card: its results go on top of it. Older results pages stay where they are,
    /// keeping only their query.
    private func searchInStack(for query: String, from card: CardRoute) {
        pruneStack()
        keepQuery()
        let search = StackSearch(query: query, source: card, model: model)
        stackedResults[search.id] = StackedResults(query: query, source: card, depth: cardPath.count + 1)
        stackSearch = search
        cardPath.append(.results(search.id))
    }

    /// Cards and results pages that have closed since are gone for good. (Not as they close:
    /// they're still on screen while they zoom away.)
    private func pruneStack() {
        stackedCards = stackedCards.filter { cardPath.contains(.card($0.key)) }
        stackedResults = stackedResults.filter { cardPath.contains(.results($0.key)) }
    }

    /// A result's card, on top of the results, paging through them.
    private func openStackedCard(at symbol: CodeSymbol, anchor: PageAnchor?, from search: StackSearch) {
        pruneStack()
        let id = UUID()
        stackedCards[id] = StackedCard(symbols: search.results, initialID: symbol.id, anchor: anchor,
                                       zoomSource: AnyHashable(CardRoute.results(search.id)),
                                       isBase: false, depth: cardPath.count + 1)
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
        return ReadingPositionStore.standard.symbolsPosition(for: model.url)?.symbolID(in: model.listSymbols)
    }

    /// Saves the card in the middle of the Symbols list, like File saves its place. It changes
    /// only when another card reaches the middle (a few times a second at most), and the save is
    /// a few bytes. Not while searching: a search reorders the cards, and isn't kept.
    private func saveListPosition(_ id: Int) {
        guard symbolQuery.isEmpty else { return }
        // Ids are places in the full list, so no need to look through it.
        let symbols = indexedSymbols
        guard symbols.indices.contains(id), symbols[id].id == id else { return }
        ReadingPositionStore.standard.saveSymbolsPosition(SymbolsPosition(symbols[id]), for: model.url)
    }

    /// Without a search, every symbol in file order (or the album's). With one: the files whose
    /// name contains it (each with all its symbols), then the symbols it matches, best first.
    /// The symbol search runs in the background (`CodeDocumentModel.search`): these are the
    /// matches so far, which fill in while it runs.
    private var shownSymbols: [CodeSymbol] {
        guard hasSymbolQuery else { return model.listSymbols }
        return model.combinedSearchResults(symbolQuery)
    }

    /// The search `shownSymbols` are for: "" while the full list shows.
    private var shownQuery: String {
        hasSymbolQuery ? model.resultsQuery : ""
    }

    private var hasSymbolQuery: Bool {
        !symbolQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The search hasn't finished going through the symbols (or hasn't started on this query).
    private var isSearchPending: Bool {
        hasSymbolQuery && (model.isSearching || model.resultsQuery != symbolQuery)
    }

    /// Full-screen, opaque, so the hidden file text never shows through.
    private func placeholder<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(uiColor: .systemGroupedBackground))
    }

    /// The address editor or the symbol search while editing, otherwise the bar with the mode
    /// selector. At the symbol levels, tapping the bar searches symbols instead of editing the
    /// address.
    @ViewBuilder
    private var bottom: some View {
        if isSearchingSymbols && barSearchesSymbols {
            SymbolSearchEditor(query: $symbolQuery, isSearching: isSearchPending,
                               placeholder: String(localized: "Search Files and Symbols"),
                               onClose: { isSearchingSymbols = false })
        } else if isEditingAddress {
            AddressEditor(
                initialText: rejectedAddress ?? barAddress,
                showsInitialError: rejectedAddress != nil,
                onOpen: onOpen,
                onCancel: { isEditingAddress = false }
            )
            .id(rejectedAddress)  // a new rejected share restarts the editor with it
        } else {
            BottomBarStack(
                title: barTitle,
                isCollapsed: model.isBarCollapsed,
                progressFraction: model.progressFraction,
                isProgressVisible: model.isProgressVisible,
                mode: $mode,
                onExpand: { model.expandBarFromTap() },
                onEdit: {
                    // The symbol levels search symbols; the address is edited from Project (or
                    // while the file hasn't loaded).
                    if barSearchesSymbols { isSearchingSymbols = true } else { isEditingAddress = true }
                },
                copyText: barAddress,
                onPasteAndGo: onPasteAndGo,
                onOpenInBrowser: openInBrowserAction,
                // The symbol levels show the active search in the bar; Project edits the address.
                searchQuery: barSearchesSymbols ? symbolQuery : nil,
                onClearSearch: { symbolQuery = "" },
                onCollapseAll: collapseAllAction(true),
                onExpandAll: collapseAllAction(false),
                // In an album: its icon before its name (the selector's Project leaves it).
                titleIcon: mode != .project && model.activeAlbum != nil ? "rectangle.stack" : nil
            )
        }
    }

    /// In Project mode, the bar names the project and edits its address on github.com (Files,
    /// which has no address, edits the open file's). Otherwise, the open file.
    private var barTitle: String {
        guard mode == .project else { return model.activeAlbum?.name ?? model.fileName }
        return projectID.isEmpty ? String(localized: "Files") : project?.title ?? ""
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
           !isSearchingSymbols, !model.isBarCollapsed {
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

    /// While searching, a swipe on the list closes the search.
    private var closeSearchAction: (@MainActor () -> Void)? {
        guard isSearchingSymbols else { return nil }
        return { isSearchingSymbols = false }
    }

    /// Search in the text menu: what to search for, for any selection.
    private func symbolSearchTerm(forSelection selection: String) -> String? {
        SymbolSearch.query(fromSelection: selection)
    }

    /// Comment on a range of the file: add it to the end of the review and open the review.
    /// - Parameter file: the file the range is in, when it isn't the open file (a symbol's page
    ///   from elsewhere in the project).
    private func comment(on range: NSRange, inFile file: URL?) {
        guard let full = model.fullText(of: file) else { return }
        let text = full.string as NSString
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
            let repository = ProjectSymbolIndex.project(containing: url, in: projects).map { project in
                ReviewRepository(name: project.link.owner + "/" + project.link.repo, ref: project.ref, commit: commit)
            }
            review.add(selection, format: format, repository: repository)
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
