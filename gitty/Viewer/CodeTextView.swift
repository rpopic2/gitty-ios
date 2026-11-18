import SwiftUI
import UIKit

/// Read-only, selectable raw text in a `UITextView` using TextKit 1 with contiguous layout.
///
/// Why TextKit 1: TextKit 2 only estimates the height of text it hasn't laid out, and `UITextView`
/// keeps correcting those estimates (and the scroll position) as you scroll, so the scroll bar
/// and the text jump. TextKit 1 with contiguous layout knows the exact height of every line,
/// like Safari, so nothing is ever corrected mid-scroll.
///
/// For smooth scrolling:
/// - The whole file is laid out once after it is set and again when the width changes, in slices
///   that yield to the run loop between them. A typical source file is a single slice.
/// - Text is set only when `version` changes, never on other SwiftUI updates.
/// - Scrolling reports to SwiftUI only when the bar's collapsed state flips, never per frame.
///
/// The reading position is saved per file when scrolling stops and when the app goes to the
/// background, and restored the next time the file opens.
struct CodeTextView: UIViewRepresentable {
    let text: RenderedText
    let version: UUID
    /// Identifies the file for its saved reading position.
    let documentURL: URL
    /// Space kept free under the text for the expanded bottom bar, above the home indicator.
    let bottomBarHeight: CGFloat
    let isBarCollapsed: Bool
    /// Changes when the reader taps the collapsed bar open.
    let barTapCount: Int
    let onRefresh: @MainActor () async -> Void
    let onBarCollapsedChange: @MainActor (Bool) -> Void
    /// False while another mode (Symbols) covers the file. The view stays alive to keep its place.
    var isActive = true
    var positionStore: ReadingPositionStore = .standard
    /// Jump to Definition in the text menu: the search term for a selected name (`nil` hides the
    /// item)…
    var symbolSearchTerm: (@MainActor (String) -> String?)? = nil
    /// …and searching symbols for it.
    var onSearchSymbols: (@MainActor (String) -> Void)? = nil
    /// Comment in the text menu: adds a comment on the selected range to the review.
    var onComment: (@MainActor (NSRange) -> Void)? = nil
    /// Scrolls to a place in the file once per request (Show in File).
    var scrollRequest: FileScrollRequest? = nil

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> CodeUITextView {
        let textView = CodeUITextView(usingTextLayoutManager: false)
        RawTextStyle.configure(textView)
        textView.delegate = context.coordinator
        context.coordinator.textView = textView

        let refreshControl = UIRefreshControl()
        refreshControl.addTarget(context.coordinator,
                                 action: #selector(Coordinator.handleRefresh(_:)),
                                 for: .valueChanged)
        textView.refreshControl = refreshControl

        // Wrapped lines change with the width (rotation, iPad split view), so lay out again.
        textView.onWidthChange = { [weak coordinator = context.coordinator] textView in
            coordinator?.widthDidChange(textView)
        }
        return textView
    }

    func updateUIView(_ textView: CodeUITextView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onRefresh = onRefresh
        coordinator.onBarCollapsedChange = onBarCollapsedChange
        coordinator.barTracker.isCollapsed = isBarCollapsed
        if coordinator.barTapCount != barTapCount {
            coordinator.barTapCount = barTapCount
            coordinator.barTracker.holdOpen()
        }
        // Only the visible scroll view may answer a tap on the status bar.
        textView.scrollsToTop = isActive
        coordinator.documentURL = documentURL
        coordinator.positionStore = positionStore
        coordinator.symbolSearchTerm = symbolSearchTerm
        coordinator.onSearchSymbols = onSearchSymbols
        coordinator.onComment = onComment

        if textView.contentInset.bottom != bottomBarHeight {
            textView.contentInset.bottom = bottomBarHeight
            textView.verticalScrollIndicatorInsets.bottom = bottomBarHeight
        }

        if coordinator.version != version {
            // After a refresh, stay where the reader is. On first show, go back to where they left off.
            coordinator.pendingRestore = coordinator.version != nil
                ? coordinator.currentPosition(in: textView)
                : positionStore.position(for: documentURL)
            coordinator.version = version
            textView.attributedText = text.attributedString
            coordinator.layOutWholeDocument(textView)
        }

        if let request = scrollRequest, request.id != coordinator.lastScrollRequestID {
            coordinator.lastScrollRequestID = request.id
            coordinator.scroll(toCharacter: request.characterIndex, in: textView)
        }
    }

    static func dismantleUIView(_ textView: CodeUITextView, coordinator: Coordinator) {
        coordinator.saveCurrentPosition()
        coordinator.cancelLayout()
    }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate {
        weak var textView: UITextView?
        var version: UUID?
        var documentURL: URL?
        var positionStore: ReadingPositionStore = .standard
        var onRefresh: (@MainActor () async -> Void)?
        var onBarCollapsedChange: (@MainActor (Bool) -> Void)?
        var barTracker = BarCollapseTracker()
        var barTapCount = 0
        var symbolSearchTerm: (@MainActor (String) -> String?)?
        var onSearchSymbols: (@MainActor (String) -> Void)?
        var onComment: (@MainActor (NSRange) -> Void)?

        /// Characters laid out per slice. Most source files fit in one slice, so they are fully
        /// laid out before the first frame; bigger files finish over the next few frames.
        private let charactersPerSlice = 100_000
        private var layoutTask: Task<Void, Never>?

        /// Position to scroll to once the text is fully laid out.
        var pendingRestore: ReadingPosition?
        /// Last known position, reused when the width changes (the old layout is gone by then).
        private var lastPosition: ReadingPosition?

        override init() {
            super.init()
            // Save before the app is suspended: it may be killed without another callback.
            // Selector-based observers are removed automatically when the coordinator goes away.
            NotificationCenter.default.addObserver(self, selector: #selector(sceneWillDeactivate),
                                                   name: UIScene.willDeactivateNotification, object: nil)
        }

        @objc private func sceneWillDeactivate() {
            saveCurrentPosition()
        }

        // MARK: Full layout

        /// Lays out the whole document so every line's height is exact. Restarts when the text
        /// or the width changes.
        func layOutWholeDocument(_ textView: UITextView) {
            cancelLayout()
            guard textView.bounds.width > 0 else { return }  // runs again once the width is known

            let layoutManager = textView.layoutManager
            let length = textView.textStorage.length
            let firstSliceEnd = layoutSlice(layoutManager, from: 0, length: length)
            textView.setNeedsLayout()
            guard firstSliceEnd < length else {
                restorePendingPosition(in: textView)
                return
            }

            layoutTask = Task { [weak self, weak textView] in
                var location = firstSliceEnd
                while location < length {
                    try? await Task.sleep(for: .milliseconds(1))
                    guard let self, let textView, !Task.isCancelled else { return }
                    location = self.layoutSlice(layoutManager, from: location, length: length)
                    textView.setNeedsLayout()
                }
                guard let self, let textView, !Task.isCancelled else { return }
                self.restorePendingPosition(in: textView)
            }
        }

        func widthDidChange(_ textView: UITextView) {
            if pendingRestore == nil { pendingRestore = lastPosition }
            layOutWholeDocument(textView)
        }

        /// Lays out one slice and returns where the next one starts.
        private func layoutSlice(_ layoutManager: NSLayoutManager, from location: Int, length: Int) -> Int {
            let end = min(location + charactersPerSlice, length)
            layoutManager.ensureLayout(forCharacterRange: NSRange(location: location, length: end - location))
            return end
        }

        func cancelLayout() {
            layoutTask?.cancel()
            layoutTask = nil
        }

        // MARK: Reading position

        func saveCurrentPosition() {
            guard pendingRestore == nil,  // not restored yet: keep what was saved
                  let textView, let documentURL,
                  let position = currentPosition(in: textView)
            else { return }
            lastPosition = position
            positionStore.save(position, for: documentURL)
        }

        /// The line at the top of the visible area (below the status bar) and how far it is scrolled.
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

        private func restorePendingPosition(in textView: UITextView) {
            guard let position = pendingRestore else { return }
            pendingRestore = nil
            lastPosition = position

            let inset = textView.adjustedContentInset
            let length = textView.textStorage.length
            var offsetY = -inset.top
            if position != .top, length > 0 {
                let layoutManager = textView.layoutManager
                let glyphIndex = layoutManager.glyphIndexForCharacter(at: min(position.characterIndex, length - 1))
                let lineRect = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
                let y = lineRect.minY + min(CGFloat(position.lineOffset), lineRect.height)
                offsetY = y + textView.textContainerInset.top - inset.top
            }
            // Clamp with the laid-out height; contentSize may not have caught up within this pass.
            let contentHeight = textView.layoutManager.usedRect(for: textView.textContainer).height
                + textView.textContainerInset.top + textView.textContainerInset.bottom
            let maxY = max(-inset.top, contentHeight - textView.bounds.height + inset.bottom)
            textView.contentOffset.y = min(max(offsetY, -inset.top), maxY)
        }

        @objc func handleRefresh(_ control: UIRefreshControl) {
            Task {
                await onRefresh?()
                control.endRefreshing()
            }
        }

        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            barTracker.beginDrag(at: scrollView.contentOffset.y)
            pendingRestore = nil  // the reader took over before a big file finished laying out
        }

        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            if !decelerate { saveCurrentPosition() }
        }

        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
            saveCurrentPosition()
        }

        func scrollViewDidScrollToTop(_ scrollView: UIScrollView) {
            saveCurrentPosition()
        }

        func textView(_ textView: UITextView, editMenuForTextIn range: NSRange,
                      suggestedActions: [UIMenuElement]) -> UIMenu? {
            let extra = RawTextStyle.commentItems(for: range, onComment: onComment)
                + RawTextStyle.jumpToDefinitionItems(for: range, in: textView,
                                                     searchTerm: symbolSearchTerm,
                                                     onSearch: onSearchSymbols)
            return RawTextStyle.editMenu(from: suggestedActions, adding: extra)
        }

        // MARK: Show in File

        var lastScrollRequestID: UUID?

        /// Puts the line with `characterIndex` at the top of the screen and remembers it as the
        /// reading position.
        func scroll(toCharacter characterIndex: Int, in textView: UITextView) {
            pendingRestore = ReadingPosition(characterIndex: characterIndex, lineOffset: 0)
            restorePendingPosition(in: textView)
            saveCurrentPosition()
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            let inset = scrollView.adjustedContentInset
            let change = barTracker.scrolled(
                to: scrollView.contentOffset.y,
                top: -inset.top,
                bottom: scrollView.contentSize.height - scrollView.bounds.height + inset.bottom,
                isUserScrolling: scrollView.isDragging || scrollView.isDecelerating
            )
            if let change { onBarCollapsedChange?(change) }
        }
    }
}

/// A request to scroll File to a place, such as the start of a symbol (Show in File). A new
/// request (a new `id`) scrolls again, even to the same place.
nonisolated struct FileScrollRequest: Equatable, Sendable {
    let id = UUID()
    let characterIndex: Int
}

/// A `UITextView` that reports width changes, since wrapped text must then be laid out again.
final class CodeUITextView: UITextView {
    var onWidthChange: (@MainActor (CodeUITextView) -> Void)?
    private var lastWidth: CGFloat = 0

    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds.width != lastWidth {
            lastWidth = bounds.width
            onWidthChange?(self)
        }
    }
}
