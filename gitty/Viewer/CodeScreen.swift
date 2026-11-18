import SwiftUI
import UIKit

/// One file, full screen, with a Safari-style bar and the Photos-style mode selector at the bottom.
struct CodeScreen: View {
    @State private var model: CodeDocumentModel
    @Environment(\.openURL) private var openURL
    /// The reader closed the "This is a web page." banner for this file.
    @State private var isWebPageBannerDismissed = false
    /// Tapping the bar edits the address; the editor covers the screen while it's open.
    @Binding var isEditingAddress: Bool
    /// A shared link that couldn't be opened: the editor starts with it and says why.
    let rejectedAddress: String?
    let onOpen: @MainActor (URL) -> Void
    let onPasteAndGo: @MainActor () -> Void
    @Binding var mode: ViewMode
    /// The project chosen in the sidebar ("" for Files), shown in Project mode.
    let projectID: String

    @Namespace private var symbolNamespace
    /// The symbol opened in the pager (drives the navigation push).
    @State private var openedSymbolID: Int?
    /// The symbol on screen in the pager. The zoom back lands on its card.
    @State private var pagerSymbolID: Int?
    /// Brings a card into view in the Symbols list (the pager closing on another symbol).
    @State private var listScrollRequest: SymbolScrollRequest?
    /// The symbols the pager pages through: the list's (search results) when a card was tapped,
    /// all of them after Search from File.
    @State private var pagerSymbols: [CodeSymbol] = []
    /// Show in File: where File should scroll to.
    @State private var fileScrollRequest: FileScrollRequest?
    /// Symbol search in Symbols mode. Stays until it's cleared or another file is opened.
    @State private var symbolQuery = ""
    @State private var isSearchingSymbols = false
    /// Symbols has been shown at least once. The list is built then, with the whole project's
    /// symbols, so it can come back to where it was left.
    @State private var hasShownSymbols = false
    /// Project has been shown at least once (it's kept from then on).
    @State private var hasShownProject = false
    /// The project chosen in the sidebar, for the bar in Project mode (`nil` for Files).
    @State private var project: ProjectInfo?
    /// The Project tab's order for that project (the sort button beside the mode selector).
    @State private var projectSorting = ListSorting()
    /// The review that Comment adds to.
    @Environment(ReviewDraft.self) private var review
    @AppStorage("reviewFormat") private var reviewFormat: ReviewFormat = .compact

    init(url: URL, mode: Binding<ViewMode>, projectID: String, isEditingAddress: Binding<Bool>,
         rejectedAddress: String? = nil,
         onOpen: @escaping @MainActor (URL) -> Void, onPasteAndGo: @escaping @MainActor () -> Void,
         store: DocumentStore = .shared) {
        _model = State(initialValue: CodeDocumentModel(url: url, store: store))
        _mode = mode
        self.projectID = projectID
        _isEditingAddress = isEditingAddress
        self.rejectedAddress = rejectedAddress
        self.onOpen = onOpen
        self.onPasteAndGo = onPasteAndGo
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            content
            if isSearchingSymbols && barSearchesSymbols && mode == .file {
                fileSearchResults
            }
            bottom
        }
        .overlay(alignment: .top) { webPageBanner }
        .overlay(alignment: .top) { StatusBarBackdrop() }
        .toolbar(.hidden, for: .navigationBar)
        .task { await model.load() }
        .task(id: projectID) {
            project = projectID.isEmpty ? nil : await ProjectStore.shared.project(id: projectID)
            projectSorting = ListSortingStore.standard.sorting(for: .project, projectID: projectID)
        }
        .onChange(of: mode) {
            model.setBarCollapsed(false)
            isSearchingSymbols = false
        }
        .onChange(of: mode, initial: true) {
            if mode == .symbols { hasShownSymbols = true }
            if mode == .project { hasShownProject = true }
        }
        .onChange(of: needsProjectSymbols, initial: true) {
            if needsProjectSymbols { model.loadProjectSymbols() }
        }
        .onChange(of: symbolQuery, initial: true) { model.search(symbolQuery) }
        .navigationDestination(item: $openedSymbolID) { openedID in
            SymbolPager(
                symbols: pagerSymbols,
                initialID: openedID,
                currentID: $pagerSymbolID,
                text: model.text(of:),
                // Not on tap, which would move the card the zoom starts from. Once you page, the
                // list (hidden behind) follows, so it's already on the card when you swipe down.
                onPage: { listScrollRequest = SymbolScrollRequest($0) },
                onWillClose: { listScrollRequest = SymbolScrollRequest($0) },
                onShowInFile: { showInFile($0) },
                symbolSearchTerm: { symbolSearchTerm(forSelection: $0) },
                onSearchSymbols: { searchSymbols(for: $0) },
                // The page shows the symbol's own text, which starts where the symbol does.
                onComment: { symbol, range in
                    comment(on: NSRange(location: symbol.range.location + range.location, length: range.length),
                            inFile: symbol.fileURL)
                }
            )
            .navigationTransition(.zoom(sourceID: pagerSymbolID ?? -1, in: symbolNamespace))
        }
        .alert("Couldn’t Refresh", isPresented: refreshAlertIsPresented, presenting: model.refreshError) { _ in
            Button("OK", role: .cancel) {}
        } message: { message in
            Text(message)
        }
    }

    @ViewBuilder
    private var content: some View {
        ZStack {
            document
                .accessibilityHidden(mode == .project)
            // Project lists files, so it doesn't depend on this file loading (or failing with a 404).
            // Built on first use, then kept (hidden) like File and Symbols, so switching back is
            // instant: it doesn't read and group the project's files again.
            if hasShownProject {
                ProjectView(projectID: projectID, currentURL: model.url, isActive: mode == .project,
                            sorting: projectSorting) { url in
                    mode = .file  // opening a file shows it
                    onOpen(url)
                }
                .equatable()  // hidden, its big list mustn't redraw each time this screen does
                .opacity(mode == .project ? 1 : 0)
                .allowsHitTesting(mode == .project)
                .accessibilityHidden(mode != .project)
            }
        }
    }

    /// The open file in File and Symbols mode: loading, loaded, or the reason it couldn't load.
    @ViewBuilder
    private var document: some View {
        switch model.phase {
        case .loading:
            // A blank page while the progress line runs, as in Safari.
            Color(uiColor: RawTextStyle.backgroundColor)
                .ignoresSafeArea()
        case .loaded(let text, let version):
            ZStack {
                // Stays alive (hidden) in the other modes, so File keeps its place and returns instantly.
                CodeTextView(
                    text: text,
                    version: version,
                    documentURL: model.url,
                    bottomBarHeight: FileBarMetrics.expandedHeight,
                    isBarCollapsed: model.isBarCollapsed,
                    barTapCount: model.barTapCount,
                    onRefresh: { await model.refresh() },
                    onBarCollapsedChange: { model.setBarCollapsed($0) },
                    isActive: mode == .file,
                    symbolSearchTerm: { symbolSearchTerm(forSelection: $0) },
                    onSearchSymbols: { searchSymbols(for: $0) },
                    onComment: { comment(on: $0, inFile: nil) },
                    scrollRequest: fileScrollRequest
                )
                .ignoresSafeArea()
                .opacity(mode == .file ? 1 : 0)
                .allowsHitTesting(mode == .file)
                .accessibilityHidden(mode != .file)

                // Also kept alive while hidden, so the list keeps its exact scroll position when
                // you come back from File or Project. (Rebuilding it and restoring the position
                // with `scrollPosition(id:)` isn't reliable: SwiftUI often ignores the starting
                // value on a view's first layout.)
                if hasShownSymbols {
                    symbols
                        .opacity(mode == .symbols ? 1 : 0)
                        .allowsHitTesting(mode == .symbols)
                        .accessibilityHidden(mode != .symbols)
                }
            }
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
        case _ where !model.projectSymbolsLoaded:
            // The project's other files are being indexed.
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
        case .ready where shownSymbols.isEmpty && isSearchPending:
            placeholder { ProgressView() }  // nothing found yet
        case .ready where shownSymbols.isEmpty:
            placeholder { ContentUnavailableView.search(text: symbolQuery) }
        case .ready:
            SymbolsView(
                symbols: shownSymbols,
                query: shownQuery,
                isActive: mode == .symbols,
                namespace: symbolNamespace,
                scrollRequest: listScrollRequest,
                initialID: { savedListSymbolID() },
                onCenteredSymbolChange: { saveListPosition($0) },
                isBarCollapsed: model.isBarCollapsed,
                barTapCount: model.barTapCount,
                openFile: model.url,
                onOpen: { symbol in
                    pagerSymbols = shownSymbols  // page through the search results only
                    pagerSymbolID = symbol.id
                    openedSymbolID = symbol.id
                },
                onOpenFile: { openFile($0) },
                onBarCollapsedChange: { model.setBarCollapsed($0) },
                onCloseSearch: closeSearchAction
            )
            // A fresh list for each search's results, for the full list after, and for each order
            // (ids are places in the list, so they move; the list finds its symbol by name).
            .id([shownQuery, model.symbolSorting.order.rawValue, model.symbolSorting.isReversed ? "reversed" : ""])
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

    private var indexedSymbols: [CodeSymbol] {
        if case .ready(let symbols) = model.symbolIndex { symbols } else { [] }
    }

    /// Where the Symbols list was left last time this file was open.
    private func savedListSymbolID() -> Int? {
        ReadingPositionStore.standard.symbolsPosition(for: model.url)?.symbolID(in: indexedSymbols)
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

    /// The symbols matching the search, best first; all of them in file order without one.
    /// The search runs in the background (`CodeDocumentModel.search`): these are the matches so
    /// far, which fill in while it runs.
    private var shownSymbols: [CodeSymbol] {
        hasSymbolQuery ? model.searchResults : indexedSymbols
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
    /// selector. In Symbols mode, tapping the bar searches symbols instead of editing the address.
    @ViewBuilder
    private var bottom: some View {
        if isSearchingSymbols && barSearchesSymbols {
            SymbolSearchEditor(query: $symbolQuery, isSearching: isSearchPending,
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
                    // File and Symbols search symbols; the address is edited from Project (or
                    // anywhere when there's nothing to search).
                    if barSearchesSymbols { isSearchingSymbols = true } else { isEditingAddress = true }
                },
                copyText: barAddress,
                onPasteAndGo: onPasteAndGo,
                onOpenInBrowser: openInBrowserAction,
                // Symbols shows the active search in the bar; File shows the file name (and
                // searches when tapped); Project edits the address.
                searchQuery: barSearchesSymbols ? (mode == .symbols ? symbolQuery : "") : nil,
                onClearSearch: { symbolQuery = "" },
                sorting: barSorting
            )
        }
    }

    /// The sort button beside the mode selector: the project's files in Project mode, and the
    /// project's files in Symbols. None in File mode, for Files (it has its own order), or for a
    /// file outside a project.
    private var barSorting: Binding<ListSorting>? {
        switch mode {
        case .project where !projectID.isEmpty:
            return Binding(get: { projectSorting }, set: { sorting in
                projectSorting = sorting
                ListSortingStore.standard.save(sorting, for: .project, projectID: projectID)
            })
        case .symbols where model.symbolsProjectID != nil:
            return Binding(get: { model.symbolSorting }, set: { model.setSymbolSorting($0) })
        default:
            return nil
        }
    }

    /// In Project mode, the bar names the project and edits its address on github.com (Files,
    /// which has no address, edits the open file's). Otherwise, the open file.
    private var barTitle: String {
        guard mode == .project else { return model.fileName }
        return projectID.isEmpty ? String(localized: "Files") : project?.title ?? ""
    }

    private var barAddress: String {
        guard mode == .project, let address = project?.link.webURL?.absoluteString else {
            return model.url.absoluteString
        }
        return address
    }

    /// "This is a web page." at the top of File mode, until dismissed. Like the bottom bar, it
    /// slides away while you scroll down and comes back when the bar expands.
    @ViewBuilder
    private var webPageBanner: some View {
        if model.isWebPage, mode == .file, !isWebPageBannerDismissed, !isEditingAddress,
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

    /// Whether tapping the bar searches symbols: in File and Symbols mode, once the file has
    /// loaded in a language with symbols. Otherwise (Project, a failed load, a web page or another
    /// language) it edits the address, so there's always a way to open something else.
    private var barSearchesSymbols: Bool {
        guard mode != .project, case .loaded = model.phase else { return false }
        if case .unsupportedLanguage = model.symbolIndex { return false }
        return true
    }

    /// Searching symbols in File mode: the matches above the search field (every symbol until
    /// you type). Tapping one opens its page, paging through the matches; swiping down comes
    /// back to File.
    @ViewBuilder
    private var fileSearchResults: some View {
        switch model.symbolIndex {
        case .indexing:
            placeholder { ProgressView() }
        case .unsupportedLanguage:
            placeholder {
                ContentUnavailableView(
                    "No Symbols for This File Type",
                    systemImage: "doc.questionmark",
                    description: Text("Symbols are available for C, C# and Swift files for now.")
                )
            }
        case .ready where shownSymbols.isEmpty && isSearchPending:
            placeholder { ProgressView() }  // nothing found yet
        case .ready where shownSymbols.isEmpty:
            placeholder {
                if symbolQuery.isEmpty {
                    ContentUnavailableView("No Symbols", systemImage: "function")
                } else {
                    ContentUnavailableView.search(text: symbolQuery)
                }
            }
        case .ready:
            SymbolResultsList(symbols: shownSymbols, onCloseSearch: { isSearchingSymbols = false }) { symbol in
                isSearchingSymbols = false
                pagerSymbols = shownSymbols
                pagerSymbolID = symbol.id
                openedSymbolID = symbol.id
            }
        }
    }

    /// While searching in Symbols mode, a swipe on the cards closes the search.
    private var closeSearchAction: (@MainActor () -> Void)? {
        guard isSearchingSymbols else { return nil }
        return { isSearchingSymbols = false }
    }

    /// Search in the text menu: what to search for, for any selection. `nil` (no menu item) only
    /// when this file has no symbols to search.
    private func symbolSearchTerm(forSelection selection: String) -> String? {
        if case .unsupportedLanguage = model.symbolIndex { return nil }
        return SymbolSearch.query(fromSelection: selection)
    }

    /// Search (from File or a symbol's page): put the selection in the symbol search and
    /// focus it. In File the matches list above the field; from a symbol's page, the page
    /// closes and the Symbols cards filter.
    private func searchSymbols(for name: String) {
        openedSymbolID = nil
        symbolQuery = name
        isSearchingSymbols = true
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
            let selection = ReviewSelection(
                location: ReviewText.location(for: url, projects: projects),
                startLine: lines.start, endLine: lines.end, code: code,
                language: ReviewText.language(for: url)
            )
            review.add(selection, format: format)
        }
    }

    /// A file header's open button in Symbols' grouped view: show that file in File mode, where
    /// it was left.
    private func openFile(_ file: URL) {
        mode = .file
        if file != model.url { onOpen(file) }
    }

    /// The pager's Show in File: close it, switch to File and put the symbol at the top.
    /// A symbol from another file opens that file, at the symbol (as its reading position).
    private func showInFile(_ symbol: CodeSymbol) {
        openedSymbolID = nil
        mode = .file
        if let file = symbol.fileURL, file != model.url {
            ReadingPositionStore.standard.save(ReadingPosition(characterIndex: symbol.range.location, lineOffset: 0),
                                               for: file)
            onOpen(file)
            return
        }
        fileScrollRequest = FileScrollRequest(characterIndex: symbol.range.location)
    }

    /// Symbols and symbol search cover the whole project, so its files are indexed once either
    /// is used.
    private var needsProjectSymbols: Bool {
        mode == .symbols || isSearchingSymbols
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

/// iOS 18 Safari tints the status bar area with bar material. iOS 26 uses the text view's
/// scroll edge effect instead (see `CodeTextView`).
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
