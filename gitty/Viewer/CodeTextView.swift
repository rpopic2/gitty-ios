import SwiftUI
import UIKit

/// Read-only, selectable raw text in a TextKit 2 `UITextView`.
///
/// For smooth scrolling:
/// - TextKit 2 shows the first screen right away. The rest of the file is then laid out in small
///   slices between frames, so the scroll indicator and content height are exact (as in Safari)
///   instead of estimates that jump the first time you reach new text.
/// - `textView.layoutManager` is never read: reading it switches the view to TextKit 1 for good.
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
        let textView = CodeUITextView(usingTextLayoutManager: true)
        textView.isEditable = false
        textView.isSelectable = true
        textView.dataDetectorTypes = []
        textView.adjustsFontForContentSizeCategory = false
        textView.backgroundColor = RawTextStyle.backgroundColor
        textView.textContainerInset = RawTextStyle.insets
        textView.textContainer.lineFragmentPadding = 0
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

        assert(textView.textLayoutManager != nil, "UITextView fell back to TextKit 1")
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

        /// Paragraphs (source lines) laid out per slice: a few ms each, well under one frame.
        private let paragraphsPerSlice = 200
        /// Above this many characters, keep TextKit 2's estimates rather than laying out everything.
        private let fullLayoutCharacterLimit = 2_000_000
        private var layoutTask: Task<Void, Never>?

        // MARK: Full layout

        /// Lays out the whole document in slices, yielding to the run loop between them so
        /// scrolling and animations never wait. Restarts when the text or the width changes.
        func layOutWholeDocument(_ textView: UITextView) {
            cancelLayout()
            guard textView.bounds.width > 0,
                  textView.textStorage.length <= fullLayoutCharacterLimit,
                  let layoutManager = textView.textLayoutManager
            else { return }

            let paragraphsPerSlice = paragraphsPerSlice
            layoutTask = Task { [weak textView] in
                var next: NSTextLocation? = layoutManager.documentRange.location
                while let start = next, !Task.isCancelled {
                    var count = 0
                    var sliceEnd: NSTextLocation?
                    layoutManager.enumerateTextLayoutFragments(from: start, options: [.ensuresLayout]) { fragment in
                        sliceEnd = fragment.rangeInElement.endLocation
                        count += 1
                        return count < paragraphsPerSlice
                    }
                    // Fewer fragments than asked for means the end of the document was reached.
                    next = count < paragraphsPerSlice ? nil : sliceEnd
                    if next != nil {
                        try? await Task.sleep(for: .milliseconds(1))
                    }
                }
                guard !Task.isCancelled, let textView else { return }
                // Let the text view pick up the exact height.
                layoutManager.textViewportLayoutController.layoutViewport()
                textView.setNeedsLayout()
            }
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
