import SwiftUI
import UIKit

/// Read-only, selectable raw text in a TextKit 2 `UITextView`.
///
/// For smooth scrolling:
/// - TextKit 2 lays out only what is on screen, so file size barely matters.
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

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView(usingTextLayoutManager: true)
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

        assert(textView.textLayoutManager != nil, "UITextView fell back to TextKit 1")
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
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
        }
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
