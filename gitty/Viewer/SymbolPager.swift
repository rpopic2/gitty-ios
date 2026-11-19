import SwiftUI
import UIKit

/// One symbol at a time, full screen, like a photo opened in Photos.
/// Swipe left/right for the previous/next symbol. Pinch or swipe down to close it, back to the
/// list at the symbol on screen (the zoom navigation transition provides those gestures).
///
/// A file's own page is the whole file, where File used to be: select text for Comment and
/// Search, pull to refresh it, and it comes back where you left off. Pull up past its end for
/// the file's info and history, like swiping up on a photo.
struct SymbolPager: View {
    let symbols: [CodeSymbol]
    /// The symbol that was tapped. The pager opens on it.
    let initialID: Int
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
    /// Search in a page's text menu: close the pager and search symbols.
    let symbolSearchTerm: @MainActor (String) -> String?
    let onSearchSymbols: @MainActor (String) -> Void
    /// Comment in a page's text menu, with the range in the symbol's text.
    let onComment: @MainActor (CodeSymbol, NSRange) -> Void
    /// The line of its file a page's text starts at, for the line-number peek.
    let firstLine: @MainActor (CodeSymbol) -> Int

    @State private var scrolledID: Int?
    @State private var isPositioned = false
    /// The file whose info panel is open.
    @State private var infoFile: InfoFile?
    /// Scrolling down a page hides the caption; scrolling up shows it.
    @State private var isCaptionHidden = false
    /// Paged away from the tapped symbol at least once.
    @State private var hasPaged = false
    /// Swiping from the right edge pages here, so it doesn't open the sidebar.
    @Environment(SideBarState.self) private var sideBar: SideBarState?
    /// The identifier highlighted on every page (Highlight in the text menu).
    @Environment(HighlightState.self) private var highlights: HighlightState?
    /// A page takes its text again when the code font changes.
    @Environment(\.codeTextStyle) private var codeTextStyle

    // An explicit init (not the memberwise one) so passing in an existing `@MainActor` closure
    // doesn't warn about converting it to `@Sendable`.
    init(symbols: [CodeSymbol], initialID: Int, currentID: Binding<Int?>,
         text: @escaping @MainActor (CodeSymbol) -> NSAttributedString?,
         onPage: @escaping @MainActor (Int) -> Void,
         onWillClose: @escaping @MainActor (Int) -> Void,
         openFile: URL,
         onRefresh: @escaping @MainActor (URL?) async -> Void,
         symbolSearchTerm: @escaping @MainActor (String) -> String?,
         onSearchSymbols: @escaping @MainActor (String) -> Void,
         onComment: @escaping @MainActor (CodeSymbol, NSRange) -> Void,
         firstLine: @escaping @MainActor (CodeSymbol) -> Int) {
        self.symbols = symbols
        self.initialID = initialID
        _currentID = currentID
        self.text = text
        self.onPage = onPage
        self.onWillClose = onWillClose
        self.openFile = openFile
        self.onRefresh = onRefresh
        self.symbolSearchTerm = symbolSearchTerm
        self.onSearchSymbols = onSearchSymbols
        self.onComment = onComment
        self.firstLine = firstLine
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
                bottom: safeArea.bottom + SymbolCaption.reservedHeight,
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
                                    onComment: { onComment(symbol, $0) },
                                    fileExtension: (symbol.fileURL ?? openFile).pathExtension,
                                    highlight: highlights?.current,
                                    onHighlight: { highlights?.current = $0 },
                                    positionURL: isFilePage ? symbol.fileURL ?? openFile : nil,
                                    onRefresh: refreshAction(for: symbol),
                                    onPullUp: infoAction(for: symbol),
                                    lineNumbering: .counted(firstLine: { firstLine(symbol) }),
                                    onScrollDown: { isCaptionHidden = $0 }
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

                if let current {
                    SymbolCaption(symbol: current, onInfo: infoAction(for: current))
                        .padding(.bottom, 8)
                        .offset(y: isCaptionHidden ? SymbolCaption.reservedHeight + 40 : 0)
                        .opacity(isCaptionHidden ? 0 : 1)
                        .allowsHitTesting(!isCaptionHidden)
                        .accessibilityHidden(isCaptionHidden)
                        .animation(.smooth(duration: 0.25), value: isCaptionHidden)
                }
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .sheet(item: $infoFile) { file in
            FileInfoView(url: file.url)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .onAppear { sideBar?.isEdgeSwipeEnabled = false }
        .onDisappear { sideBar?.isEdgeSwipeEnabled = true }
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

    /// Pulling up past the end of a page (or its caption): the info panel of its file.
    private func infoAction(for symbol: CodeSymbol) -> @MainActor () -> Void {
        let url = symbol.fileURL ?? openFile
        return { infoFile = InfoFile(url: url) }
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

/// A file whose info panel is open.
private struct InfoFile: Identifiable {
    let url: URL
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

/// "name · Line N" in a small capsule at the bottom, in place of the bar and selector. Tap it
/// or pull it up for the file's info.
private struct SymbolCaption: View {
    let symbol: CodeSymbol
    let onInfo: @MainActor () -> Void

    static let height: CGFloat = 36
    /// Space kept free under the text so its end isn't hidden behind the caption.
    static let reservedHeight: CGFloat = height + 16
    /// How far up to pull it (or flick it) for the info.
    private static let pullDistance: CGFloat = 40

    init(symbol: CodeSymbol, onInfo: @escaping @MainActor () -> Void) {
        self.symbol = symbol
        self.onInfo = onInfo
    }

    var body: some View {
        capsule
            .onTapGesture { onInfo() }
            .gesture(
                DragGesture(minimumDistance: 8).onEnded { value in
                    if value.translation.height < -Self.pullDistance
                        || value.predictedEndTranslation.height < -3 * Self.pullDistance {
                        onInfo()
                    }
                }
            )
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityHint(Text("Shows the file’s info and history"))
    }

    @ViewBuilder
    private var capsule: some View {
        let label = HStack(spacing: 6) {
            Image(systemName: symbol.kind.systemImage)
                .foregroundStyle(.tint)
            Text(symbol.name)
                .lineLimit(1)
                .truncationMode(.middle)
            // From another file of the project: which one. A file's own page needs nothing
            // more than its name.
            if symbol.kind != .file {
                Text(symbol.fileURL.map { "· \($0.lastPathComponent):\(symbol.line)" } ?? "· Line \(symbol.line)")
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
    /// Comment in the text menu: adds a comment on the selected range to the review.
    var onComment: (@MainActor (NSRange) -> Void)? = nil
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
    /// Pulled up past the end of the text: the file's info.
    var onPullUp: (@MainActor () -> Void)? = nil
    /// Swiping in from the left edge and holding shows the line numbers, numbered this way.
    var lineNumbering: LineNumbering? = nil
    /// The reader scrolled down (`true`: hide what covers the text) or back up.
    var onScrollDown: (@MainActor (Bool) -> Void)? = nil
    var positionStore: ReadingPositionStore = .standard

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UITextView {
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
        let peek = UIScreenEdgePanGestureRecognizer(target: context.coordinator,
                                                    action: #selector(Coordinator.handlePeek(_:)))
        peek.edges = .left
        peek.delegate = context.coordinator
        textView.addGestureRecognizer(peek)
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        let coordinator = context.coordinator
        textView.scrollsToTop = isCurrent
        coordinator.symbolSearchTerm = symbolSearchTerm
        coordinator.onSearchSymbols = onSearchSymbols
        coordinator.onComment = onComment
        coordinator.fileExtension = fileExtension
        coordinator.highlight = highlight
        coordinator.onHighlight = onHighlight
        coordinator.onRefresh = onRefresh
        coordinator.onPullUp = onPullUp
        coordinator.lineNumbering = lineNumbering
        coordinator.onScrollDown = onScrollDown
        textView.accessibilityCustomActions = onPullUp == nil ? nil : [
            UIAccessibilityCustomAction(name: String(localized: "File Info")) { _ in
                coordinator.onPullUp?()
                return true
            },
        ]
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
        if let positionURL, let position = keep ?? positionStore.position(for: positionURL) {
            // Once the page has its size, so the lines are where they'll be.
            Task { @MainActor [weak textView] in
                guard let textView else { return }
                textView.layoutIfNeeded()
                coordinator.restore(position, in: textView)
            }
        }
    }

    static func dismantleUIView(_ textView: UITextView, coordinator: Coordinator) {
        coordinator.save(textView)
    }

    final class Coordinator: NSObject, UITextViewDelegate, UIGestureRecognizerDelegate {
        var textID: Int?
        var symbolSearchTerm: (@MainActor (String) -> String?)?
        var onSearchSymbols: (@MainActor (String) -> Void)?
        var onComment: (@MainActor (NSRange) -> Void)?
        var fileExtension = ""
        /// The highlight wanted on this page.
        var highlight: IdentifierHighlight?
        var onHighlight: (@MainActor (IdentifierHighlight?) -> Void)?
        var onRefresh: (@MainActor () async -> Void)?
        var onPullUp: (@MainActor () -> Void)?
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
            let extra = RawTextStyle.commentItems(for: range, onComment: onComment)
                + RawTextStyle.searchItems(for: range, in: textView,
                                           searchTerm: symbolSearchTerm,
                                           onSearch: onSearchSymbols)
                + highlightItems(for: range, in: textView)
            return RawTextStyle.editMenu(from: suggestedActions, adding: extra)
        }

        // MARK: Highlight

        /// "Highlight" when the selection is inside an identifier (a word, on a page without
        /// a grammar); "Remove Highlight" on one that's highlighted.
        private func highlightItems(for range: NSRange, in textView: UITextView) -> [UIMenuElement] {
            guard let onHighlight, textView.textStorage.length > 0,
                  NSMaxRange(range) <= textView.textStorage.length
            else { return [] }
            let map = identifiers ?? IdentifierMap(text: textView.textStorage.string, fileExtension: fileExtension)
            identifiers = map
            guard let identifier = map.identifier(containing: range) else { return [] }
            let isHighlighted = highlightedRanges.contains {
                $0.location <= range.location && NSMaxRange(range) <= NSMaxRange($0)
            }
            if isHighlighted {
                return [UIAction(title: String(localized: "Remove Highlight"),
                                 image: UIImage(systemName: "highlighter")) { _ in onHighlight(nil) }]
            }
            return [UIAction(title: String(localized: "Highlight"),
                             image: UIImage(systemName: "highlighter")) { _ in onHighlight(identifier) }]
        }

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

        @objc func handlePeek(_ gesture: UIScreenEdgePanGestureRecognizer) {
            guard let textView = gesture.view as? UITextView, let lineNumbering else { return }
            switch gesture.state {
            case .began:
                let gutter = self.gutter ?? LineNumberGutter()
                self.gutter = gutter
                gutter.textView = textView
                gutter.numbering = lineNumbering
                gutter.prepare()
                let width = gutter.preferredWidth(font: LineNumberGutter.font(for: textView))
                // Just left of the text: the whole page slides right to show it (the text view
                // scrolls sideways, which nothing else does, so the text isn't laid out again).
                gutter.frame = CGRect(x: -width, y: textView.contentOffset.y, width: width, height: textView.bounds.height)
                textView.addSubview(gutter)
                gutter.setNeedsDisplay()
                fallthrough
            case .changed:
                guard let gutter else { return }
                // Follows the finger until it's all out, then stays while held.
                let shown = min(max(gesture.translation(in: textView).x, 0), gutter.bounds.width)
                textView.contentOffset.x = -shown
            default:
                guard let gutter else { return }
                UIView.animate(withDuration: 0.2, delay: 0, options: [.curveEaseIn, .beginFromCurrentState]) {
                    textView.contentOffset.x = 0
                } completion: { _ in
                    if textView.contentOffset.x == 0 { gutter.removeFromSuperview() }
                }
            }
        }

        /// The peek goes first: the pages, the scrolling and going back wait for it to fail,
        /// which it does at once away from the left edge.
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            gestureRecognizer is UIScreenEdgePanGestureRecognizer && lineNumbering != nil
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            !(gestureRecognizer is UIScreenEdgePanGestureRecognizer) || lineNumbering != nil
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            reportScrollDirection(scrollView)
            // The peek stays over the screen while the text scrolls under it.
            guard let gutter, gutter.superview != nil, gutter.frame.minY != scrollView.contentOffset.y else { return }
            gutter.frame.origin.y = scrollView.contentOffset.y
            gutter.setNeedsDisplay()
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

        /// Let go while pulled this far past the end: the file's info opens.
        static let pullUpDistance: CGFloat = 60

        func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint,
                                       targetContentOffset: UnsafeMutablePointer<CGPoint>) {
            guard let onPullUp else { return }
            let inset = scrollView.adjustedContentInset
            let end = max(scrollView.contentSize.height + inset.bottom - scrollView.bounds.height, -inset.top)
            if scrollView.contentOffset.y > end + Self.pullUpDistance { onPullUp() }
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
