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
    @SceneStorage("viewMode") private var mode: ViewMode = .file

    @Namespace private var symbolNamespace
    /// The symbol opened in the pager (drives the navigation push).
    @State private var openedSymbolID: Int?
    /// The symbol on screen in the pager. The zoom back lands on its card.
    @State private var pagerSymbolID: Int?
    /// The card the Symbols list keeps in view.
    @State private var listSymbolID: Int?
    /// The symbols the pager pages through: the list's (search results) when a card was tapped,
    /// all of them after Jump to Definition from File.
    @State private var pagerSymbols: [CodeSymbol] = []
    /// Show in File: where File should scroll to.
    @State private var fileScrollRequest: FileScrollRequest?
    /// Symbol search in Symbols mode. Stays until it's cleared or another file is opened.
    @State private var symbolQuery = ""
    @State private var isSearchingSymbols = false

    init(url: URL, isEditingAddress: Binding<Bool>, rejectedAddress: String? = nil,
         onOpen: @escaping @MainActor (URL) -> Void, onPasteAndGo: @escaping @MainActor () -> Void,
         store: DocumentStore = .shared) {
        _model = State(initialValue: CodeDocumentModel(url: url, store: store))
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
        .onChange(of: mode) {
            model.setBarCollapsed(false)
            isSearchingSymbols = false
        }
        .navigationDestination(item: $openedSymbolID) { openedID in
            SymbolPager(
                symbols: pagerSymbols,
                initialID: openedID,
                currentID: $pagerSymbolID,
                text: model.text(of:),
                // Not on tap: center the card only when heading back, so it zooms back into view.
                onWillClose: { listSymbolID = $0 },
                onShowInFile: { showInFile($0) }
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
            if mode == .project {
                ProjectView(currentURL: model.url) { url in
                    mode = .file  // opening a file shows it
                    onOpen(url)
                }
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
                    findDefinition: { SymbolSearch.definition(named: $0, in: indexedSymbols) },
                    onJumpToDefinition: { jumpToDefinition($0) },
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
                symbols
                    .opacity(mode == .symbols ? 1 : 0)
                    .allowsHitTesting(mode == .symbols)
                    .accessibilityHidden(mode != .symbols)
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
        case .indexing:
            placeholder { ProgressView() }
        case .ready(let symbols) where symbols.isEmpty:
            placeholder {
                ContentUnavailableView(
                    "No Symbols",
                    systemImage: "function",
                    description: Text("No top-level definitions were found in this file.")
                )
            }
        case .ready where shownSymbols.isEmpty:
            placeholder { ContentUnavailableView.search(text: symbolQuery) }
        case .ready:
            SymbolsView(
                symbols: shownSymbols,
                isActive: mode == .symbols,
                namespace: symbolNamespace,
                scrolledID: $listSymbolID,
                isBarCollapsed: model.isBarCollapsed,
                barTapCount: model.barTapCount,
                onOpen: { symbol in
                    pagerSymbols = shownSymbols  // page through the search results only
                    pagerSymbolID = symbol.id
                    openedSymbolID = symbol.id
                },
                onBarCollapsedChange: { model.setBarCollapsed($0) }
            )
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

    /// The symbols matching the search, best first; all of them in file order without one.
    private var shownSymbols: [CodeSymbol] {
        SymbolSearch.matches(symbolQuery, in: indexedSymbols)
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
            SymbolSearchEditor(query: $symbolQuery, onDone: { isSearchingSymbols = false })
        } else if isEditingAddress {
            AddressEditor(
                initialText: rejectedAddress ?? model.url.absoluteString,
                showsInitialError: rejectedAddress != nil,
                onOpen: onOpen,
                onCancel: { isEditingAddress = false }
            )
            .id(rejectedAddress)  // a new rejected share restarts the editor with it
        } else {
            BottomBarStack(
                title: model.fileName,
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
                copyText: model.url.absoluteString,
                onPasteAndGo: onPasteAndGo,
                onOpenInBrowser: openInBrowserAction,
                // Symbols shows the active search in the bar; File shows the file name (and
                // searches when tapped); Project edits the address.
                searchQuery: barSearchesSymbols ? (mode == .symbols ? symbolQuery : "") : nil,
                onClearSearch: { symbolQuery = "" }
            )
        }
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
        case .ready where shownSymbols.isEmpty:
            placeholder {
                if symbolQuery.isEmpty {
                    ContentUnavailableView("No Symbols", systemImage: "function")
                } else {
                    ContentUnavailableView.search(text: symbolQuery)
                }
            }
        case .ready:
            SymbolResultsList(symbols: shownSymbols) { symbol in
                isSearchingSymbols = false
                pagerSymbols = shownSymbols
                pagerSymbolID = symbol.id
                openedSymbolID = symbol.id
            }
        }
    }

    /// File's Jump to Definition: open the symbol's page. Paging goes through every symbol, and
    /// swiping down comes back to File.
    private func jumpToDefinition(_ symbol: CodeSymbol) {
        pagerSymbols = indexedSymbols
        pagerSymbolID = symbol.id
        openedSymbolID = symbol.id
    }

    /// The pager's Show in File: close it, switch to File and put the symbol at the top.
    private func showInFile(_ symbol: CodeSymbol) {
        openedSymbolID = nil
        mode = .file
        fileScrollRequest = FileScrollRequest(characterIndex: symbol.range.location)
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
