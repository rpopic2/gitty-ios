import SwiftUI
import UIKit

/// One symbol at a time, full screen, like a photo opened in Photos.
/// Swipe left/right for the previous/next symbol. Swipe down to zoom back to the list
/// (the zoom navigation transition provides that gesture).
///
/// A file's own page is the whole file, where File used to be: select text for Comment and
/// Search, pull to refresh it, and it comes back where you left off.
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

    @State private var scrolledID: Int?
    @State private var isPositioned = false
    /// Paged away from the tapped symbol at least once.
    @State private var hasPaged = false
    /// Swiping from the right edge pages here, so it doesn't open the sidebar.
    @Environment(SideBarState.self) private var sideBar: SideBarState?

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
         onComment: @escaping @MainActor (CodeSymbol, NSRange) -> Void) {
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
                                    positionURL: isFilePage ? symbol.fileURL ?? openFile : nil,
                                    onRefresh: refreshAction(for: symbol)
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
                    SymbolCaption(symbol: current)
                        .padding(.bottom, 8)
                }
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .onAppear { sideBar?.isEdgeSwipeEnabled = false }
        .onDisappear { sideBar?.isEdgeSwipeEnabled = true }
        .background(WillDisappearObserver { onWillClose(visibleID) })
        .onChange(of: scrolledID) { _, id in
            // Until the pager is on the tapped symbol, don't let the first layout overwrite it.
            guard isPositioned, let id else { return }
            currentID = id
            if id != initialID { hasPaged = true }
            if hasPaged { onPage(id) }
        }
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
        return symbol.kind == .file ? ObjectIdentifier(text).hashValue : symbol.id
    }
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

/// "name · Line N" in a small capsule at the bottom, in place of the bar and selector.
private struct SymbolCaption: View {
    let symbol: CodeSymbol

    static let height: CGFloat = 36
    /// Space kept free under the text so its end isn't hidden behind the caption.
    static let reservedHeight: CGFloat = height + 16

    var body: some View {
        capsule
            .allowsHitTesting(false)  // touches go to the page under it
            .accessibilityElement(children: .combine)
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
    /// A file's page: the file whose reading position it keeps (saved when scrolling stops,
    /// restored when the page takes its text).
    var positionURL: URL? = nil
    /// A file's page: pull to refresh.
    var onRefresh: (@MainActor () async -> Void)? = nil
    var positionStore: ReadingPositionStore = .standard

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView(usingTextLayoutManager: false)
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
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        let coordinator = context.coordinator
        textView.scrollsToTop = isCurrent
        coordinator.symbolSearchTerm = symbolSearchTerm
        coordinator.onSearchSymbols = onSearchSymbols
        coordinator.onComment = onComment
        coordinator.onRefresh = onRefresh
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

        guard coordinator.textID != textID else { return }
        // Refreshed text keeps the place on screen; first text goes back to the saved one.
        let keep = coordinator.textID != nil && textView.textStorage.length > 0
            ? coordinator.currentPosition(in: textView) : nil
        coordinator.textID = textID
        textView.attributedText = text
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

    final class Coordinator: NSObject, UITextViewDelegate {
        var textID: Int?
        var symbolSearchTerm: (@MainActor (String) -> String?)?
        var onSearchSymbols: (@MainActor (String) -> Void)?
        var onComment: (@MainActor (NSRange) -> Void)?
        var onRefresh: (@MainActor () async -> Void)?
        var positionURL: URL?
        var positionStore: ReadingPositionStore = .standard

        func textView(_ textView: UITextView, editMenuForTextIn range: NSRange,
                      suggestedActions: [UIMenuElement]) -> UIMenu? {
            let extra = RawTextStyle.commentItems(for: range, onComment: onComment)
                + RawTextStyle.searchItems(for: range, in: textView,
                                           searchTerm: symbolSearchTerm,
                                           onSearch: onSearchSymbols)
            return RawTextStyle.editMenu(from: suggestedActions, adding: extra)
        }

        @objc func handleRefresh(_ control: UIRefreshControl) {
            Task { @MainActor in
                await onRefresh?()
                control.endRefreshing()
            }
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
