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
struct CodeTextView: UIViewRepresentable {
    let text: RenderedText
    let version: UUID
    /// Space kept free under the text for the expanded bottom bar, above the home indicator.
    let bottomBarHeight: CGFloat
    let isBarCollapsed: Bool
    let onRefresh: @MainActor () async -> Void
    let onBarCollapsedChange: @MainActor (Bool) -> Void

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
            coordinator?.layOutWholeDocument(textView)
        }
        return textView
    }

    func updateUIView(_ textView: CodeUITextView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onRefresh = onRefresh
        coordinator.onBarCollapsedChange = onBarCollapsedChange
        coordinator.isBarCollapsed = isBarCollapsed

        if textView.contentInset.bottom != bottomBarHeight {
            textView.contentInset.bottom = bottomBarHeight
            textView.verticalScrollIndicatorInsets.bottom = bottomBarHeight
        }

        if coordinator.version != version {
            let isReplacing = coordinator.version != nil
            let offset = textView.contentOffset
            coordinator.version = version
            textView.attributedText = text.attributedString
            if isReplacing {
                // Keep the reading position after a refresh brings new text.
                let inset = textView.adjustedContentInset
                let maxY = max(-inset.top, textView.contentSize.height - textView.bounds.height + inset.bottom)
                textView.contentOffset.y = min(max(offset.y, -inset.top), maxY)
            }
            coordinator.layOutWholeDocument(textView)
        }
    }

    static func dismantleUIView(_ textView: CodeUITextView, coordinator: Coordinator) {
        coordinator.cancelLayout()
    }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate {
        var version: UUID?
        var onRefresh: (@MainActor () async -> Void)?
        var onBarCollapsedChange: (@MainActor (Bool) -> Void)?
        var isBarCollapsed = false

        /// How far (pt) the user must scroll in one direction before the bar changes.
        private let collapseThreshold: CGFloat = 10
        private var lastOffsetY: CGFloat = 0
        private var accumulated: CGFloat = 0

        /// Characters laid out per slice. Most source files fit in one slice, so they are fully
        /// laid out before the first frame; bigger files finish over the next few frames.
        private let charactersPerSlice = 100_000
        private var layoutTask: Task<Void, Never>?

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
            guard firstSliceEnd < length else { return }

            layoutTask = Task { [weak self, weak textView] in
                var location = firstSliceEnd
                while location < length {
                    try? await Task.sleep(for: .milliseconds(1))
                    guard let self, let textView, !Task.isCancelled else { return }
                    location = self.layoutSlice(layoutManager, from: location, length: length)
                    textView.setNeedsLayout()
                }
            }
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

        @objc func handleRefresh(_ control: UIRefreshControl) {
            Task {
                await onRefresh?()
                control.endRefreshing()
            }
        }

        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            lastOffsetY = scrollView.contentOffset.y
            accumulated = 0
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
            guard scrollView.isDragging || scrollView.isDecelerating, delta != 0 else { return }

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
