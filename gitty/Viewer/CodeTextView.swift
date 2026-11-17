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
///
/// The reading position is saved per file when scrolling stops and when the app goes to the
/// background, and restored the next time the file opens.
/// - Scrolling reports to SwiftUI only when the bar's collapsed state flips, never per frame.
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
    var positionStore: ReadingPositionStore = .standard

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> CodeUITextView {
        let textView = CodeUITextView(usingTextLayoutManager: false)
        textView.isEditable = false
        textView.isSelectable = true
        textView.dataDetectorTypes = []
        textView.adjustsFontForContentSizeCategory = false
        textView.backgroundColor = RawTextStyle.backgroundColor
        textView.textContainerInset = RawTextStyle.insets
        textView.textContainer.lineFragmentPadding = 0
        // Exact heights everywhere: no estimated regions to fix up while scrolling.
        textView.layoutManager.allowsNonContiguousLayout = false
        textView.alwaysBounceVertical = true
        textView.showsHorizontalScrollIndicator = false
        textView.contentInsetAdjustmentBehavior = .automatic
        textView.scrollsToTop = true
        textView.delegate = context.coordinator
        context.coordinator.textView = textView

        if #available(iOS 26.0, *) {
            // Soft blur under the status bar, like Safari 26.
            textView.topEdgeEffect.style = .soft
        }

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
        coordinator.isBarCollapsed = isBarCollapsed
        if coordinator.barTapCount != barTapCount {
            coordinator.barTapCount = barTapCount
            coordinator.barWasTappedOpen()
        }
        coordinator.documentURL = documentURL
        coordinator.positionStore = positionStore

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
        var isBarCollapsed = false
        var barTapCount = 0
        /// After the reader taps the bar open, it stays open until they start a new drag.
        private var holdsBarOpen = false

        /// How far (pt) the user must scroll in one direction before the bar changes.
        private let collapseThreshold: CGFloat = 10
        private var lastOffsetY: CGFloat = 0
        private var accumulated: CGFloat = 0

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
            lastOffsetY = scrollView.contentOffset.y
            accumulated = 0
            pendingRestore = nil  // the reader took over before a big file finished laying out
            holdsBarOpen = false
        }

        /// Like Safari: tapping the bar during a fling keeps the bar open while the fling carries on.
        /// Without this, the remaining momentum counts as scrolling down and collapses it again.
        func barWasTappedOpen() {
            holdsBarOpen = true
            accumulated = 0
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

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            let y = scrollView.contentOffset.y
            let delta = y - lastOffsetY
            lastOffsetY = y

            let inset = scrollView.adjustedContentInset
            let topY = -inset.top
            let bottomY = scrollView.contentSize.height - scrollView.bounds.height + inset.bottom

            // Like Safari: the bar is always expanded at the top and at the end of the page.
            if y <= topY + 1 || y >= bottomY - 1 {
                setCollapsed(false)
                return
            }
            guard !holdsBarOpen, scrollView.isDragging || scrollView.isDecelerating, delta != 0 else { return }

            if (delta > 0) != (accumulated > 0) { accumulated = 0 }  // direction changed
            accumulated += delta
            if accumulated > collapseThreshold {
                setCollapsed(true)
            } else if accumulated < -collapseThreshold {
                setCollapsed(false)
            }
        }

        private func setCollapsed(_ collapsed: Bool) {
            guard collapsed != isBarCollapsed else { return }
            isBarCollapsed = collapsed
            onBarCollapsedChange?(collapsed)
        }
    }
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
