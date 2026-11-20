import SwiftUI
import UIKit

/// One symbol at a time, full screen, like a photo opened in Photos.
/// Swipe left/right for the previous/next symbol. Pinch or swipe down to close it, back to the
/// list at the symbol on screen (the zoom navigation transition provides those gestures).
///
/// A file's own page is the whole file, where File used to be: select text for Comment and
/// Search, pull to refresh it, and it comes back where you left off. Tap the caption for the
/// file's info and history.
struct SymbolPager: View {
    let symbols: [CodeSymbol]
    /// The symbol that was tapped. The pager opens on it.
    let initialID: Int
    /// Where its code was tapped at the Code level: its page opens with that line where it was
    /// on screen (`nil`: at the top, or where a file's page was left).
    let initialAnchor: PageAnchor?
    /// The symbol on screen. Reported only after the pager has opened on `initialID`.
    @Binding var currentID: Int?
    let text: @MainActor (CodeSymbol) -> NSAttributedString?
    /// Called with each symbol paged to, once you've paged away from the tapped one.
    let onPage: @MainActor (Int) -> Void
    /// Called with the symbol on screen when the pager starts to close (the swipe down begins).
    let onWillClose: @MainActor (Int) -> Void
    /// The open file, which entries without a `fileURL` are in (for a file page's place).
    let openFile: URL
    /// Pull to refresh on a file's page: download that file (`nil`: the open file) again.
    let onRefresh: @MainActor (URL?) async -> Void
    /// Search in a page's text menu: search symbols, on a results page stacked over this one.
    let symbolSearchTerm: @MainActor (String) -> String?
    let onSearchSymbols: @MainActor (String) -> Void
    /// Occurrences in a page's text menu: where the selection is used, on a page stacked over
    /// this one.
    let onFindOccurrences: (@MainActor (OccurrenceTerm) -> Void)?
    /// Open Whole File in a page's details: the symbol's file, stacked, at the symbol.
    let onOpenWholeFile: (@MainActor (CodeSymbol) -> Void)?
    /// Where pages other than the first open (a symbol's id: the line, and where it goes on
    /// screen), like `initialAnchor` for the first: an occurrence's line.
    let pageAnchors: [Int: PageAnchor]
    /// Comment in a page's text menu, with the range in the symbol's text.
    let onComment: @MainActor (CodeSymbol, NSRange) -> Void
    /// The line of its file a page's text starts at, for the line-number peek.
    let firstLine: @MainActor (CodeSymbol) -> Int
    /// Add to Album in a page's text menu, for the selected lines (range in the symbol's text).
    let albumMenu: (@MainActor (CodeSymbol, NSRange) -> UIMenu?)?
    /// Where this pager is in the stack (1 at the bottom, results pages counting too): the
    /// caption shows it once there's anything under this one.
    let stackDepth: Int
    /// The stack icon's: the stack's symbols, and adding them to an album.
    let stackActions: StackActions?

    @State private var scrolledID: Int?
    @State private var isPositioned = false
    /// The file whose info panel is open.
    @State private var infoFile: InfoFile?
    /// Scrolling down a page hides the caption; scrolling up shows it.
    @State private var isCaptionHidden = false
    /// Paged away from the tapped symbol at least once.
    @State private var hasPaged = false
    /// The identifier highlighted on every page (Highlight in the text menu).
    @Environment(HighlightState.self) private var highlights: HighlightState?
    /// A review set aside stays docked at the bottom, above the caption.
    @Environment(ReviewDraft.self) private var review: ReviewDraft?
    /// A page takes its text again when the code font changes.
    @Environment(\.codeTextStyle) private var codeTextStyle

    // An explicit init (not the memberwise one) so passing in an existing `@MainActor` closure
    // doesn't warn about converting it to `@Sendable`.
    init(symbols: [CodeSymbol], initialID: Int, initialAnchor: PageAnchor? = nil, currentID: Binding<Int?>,
         text: @escaping @MainActor (CodeSymbol) -> NSAttributedString?,
         onPage: @escaping @MainActor (Int) -> Void,
         onWillClose: @escaping @MainActor (Int) -> Void,
         openFile: URL,
         onRefresh: @escaping @MainActor (URL?) async -> Void,
         symbolSearchTerm: @escaping @MainActor (String) -> String?,
         onSearchSymbols: @escaping @MainActor (String) -> Void,
         onFindOccurrences: (@MainActor (OccurrenceTerm) -> Void)? = nil,
         onOpenWholeFile: (@MainActor (CodeSymbol) -> Void)? = nil,
         pageAnchors: [Int: PageAnchor] = [:],
         onComment: @escaping @MainActor (CodeSymbol, NSRange) -> Void,
         firstLine: @escaping @MainActor (CodeSymbol) -> Int,
         albumMenu: (@MainActor (CodeSymbol, NSRange) -> UIMenu?)? = nil,
         stackDepth: Int = 1, stackActions: StackActions? = nil) {
        self.symbols = symbols
        self.initialID = initialID
        self.initialAnchor = initialAnchor
        _currentID = currentID
        self.text = text
        self.onPage = onPage
        self.onWillClose = onWillClose
        self.openFile = openFile
        self.onRefresh = onRefresh
        self.symbolSearchTerm = symbolSearchTerm
        self.onSearchSymbols = onSearchSymbols
        self.onFindOccurrences = onFindOccurrences
        self.onOpenWholeFile = onOpenWholeFile
        self.pageAnchors = pageAnchors
        self.onComment = onComment
        self.firstLine = firstLine
        self.albumMenu = albumMenu
        self.stackDepth = stackDepth
        self.stackActions = stackActions
    }

    private var visibleID: Int { scrolledID ?? initialID }

    private var current: CodeSymbol? {
        symbols.first { $0.id == visibleID }
    }

    var body: some View {
        // Pages sit inside a scroll view, where UIKit gives them no safe-area insets. Read the
        // screen's safe area here and hand it to each page.
        GeometryReader { proxy in
            let safeArea = proxy.safeAreaInsets
            // The top is kept out of the page instead (see below), so no inset there.
            let pageInsets = EdgeInsets(
                top: 0,
                leading: safeArea.leading,
                bottom: safeArea.bottom + SymbolCaption.reservedHeight
                    + (review?.isDocked == true ? ReviewDock.reservedHeight : 0),
                trailing: safeArea.trailing
            )
            ZStack(alignment: .bottom) {
                ScrollViewReader { reader in
                    ScrollView(.horizontal) {
                        LazyHStack(spacing: 0) {
                            ForEach(symbols) { symbol in
                                // Another file's text may still be loading: the page fills in
                                // once it's there (a different id makes the view take the text).
                                let pageText = text(symbol)
                                let isFilePage = symbol.kind == .file
                                ReadOnlyTextView(
                                    text: pageText ?? NSAttributedString(),
                                    textID: pageID(for: symbol, text: pageText),
                                    insets: pageInsets,
                                    isCurrent: symbol.id == visibleID,
                                    symbolSearchTerm: symbolSearchTerm,
                                    onSearchSymbols: onSearchSymbols,
                                    onFindOccurrences: onFindOccurrences,
                                    onComment: { onComment(symbol, $0) },
                                    albumMenu: pageAlbumMenu(for: symbol),
                                    fileExtension: (symbol.fileURL ?? openFile).pathExtension,
                                    highlight: highlights?.current,
                                    onHighlight: { highlights?.current = $0 },
                                    positionURL: isFilePage ? symbol.fileURL ?? openFile : nil,
                                    onRefresh: refreshAction(for: symbol),
                                    lineNumbering: .counted(firstLine: { firstLine(symbol) }),
                                    onScrollDown: { isCaptionHidden = $0 },
                                    // The page's text view starts below the status bar.
                                    startAnchor: (symbol.id == initialID ? initialAnchor : pageAnchors[symbol.id])
                                        .map { PageAnchor(line: $0.line, screenY: $0.screenY - safeArea.top) }
                                )
                                // The text starts below the status bar and never scrolls under
                                // it: just the page's background shows there.
                                .padding(.top, safeArea.top)
                                .containerRelativeFrame([.horizontal, .vertical])
                            }
                        }
                        .scrollTargetLayout()
                    }
                    .scrollTargetBehavior(.paging)
                    .scrollPosition(id: $scrolledID)
                    .scrollIndicators(.hidden)
                    .background(Color(uiColor: RawTextStyle.backgroundColor))
                    .ignoresSafeArea()
                    .onAppear {
                        // `scrollPosition(id:)` ignores a starting value during the first layout and
                        // opens on the first page. Move to the tapped symbol explicitly.
                        reader.scrollTo(initialID, anchor: .leading)
                        scrolledID = initialID
                        isPositioned = true
                    }
                }

                // The caption, then a set-aside review under it: both hide while you scroll down.
                VStack(spacing: 0) {
                    if let current {
                        SymbolCaption(symbol: current, fileName: (current.fileURL ?? openFile).displayFileName,
                                      stackDepth: stackDepth, stackActions: stackActions,
                                      onInfo: infoAction(for: current))
                            .padding(.bottom, 8)
                    }
                    if let review, review.isDocked {
                        ReviewDock(draft: review)
                            .padding(.bottom, 8)
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }
                }
                .offset(y: isCaptionHidden
                    ? SymbolCaption.reservedHeight + (review?.isDocked == true ? ReviewDock.reservedHeight : 0) + 40
                    : 0)
                .opacity(isCaptionHidden ? 0 : 1)
                .allowsHitTesting(!isCaptionHidden)
                .accessibilityHidden(isCaptionHidden)
                .animation(.smooth(duration: 0.25), value: isCaptionHidden)
                .animation(.smooth(duration: 0.25), value: review?.isDocked)
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .sheet(item: $infoFile) { file in
            FileInfoView(url: file.url, onOpenWholeFile: file.symbol.flatMap { symbol in
                onOpenWholeFile.map { open in { open(symbol) } }
            })
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .background(WillDisappearObserver { onWillClose(visibleID) })
        .onChange(of: scrolledID) { _, id in
            // Until the pager is on the tapped symbol, don't let the first layout overwrite it.
            guard isPositioned, let id else { return }
            currentID = id
            isCaptionHidden = false  // each page starts with it
            if id != initialID { hasPaged = true }
            if hasPaged { onPage(id) }
        }
    }

    /// Tapping a page's caption: the info panel of its file.
    private func infoAction(for symbol: CodeSymbol) -> @MainActor () -> Void {
        let url = symbol.fileURL ?? openFile
        let from = symbol.kind == .file ? nil : symbol
        return { infoFile = InfoFile(url: url, symbol: from) }
    }

    private func pageAlbumMenu(for symbol: CodeSymbol) -> (@MainActor (NSRange) -> UIMenu?)? {
        guard let albumMenu else { return nil }
        return { albumMenu(symbol, $0) }
    }

    /// Pull to refresh, on a file's page only.
    private func refreshAction(for symbol: CodeSymbol) -> (@MainActor () async -> Void)? {
        guard symbol.kind == .file else { return nil }
        let refresh = onRefresh
        let file = symbol.fileURL
        return { await refresh(file) }
    }

    /// When a page takes new text: once another file's text has loaded, and for a file's page
    /// each time the file is refreshed (its text is then a new object).
    private func pageID(for symbol: CodeSymbol, text: NSAttributedString?) -> Int {
        guard let text else { return -1 - symbol.id }
        guard symbol.kind != .file else { return ObjectIdentifier(text).hashValue }  // new object when restyled
        var hasher = Hasher()
        hasher.combine(symbol.id)
        hasher.combine(codeTextStyle)
        return hasher.finalize()
    }
}

/// A page's text view, with the line numbers beside it (hidden until you peek at them).
final class PageTextView: UIView {
    let textView: UITextView
    let gutter = LineNumberGutter()
    /// The line-number peek: a drag in from the left edge.
    weak var peek: UIGestureRecognizer?

    init(textView: UITextView) {
        self.textView = textView
        super.init(frame: .zero)
        clipsToBounds = true
        backgroundColor = RawTextStyle.backgroundColor
        addSubview(textView)
        gutter.isHidden = true
        addSubview(gutter)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// On screen: the scroll views around the page (the pager's paging) wait for the peek, so a
    /// drag in from the left edge doesn't page. Going back (the card's zoom transition, or the
    /// stack's back swipe) runs alongside it, as on a results page: the card slides away with
    /// its line numbers out (see the coordinator's delegate methods).
    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil, let peek else { return }
        var view = superview
        while let current = view {
            if current is UIScrollView {
                for other in current.gestureRecognizers ?? [] where other is UIPanGestureRecognizer && other !== peek {
                    other.require(toFail: peek)
                }
            }
            view = current.superview
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Not while sliding: a frame is only meaningful without a transform.
        if textView.transform == .identity { textView.frame = bounds }
    }
}

/// A file whose info panel is open.
private struct InfoFile: Identifiable {
    let url: URL
    /// The symbol it was opened from (`nil`: a file's own page), for Open Whole File.
    let symbol: CodeSymbol?
    var id: URL { url }
}

/// Reports when the screen it's on starts to go away. For the zoom transition that's the moment
/// the swipe down begins. It's also called if the swipe is then cancelled, which is harmless here.
/// SwiftUI has no hook for this, so it uses a UIKit view controller's `viewWillDisappear`.
private struct WillDisappearObserver: UIViewControllerRepresentable {
    let onWillDisappear: @MainActor () -> Void

    func makeUIViewController(context: Context) -> Controller { Controller() }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.onWillDisappear = onWillDisappear
    }

    final class Controller: UIViewController {
        var onWillDisappear: (@MainActor () -> Void)?

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            onWillDisappear?()
        }
    }
}

/// "name · file" in a small capsule at the bottom, in place of the bar and selector. Tap it
/// for the file's info.
private struct SymbolCaption: View {
    let symbol: CodeSymbol
    /// The symbol's file's name, after its name.
    let fileName: String
    /// The card's place in the stack (`StackDepthLabel`): shown before the symbol from 2 up.
    let stackDepth: Int
    let stackActions: StackActions?
    let onInfo: @MainActor () -> Void

    static let height: CGFloat = 36
    /// Space kept free under the text so its end isn't hidden behind the caption.
    static let reservedHeight: CGFloat = height + 16

    init(symbol: CodeSymbol, fileName: String, stackDepth: Int, stackActions: StackActions?,
         onInfo: @escaping @MainActor () -> Void) {
        self.symbol = symbol
        self.fileName = fileName
        self.stackDepth = stackDepth
        self.stackActions = stackActions
        self.onInfo = onInfo
    }

    var body: some View {
        capsule
            .onTapGesture { onInfo() }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityHint(Text("Shows the file’s info and history"))
    }

    @ViewBuilder
    private var capsule: some View {
        let label = HStack(spacing: 6) {
            if stackDepth > 1 {
                StackDepthLabel(depth: stackDepth, actions: stackActions)
            }
            Image(systemName: symbol.kind.systemImage)
                .foregroundStyle(.tint)
            Text(symbol.name)
                .lineLimit(1)
                .truncationMode(.middle)
            // Its file's name (peek for the line numbers). A file's own page needs nothing more
            // than its name.
            if symbol.kind != .file {
                Text(verbatim: "· " + fileName)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .font(.subheadline)
        .padding(.horizontal, 16)
        .frame(height: Self.height)
        .contentShape(Capsule())

        if #available(iOS 26.0, *) {
            label.glassEffect(.regular.interactive(), in: Capsule())
                .padding(.horizontal, 24)
        } else {
            label.background(.bar, in: Capsule())
                .padding(.horizontal, 24)
        }
    }
}

/// A read-only raw-text view for one symbol: the same Safari style as the file.
struct ReadOnlyTextView: UIViewRepresentable {
    let text: NSAttributedString
    /// Text is replaced only when this changes.
    let textID: Int
    /// Safe area (plus room for the caption at the bottom) to keep the text clear of. The page
    /// itself starts below the status bar, so `top` is normally 0.
    let insets: EdgeInsets
    /// Only the page on screen answers a tap on the status bar.
    let isCurrent: Bool
    /// Search in the text menu: the search for a selection (`nil` hides the item)…
    var symbolSearchTerm: (@MainActor (String) -> String?)? = nil
    /// …and searching symbols for it.
    var onSearchSymbols: (@MainActor (String) -> Void)? = nil
    /// Occurrences in the text menu: where the selection is used in the project.
    var onFindOccurrences: (@MainActor (OccurrenceTerm) -> Void)? = nil
    /// Comment in the text menu: adds a comment on the selected range to the review.
    var onComment: (@MainActor (NSRange) -> Void)? = nil
    /// Add to Album in the text menu, for the selected lines (`nil` hides it).
    var albumMenu: (@MainActor (NSRange) -> UIMenu?)? = nil
    /// Highlight in the text menu: the file's extension, for its tree-sitter grammar…
    var fileExtension = ""
    /// …the identifier highlighted on every page…
    var highlight: IdentifierHighlight? = nil
    /// …and choosing it (`nil`: Remove Highlight). `nil` hides the item.
    var onHighlight: (@MainActor (IdentifierHighlight?) -> Void)? = nil
    /// A file's page: the file whose reading position it keeps (saved when scrolling stops,
    /// restored when the page takes its text).
    var positionURL: URL? = nil
    /// A file's page: pull to refresh.
    var onRefresh: (@MainActor () async -> Void)? = nil
    /// Swiping in from the left edge and holding shows the line numbers, numbered this way.
    var lineNumbering: LineNumbering? = nil
    /// The reader scrolled down (`true`: hide what covers the text) or back up.
    var onScrollDown: (@MainActor (Bool) -> Void)? = nil
    /// Opens with this line's top this far below the text view's top (`screenY`), once its
    /// text is there: so a page opened from the Code level shows the lines that were on screen.
    /// Never past either end, so a page that fits doesn't scroll.
    var startAnchor: PageAnchor? = nil
    var positionStore: ReadingPositionStore = .standard

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> PageTextView {
        // TextKit 1, with a layout manager that also draws whole-line backgrounds (a diff's).
        let storage = NSTextStorage()
        let layoutManager = LineBackgroundLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layoutManager.addTextContainer(container)
        let textView = UITextView(frame: .zero, textContainer: container)
        RawTextStyle.configure(textView)
        textView.contentInsetAdjustmentBehavior = .never  // insets come from `insets` instead
        if #available(iOS 26.0, *) {
            textView.topEdgeEffect.isHidden = true  // nothing covers the top of a page
        }
        textView.delegate = context.coordinator
        if onRefresh != nil {
            let refreshControl = UIRefreshControl()
            refreshControl.addTarget(context.coordinator, action: #selector(Coordinator.handleRefresh(_:)),
                                     for: .valueChanged)
            textView.refreshControl = refreshControl
        }
        let page = PageTextView(textView: textView)
        // Peeking at the line numbers: a drag from the left edge (a plain pan that only takes
        // touches starting there; the screen-edge recognizer lost to the pager and going back).
        let peek = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePeek(_:)))
        peek.delegate = context.coordinator
        page.addGestureRecognizer(peek)
        page.peek = peek
        context.coordinator.peek = peek
        // Hold an identifier to highlight it (or remove its highlight). Holding never selects:
        // a double tap does.
        let highlightPress = UILongPressGestureRecognizer(target: context.coordinator,
                                                          action: #selector(Coordinator.handleHighlightPress(_:)))
        highlightPress.minimumPressDuration = 0.35  // before the text view's own long press selects
        highlightPress.cancelsTouchesInView = false
        highlightPress.delegate = context.coordinator
        textView.addGestureRecognizer(highlightPress)
        context.coordinator.highlightPress = highlightPress
        // Double tap selects a code token (`view` of `self.view`) rather than a word: this only
        // notes where the taps are, alongside the text view's own double tap.
        let tokenTap = UITapGestureRecognizer(target: context.coordinator,
                                              action: #selector(Coordinator.handleTokenTap(_:)))
        tokenTap.numberOfTapsRequired = 2
        tokenTap.cancelsTouchesInView = false
        tokenTap.delaysTouchesEnded = false
        tokenTap.delegate = context.coordinator
        textView.addGestureRecognizer(tokenTap)
        context.coordinator.tokenTap = tokenTap
        return page
    }

    func updateUIView(_ page: PageTextView, context: Context) {
        let textView = page.textView
        let coordinator = context.coordinator
        textView.scrollsToTop = isCurrent
        coordinator.symbolSearchTerm = symbolSearchTerm
        coordinator.onSearchSymbols = onSearchSymbols
        coordinator.onFindOccurrences = onFindOccurrences
        coordinator.onComment = onComment
        coordinator.albumMenu = albumMenu
        coordinator.fileExtension = fileExtension
        coordinator.highlight = highlight
        coordinator.onHighlight = onHighlight
        coordinator.onRefresh = onRefresh
        coordinator.lineNumbering = lineNumbering
        coordinator.onScrollDown = onScrollDown
        coordinator.positionURL = positionURL
        coordinator.positionStore = positionStore

        let contentInset = UIEdgeInsets(top: insets.top, left: 0, bottom: insets.bottom, right: 0)
        if textView.contentInset != contentInset {
            textView.contentInset = contentInset
            textView.verticalScrollIndicatorInsets = contentInset
        }
        // Sideways, keep the text clear of the notch in landscape.
        let base = RawTextStyle.insets
        let containerInset = UIEdgeInsets(top: base.top, left: base.left + insets.leading,
                                          bottom: base.bottom, right: base.right + insets.trailing)
        if textView.textContainerInset != containerInset {
            textView.textContainerInset = containerInset
        }

        guard coordinator.textID != textID else {
            coordinator.updateHighlight(in: textView)
            return
        }
        // Refreshed text keeps the place on screen; first text goes back to the saved one.
        let keep = coordinator.textID != nil && textView.textStorage.length > 0
            ? coordinator.currentPosition(in: textView) : nil
        coordinator.textID = textID
        textView.attributedText = text
        coordinator.textChanged()
        coordinator.updateHighlight(in: textView)
        textView.contentOffset.y = -contentInset.top
        // A place to open at (the first text only) goes before a file page's saved one: Open
        // Whole File opens the file at the symbol it came from.
        if keep == nil, let startAnchor, !coordinator.didApplyStart, text.length > 0 {
            coordinator.didApplyStart = true
            Task { @MainActor [weak textView] in
                // Once the page has its width, so the lines wrap where they'll stay.
                for _ in 0..<5 where (textView?.bounds.width ?? 0) == 0 { await Task.yield() }
                guard let textView else { return }
                textView.layoutIfNeeded()
                coordinator.scroll(to: startAnchor, in: textView)
            }
        } else if let positionURL, let position = keep ?? positionStore.position(for: positionURL) {
            // Once the page has its size, so the lines are where they'll be.
            Task { @MainActor [weak textView] in
                guard let textView else { return }
                textView.layoutIfNeeded()
                coordinator.restore(position, in: textView)
            }
        }
    }

    static func dismantleUIView(_ page: PageTextView, coordinator: Coordinator) {
        coordinator.save(page.textView)
    }

    final class Coordinator: NSObject, UITextViewDelegate, UIGestureRecognizerDelegate, UIEditMenuInteractionDelegate {
        var textID: Int?
        var symbolSearchTerm: (@MainActor (String) -> String?)?
        var onSearchSymbols: (@MainActor (String) -> Void)?
        var onFindOccurrences: (@MainActor (OccurrenceTerm) -> Void)?
        var onComment: (@MainActor (NSRange) -> Void)?
        var albumMenu: (@MainActor (NSRange) -> UIMenu?)?
        var fileExtension = ""
        /// The highlight wanted on this page.
        var highlight: IdentifierHighlight?
        var onHighlight: (@MainActor (IdentifierHighlight?) -> Void)?
        var onRefresh: (@MainActor () async -> Void)?
        var lineNumbering: LineNumbering?
        /// Showing while a peek is held.
        private var gutter: LineNumberGutter?
        var positionURL: URL?
        var positionStore: ReadingPositionStore = .standard

        /// The page's identifiers, made the first time Highlight needs them.
        private var identifiers: IdentifierMap?
        /// The highlight drawn, and where.
        private var shownHighlight: IdentifierHighlight?
        private var highlightedRanges: [NSRange] = []
        private var highlightTask: Task<Void, Never>?

        func textView(_ textView: UITextView, editMenuForTextIn range: NSRange,
                      suggestedActions: [UIMenuElement]) -> UIMenu? {
            let album: [UIMenuElement] = range.length > 0 ? (albumMenu?(range).map { [$0] } ?? []) : []
            let extra = RawTextStyle.commentItems(for: range, onComment: onComment)
                + RawTextStyle.searchItems(for: range, in: textView,
                                           searchTerm: symbolSearchTerm,
                                           onSearch: onSearchSymbols)
                + RawTextStyle.occurrencesItems(for: range, in: textView,
                                                onFind: occurrencesAction(in: textView))
            // Highlight is holding an identifier, not a menu item. Add to Album comes
            // last, after Copy and Share: on the menu's second page.
            return RawTextStyle.editMenu(from: suggestedActions, adding: extra, trailing: album)
        }

        // MARK: Highlight

        /// The page has new text, without any highlight.
        func textChanged() {
            highlightTask?.cancel()
            highlightTask = nil
            identifiers = nil
            shownHighlight = nil
            highlightedRanges = []
        }

        /// Draws `highlight` if it isn't yet. The page's identifiers are found off the main
        /// thread the first time (a few milliseconds for a big file).
        func updateHighlight(in textView: UITextView) {
            guard highlight != shownHighlight else { return }
            shownHighlight = highlight
            highlightTask?.cancel()
            highlightTask = nil
            guard let highlight, textView.textStorage.length > 0 else {
                mark([], in: textView)
                return
            }
            if let identifiers {
                mark(identifiers.occurrences(of: highlight), in: textView)
                return
            }
            let text = textView.textStorage.string
            let fileExtension = fileExtension
            highlightTask = Task { [weak self, weak textView] in
                let map = await Task.detached(priority: .userInitiated) {
                    IdentifierMap(text: text, fileExtension: fileExtension)
                }.value
                guard !Task.isCancelled, let self, let textView else { return }
                self.identifiers = map
                self.mark(map.occurrences(of: highlight), in: textView)
            }
        }

        /// Replaces the highlighted ranges. Only the background changes, so nothing moves.
        private func mark(_ ranges: [NSRange], in textView: UITextView) {
            let storage = textView.textStorage
            guard !(ranges.isEmpty && highlightedRanges.isEmpty) else { return }
            let color = (textView.tintColor ?? .systemBlue).withAlphaComponent(0.3)
            storage.beginEditing()
            for range in highlightedRanges where NSMaxRange(range) <= storage.length {
                storage.removeAttribute(.backgroundColor, range: range)
            }
            for range in ranges where NSMaxRange(range) <= storage.length {
                storage.addAttribute(.backgroundColor, value: color, range: range)
            }
            storage.endEditing()
            highlightedRanges = ranges
        }

        @objc func handleRefresh(_ control: UIRefreshControl) {
            Task { @MainActor in
                await onRefresh?()
                control.endRefreshing()
            }
        }

        // MARK: Line numbers (swipe in from the left edge and hold)

        /// Touches starting this close to the screen's left edge can peek.
        static let peekEdgeWidth: CGFloat = 28

        weak var peek: UIPanGestureRecognizer?

        @objc func handlePeek(_ gesture: UIPanGestureRecognizer) {
            guard let page = gesture.view as? PageTextView, let lineNumbering else { return }
            let textView = page.textView
            let gutter = page.gutter
            switch gesture.state {
            case .began:
                prepareNumbers(in: page, numbering: lineNumbering)
                fallthrough
            case .changed:
                // The page and the numbers slide right together, following the finger until the
                // numbers are all out, then stay while held.
                let shown = min(max(gesture.translation(in: page).x, 0), gutter.bounds.width)
                let slide = CGAffineTransform(translationX: shown, y: 0)
                textView.transform = slide
                gutter.transform = slide
            case .cancelled:
                // Going back may have taken the drag: the watch keeps the numbers out while it
                // does, and puts them away otherwise.
                watchGoingBack(page)
            default:
                Self.hideNumbers(in: page, animated: true)
            }
        }

        private func prepareNumbers(in page: PageTextView, numbering: LineNumbering) {
            let textView = page.textView
            let gutter = page.gutter
            gutter.textView = textView
            gutter.numbering = numbering
            gutter.prepare()
            let width = gutter.preferredWidth(font: LineNumberGutter.font(for: textView))
            gutter.transform = .identity  // a frame is only meaningful without one
            gutter.frame = CGRect(x: -width, y: 0, width: width, height: page.bounds.height)
            gutter.isHidden = false
            gutter.setNeedsDisplay()
        }

        /// Watching the card while an edge drag may be closing it (see `watchGoingBack`).
        private var isWatchingGoingBack = false

        /// Going back takes the drag from the peek (cancelling it, or winning before it starts),
        /// and nothing says so but the card itself, which shrinks under the finger. So the card
        /// is watched: while it's smaller than the screen the numbers are all the way out, as on
        /// a results page; back to full size (going back was let go), they slide away; gone,
        /// they're put back unseen. A drag that wasn't going back ends the watch.
        private func watchGoingBack(_ page: PageTextView) {
            guard !isWatchingGoingBack, lineNumbering != nil else { return }
            isWatchingGoingBack = true
            Task { @MainActor [weak self, weak page] in
                var isShowing = false
                var fullSizeFrames = 0
                var quietFrames = 0
                defer { self?.isWatchingGoingBack = false }
                for _ in 0..<900 {  // 15 s at most
                    try? await Task.sleep(for: .milliseconds(16))
                    guard let self, let page else { return }
                    guard let window = page.window else {
                        Self.hideNumbers(in: page, animated: false)  // the card has gone
                        return
                    }
                    let isShrunk = page.convert(page.bounds, to: nil).width < window.bounds.width * 0.97
                    let isPeeking = self.peek.map { $0.state == .began || $0.state == .changed } ?? false
                    if isShrunk {
                        fullSizeFrames = 0
                        if !isShowing {
                            isShowing = true
                            self.showAllNumbers(in: page)
                        }
                    } else if isShowing {
                        fullSizeFrames += 1
                        if fullSizeFrames > 8 {  // settled back at full size
                            Self.hideNumbers(in: page, animated: true)
                            return
                        }
                    } else if !isPeeking {
                        quietFrames += 1
                        if quietFrames > 20 {  // not going back after all
                            if !page.gutter.isHidden { Self.hideNumbers(in: page, animated: true) }
                            return
                        }
                    }
                }
            }
        }

        /// The numbers all the way out, at once.
        private func showAllNumbers(in page: PageTextView) {
            guard let lineNumbering else { return }
            if page.gutter.isHidden { prepareNumbers(in: page, numbering: lineNumbering) }
            let slide = CGAffineTransform(translationX: page.gutter.bounds.width, y: 0)
            UIView.animate(withDuration: 0.15, delay: 0, options: [.beginFromCurrentState]) {
                page.textView.transform = slide
                page.gutter.transform = slide
            }
        }

        private static func hideNumbers(in page: PageTextView, animated: Bool) {
            let textView = page.textView
            let gutter = page.gutter
            guard animated else {
                textView.transform = .identity
                gutter.transform = .identity
                gutter.isHidden = true
                return
            }
            UIView.animate(withDuration: 0.2, delay: 0, options: [.curveEaseIn, .beginFromCurrentState]) {
                textView.transform = .identity
                gutter.transform = .identity
            } completion: { _ in
                if textView.transform == .identity { gutter.isHidden = true }
            }
        }

        // MARK: Hold to highlight

        weak var highlightPress: UILongPressGestureRecognizer?

        /// Holding only highlights (an identifier; elsewhere it does nothing): it never selects.
        /// Selecting is a double tap, then the handles.
        @objc func handleHighlightPress(_ gesture: UILongPressGestureRecognizer) {
            guard let textView = gesture.view as? UITextView else { return }
            switch gesture.state {
            case .began:
                cancelTextViewHold(textView, except: gesture)
                guard let onHighlight, let found = identifierAt(gesture.location(in: textView), in: textView)
                else { return }
                let (identifier, index) = found
                let isHighlighted = highlightedRanges.contains { NSLocationInRange(index, $0) }
                UIImpactFeedbackGenerator(style: .light).impactOccurred(at: gesture.location(in: textView))
                onHighlight(isHighlighted ? nil : identifier)
            default:
                break
            }
        }

        /// This hold is taken: the text view's own (selecting, its loupe) stops here. Its text
        /// gestures are on the text view and on the views inside it; turning one off and on
        /// cancels it for the current touch. Scrolling carries on.
        private func cancelTextViewHold(_ textView: UITextView, except gesture: UIGestureRecognizer) {
            var views: [UIView] = [textView]
            while let view = views.popLast() {
                for other in view.gestureRecognizers ?? []
                where other !== gesture && other !== tokenTap && !(other is UIPanGestureRecognizer) && other.isEnabled {
                    other.isEnabled = false
                    other.isEnabled = true
                }
                views.append(contentsOf: view.subviews)
            }
        }

        /// Occurrences in the menu: what to look for is worked out when it's chosen.
        private func occurrencesAction(in textView: UITextView) -> (@MainActor (String, NSRange) -> Void)? {
            guard let find = onFindOccurrences else { return nil }
            return { [weak self, weak textView] text, range in
                guard let self, let textView else { return }
                find(self.occurrenceTerm(text, at: range, in: textView))
            }
        }

        /// What Occurrences looks for: with Same Kind on (the sidebar), the identifier the
        /// selection is, from the page's parse (made now if Highlight hasn't yet).
        private func occurrenceTerm(_ text: String, at range: NSRange, in textView: UITextView) -> OccurrenceTerm {
            guard UserDefaults.standard.bool(forKey: OccurrenceTerm.sameKindKey),
                  NSMaxRange(range) <= textView.textStorage.length
            else { return OccurrenceTerm(text: text, identifier: nil) }
            // The selection without the spaces around it.
            let selected = textView.textStorage.mutableString.substring(with: range) as NSString
            let inside = selected.range(of: text)
            guard inside.location != NSNotFound else { return OccurrenceTerm(text: text, identifier: nil) }
            let map = identifiers ?? IdentifierMap(text: textView.textStorage.string, fileExtension: fileExtension)
            identifiers = map
            let found = map.identifier(containing: NSRange(location: range.location + inside.location, length: inside.length))
            let identifier = found.flatMap { $0.name == text && $0.kind != nil ? $0 : nil }
            return OccurrenceTerm(text: text, identifier: identifier)
        }

        /// The identifier under a point of the text view, and the character there: only right on
        /// a character, not in the space after a line's end.
        private func identifierAt(_ point: CGPoint, in textView: UITextView) -> (IdentifierHighlight, Int)? {
            guard let index = characterIndex(at: point, in: textView) else { return nil }
            let storage = textView.textStorage
            let map = identifiers ?? IdentifierMap(text: storage.string, fileExtension: fileExtension)
            identifiers = map
            return map.identifier(containing: NSRange(location: index, length: 1)).map { ($0, index) }
        }

        /// The character right under a point of the text view (not the space after a line's end).
        private func characterIndex(at point: CGPoint, in textView: UITextView) -> Int? {
            let storage = textView.textStorage
            guard storage.length > 0 else { return nil }
            let layoutManager = textView.layoutManager
            let container = textView.textContainer
            let location = CGPoint(x: point.x - textView.textContainerInset.left,
                                   y: point.y - textView.textContainerInset.top)
            let glyph = layoutManager.glyphIndex(for: location, in: container)
            let bounds = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
            guard bounds.insetBy(dx: -3, dy: -2).contains(location) else { return nil }
            let index = layoutManager.characterIndexForGlyph(at: glyph)
            return index < storage.length ? index : nil
        }

        // MARK: Double tap selects a token

        weak var tokenTap: UITapGestureRecognizer?
        /// The character double-tapped, kept a moment (the text view's own double tap may select
        /// the word just before or just after this one sees the taps).
        private var pressIndex: Int?
        private var pressCount = 0
        private var isSnapping = false

        @objc func handleTokenTap(_ gesture: UITapGestureRecognizer) {
            guard gesture.state == .ended, let textView = gesture.view as? UITextView else { return }
            pressCount += 1
            pressIndex = characterIndex(at: gesture.location(in: textView), in: textView)
            snapSelection(in: textView)  // in case the word was selected first
            let count = pressCount
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(400))
                guard let self, self.pressCount == count else { return }
                self.pressIndex = nil
            }
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            // A hold selected anyway (a gesture of the text view's that wasn't cancelled): undo it.
            if let hold = highlightPress, hold.state == .began || hold.state == .changed,
               textView.selectedRange.length > 0, !isSnapping {
                isSnapping = true
                textView.selectedRange = NSRange(location: textView.selectedRange.location, length: 0)
                isSnapping = false
                return
            }
            // Dragging a handle afterwards: the text view shows its own menu, so not this one too.
            if pressIndex == nil { menuInteraction?.dismissMenu() }
            snapSelection(in: textView)
        }

        /// The word the double tap selected becomes the token there. Selections made otherwise
        /// (handles, Select All, holding off an identifier) stay as they are.
        private func snapSelection(in textView: UITextView) {
            guard !isSnapping, let index = pressIndex else { return }
            let selected = textView.selectedRange
            guard selected.length > 0, NSLocationInRange(index, selected),
                  let token = CodeToken.range(at: index, in: textView.textStorage.mutableString)
            else { return }
            if token != selected {
                isSnapping = true
                textView.selectedRange = token
                isSnapping = false
            }
            showMenuOnce(for: token, in: textView)
        }

        /// The double tap that `showMenuOnce` last showed the menu for.
        private var menuShownForPress = 0

        /// The menu, once per double tap: a read-only text view shows none after a double tap
        /// (only after a hold). Shown a moment later, once the text view is done with the taps
        /// (it hid a menu shown straight away).
        private func showMenuOnce(for token: NSRange, in textView: UITextView) {
            guard menuShownForPress != pressCount else { return }
            menuShownForPress = pressCount
            Task { @MainActor [weak textView] in
                try? await Task.sleep(for: .milliseconds(60))
                guard let textView, textView.selectedRange == token, let rect = self.selectionRect(in: textView)
                else { return }
                if !textView.isFirstResponder { textView.becomeFirstResponder() }  // for Copy
                self.doubleTapMenu(on: textView).presentEditMenu(with: UIEditMenuConfiguration(
                    identifier: nil, sourcePoint: CGPoint(x: rect.midX, y: rect.minY)))
            }
        }

        /// The selection's first line, in the text view.
        private func selectionRect(in textView: UITextView) -> CGRect? {
            guard let range = textView.selectedTextRange, !range.isEmpty else { return nil }
            let rect = textView.firstRect(for: range)
            return rect.isNull || rect.isInfinite ? nil : rect
        }

        /// The double tap's own menu interaction, with the same items as the text view's menu
        /// (the text view's own interaction showed nothing when asked).
        private var menuInteraction: UIEditMenuInteraction?

        private func doubleTapMenu(on textView: UITextView) -> UIEditMenuInteraction {
            if let menuInteraction, menuInteraction.view === textView { return menuInteraction }
            let interaction = UIEditMenuInteraction(delegate: self)
            textView.addInteraction(interaction)
            menuInteraction = interaction
            return interaction
        }

        func editMenuInteraction(_ interaction: UIEditMenuInteraction, menuFor configuration: UIEditMenuConfiguration,
                                 suggestedActions: [UIMenuElement]) -> UIMenu? {
            guard let textView = interaction.view as? UITextView else { return nil }
            // Copy and Select All at least, if the system suggested nothing.
            let suggested = suggestedActions.isEmpty
                ? [UICommand(title: String(localized: "Copy"), action: #selector(UIResponderStandardEditActions.copy(_:))),
                   UICommand(title: String(localized: "Select All"),
                             action: #selector(UIResponderStandardEditActions.selectAll(_:)))]
                : suggestedActions
            return self.textView(textView, editMenuForTextIn: textView.selectedRange, suggestedActions: suggested)
        }

        /// The menu points at the selection.
        func editMenuInteraction(_ interaction: UIEditMenuInteraction,
                                 targetRectFor configuration: UIEditMenuConfiguration) -> CGRect {
            guard let textView = interaction.view as? UITextView else { return .null }
            return selectionRect(in: textView) ?? .null
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            if gestureRecognizer === peek {
                // Going back, alongside: not the page's or the pager's scrolling.
                return !(otherGestureRecognizer.view is UIScrollView)
            }
            return gestureRecognizer === tokenTap || gestureRecognizer === highlightPress
        }

        /// The peek only takes touches that start at the screen's left edge.
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard gestureRecognizer === peek else { return true }
            guard lineNumbering != nil, touch.location(in: nil).x <= Self.peekEdgeWidth else { return false }
            // If going back wins the drag before the peek starts, the numbers still come out.
            if let page = gestureRecognizer.view as? PageTextView { watchGoingBack(page) }
            return true
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            if gestureRecognizer === peek, let pan = gestureRecognizer as? UIPanGestureRecognizer {
                let velocity = pan.velocity(in: pan.view)
                return velocity.x > abs(velocity.y)  // rightwards
            }
            if gestureRecognizer === highlightPress {
                // Pages that highlight take every hold, so holding never selects there.
                return onHighlight != nil
            }
            return true
        }

        /// The peek goes before the pages and the scrolling (it only takes touches at the left
        /// edge), and alongside going back. Nothing waits for holding to highlight: it starts while the finger is
        /// still down, and stops the text view's own hold itself (`handleHighlightPress`).
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            // Scrolling (the page's, the pager's paging) waits for the peek; going back doesn't.
            if gestureRecognizer === peek { return otherGestureRecognizer.view is UIScrollView }
            return false
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            reportScrollDirection(scrollView)
            // The numbers follow the text while it scrolls under them.
            if let page = scrollView.superview as? PageTextView, !page.gutter.isHidden {
                page.gutter.setNeedsDisplay()
            }
        }

        // MARK: Scrolling down hides the caption

        var onScrollDown: (@MainActor (Bool) -> Void)?
        private var lastY: CGFloat?
        private var isScrolledDown = false

        /// Reading on (scrolling down) hides the caption; scrolling back up, or reaching the end,
        /// shows it again. Only the reader's own scrolling counts.
        private func reportScrollDirection(_ scrollView: UIScrollView) {
            guard let onScrollDown else { return }
            let y = scrollView.contentOffset.y
            defer { lastY = y }
            guard scrollView.isTracking || scrollView.isDecelerating, let lastY else { return }
            let inset = scrollView.adjustedContentInset
            let end = scrollView.contentSize.height + inset.bottom - scrollView.bounds.height
            let down: Bool
            if y >= end - 1 || y <= -inset.top {
                down = false
            } else if y - lastY > 4 {
                down = true
            } else if lastY - y > 4 {
                down = false
            } else {
                return
            }
            guard down != isScrolledDown else { return }
            isScrolledDown = down
            onScrollDown(down)
        }

        // MARK: Reading position (a file's page)

        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            if !decelerate, let textView = scrollView as? UITextView { save(textView) }
        }

        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
            if let textView = scrollView as? UITextView { save(textView) }
        }

        func scrollViewDidScrollToTop(_ scrollView: UIScrollView) {
            if let textView = scrollView as? UITextView { save(textView) }
        }

        func save(_ textView: UITextView) {
            guard let positionURL, let position = currentPosition(in: textView) else { return }
            positionStore.save(position, for: positionURL)
        }

        /// The line at the top of the page and how far it's scrolled past.
        func currentPosition(in textView: UITextView) -> ReadingPosition? {
            guard textView.textStorage.length > 0 else { return nil }
            let y = textView.contentOffset.y + textView.adjustedContentInset.top - textView.textContainerInset.top
            guard y > 0 else { return .top }
            let layoutManager = textView.layoutManager
            let glyphIndex = layoutManager.glyphIndex(for: CGPoint(x: 0, y: y), in: textView.textContainer)
            let lineRect = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
            return ReadingPosition(characterIndex: layoutManager.characterIndexForGlyph(at: glyphIndex),
                                   lineOffset: Double(y - lineRect.minY))
        }

        /// `startAnchor` has been used (on the page's first text).
        var didApplyStart = false

        /// Scrolls so `anchor.line` starts `anchor.screenY` below the text view's top, as far as
        /// the text allows.
        func scroll(to anchor: PageAnchor, in textView: UITextView) {
            let text: NSString = textView.textStorage.mutableString  // `string` would copy it all
            guard text.length > 0 else { return }
            var location = 0
            var line = 0
            while line < anchor.line {
                let found = text.range(of: "\n", options: .literal,
                                       range: NSRange(location: location, length: text.length - location))
                guard found.location != NSNotFound, NSMaxRange(found) < text.length else { break }
                location = NSMaxRange(found)
                line += 1
            }
            let layoutManager = textView.layoutManager
            let glyphIndex = layoutManager.glyphIndexForCharacter(at: min(location, text.length - 1))
            let lineRect = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
            let inset = textView.adjustedContentInset
            let contentHeight = layoutManager.usedRect(for: textView.textContainer).height
                + textView.textContainerInset.top + textView.textContainerInset.bottom
            let maxY = max(-inset.top, contentHeight - textView.bounds.height + inset.bottom)
            let y = lineRect.minY + textView.textContainerInset.top - anchor.screenY
            textView.contentOffset.y = min(max(y, -inset.top), maxY)
        }

        func restore(_ position: ReadingPosition, in textView: UITextView) {
            let length = textView.textStorage.length
            let inset = textView.adjustedContentInset
            guard position != .top, length > 0 else { return }
            let layoutManager = textView.layoutManager
            let glyphIndex = layoutManager.glyphIndexForCharacter(at: min(position.characterIndex, length - 1))
            let lineRect = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
            let y = lineRect.minY + min(CGFloat(position.lineOffset), lineRect.height)
            let contentHeight = layoutManager.usedRect(for: textView.textContainer).height
                + textView.textContainerInset.top + textView.textContainerInset.bottom
            let maxY = max(-inset.top, contentHeight - textView.bounds.height + inset.bottom)
            textView.contentOffset.y = min(max(y + textView.textContainerInset.top - inset.top, -inset.top), maxY)
        }
    }
}
