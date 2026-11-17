import SwiftUI
import UIKit

/// One file, full screen, with a Safari-style bar and the Photos-style mode selector at the bottom.
struct CodeScreen: View {
    @State private var model: CodeDocumentModel
    @SceneStorage("viewMode") private var mode: ViewMode = .file

    @Namespace private var symbolNamespace
    /// The symbol opened in the pager (drives the navigation push).
    @State private var openedSymbolID: Int?
    /// The symbol on screen in the pager. The zoom back lands on its card.
    @State private var pagerSymbolID: Int?
    /// The card the Symbols list keeps in view.
    @State private var listSymbolID: Int?

    init(url: URL, store: DocumentStore = .shared) {
        _model = State(initialValue: CodeDocumentModel(url: url, store: store))
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            content
            BottomBarStack(
                title: model.fileName,
                isCollapsed: model.isBarCollapsed,
                progressFraction: model.progressFraction,
                isProgressVisible: model.isProgressVisible,
                mode: $mode,
                onExpand: { model.expandBarFromTap() }
            )
        }
        .overlay(alignment: .top) { StatusBarBackdrop() }
        .toolbar(.hidden, for: .navigationBar)
        .task { await model.load() }
        .onChange(of: mode) {
            model.setBarCollapsed(false)
        }
        .onChange(of: pagerSymbolID) { _, id in
            // Keep the card of the symbol on screen in view, so swiping down zooms back to it.
            if let id { listSymbolID = id }
        }
        .navigationDestination(item: $openedSymbolID) { _ in
            SymbolPager(symbols: indexedSymbols, currentID: $pagerSymbolID, text: model.text(of:))
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
                    isActive: mode == .file
                )
                .ignoresSafeArea()
                .opacity(mode == .file ? 1 : 0)
                .allowsHitTesting(mode == .file)
                .accessibilityHidden(mode != .file)

                switch mode {
                case .file:
                    EmptyView()
                case .symbols:
                    symbols
                case .project:
                    placeholder {
                        ContentUnavailableView(
                            "Project",
                            systemImage: "folder",
                            description: Text("The project view comes in a later step.")
                        )
                    }
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
        case .ready(let symbols):
            SymbolsView(
                symbols: symbols,
                namespace: symbolNamespace,
                scrolledID: $listSymbolID,
                isBarCollapsed: model.isBarCollapsed,
                barTapCount: model.barTapCount,
                onOpen: { symbol in
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
                    description: Text("Symbols are available for C files for now.")
                )
            }
        }
    }

    private var indexedSymbols: [CodeSymbol] {
        if case .ready(let symbols) = model.symbolIndex { symbols } else { [] }
    }

    /// Full-screen, opaque, so the hidden file text never shows through.
    private func placeholder<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(uiColor: .systemGroupedBackground))
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
