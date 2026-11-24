import SwiftUI
import UIKit

/// One section of the Code level's list: a symbol's (its title, pinned while its code scrolls
/// under it, then its code), or a folder's header in the grouped view (a row, no title).
struct CodeTableSection: Equatable {
    /// The symbol's id, or a folder header's (negative).
    let id: Int
    /// A title that sticks to the top while the section scrolls.
    let hasHeader: Bool
    /// A row under it: a symbol's code, a file's whole text, or a folder's header.
    let hasRow: Bool
}

/// Bring a section to the top. A new request (a new `token`) scrolls again, even to the same one.
struct CodeTableScrollRequest: Equatable {
    let id: Int
    let token = UUID()

    init(_ id: Int) {
        self.id = id
    }
}

/// What was held: a section's title (its header), or its row.
enum CodeTableMenuPart {
    case title, row
}

/// A touch-and-hold menu, made as it opens, and its preview (`nil`: the cell itself, lifted).
struct CodeTableMenu {
    let menu: UIMenu
    let preview: (@MainActor () -> UIViewController)?
    /// A tap on the preview (a symbol's: its card opens, as Open does). `nil`: it just closes.
    var onPreviewTap: (@MainActor () -> Void)? = nil
}

/// Where the list is, for the bar collapsing as it scrolls (see `BarCollapseTracker`).
struct CodeTableScroll {
    let offset: CGFloat
    let top: CGFloat
    let bottom: CGFloat
    let isUserScrolling: Bool
    let isCoasting: Bool
    let contentHeight: CGFloat
}

/// The Code level's list in UIKit: a table whose section headers stick to the top, each title
/// and row still a SwiftUI view (`UIHostingConfiguration`). Only the rows on screen are ever
/// made, and a cell scrolled off is used again for the next one, so a new list (another album,
/// the project after an album) is quick to show: SwiftUI's lazy stack set up and measured every
/// row on screen at once, half a second for a new album. Everything around the list (the peek,
/// the pinch, the bar) stays SwiftUI.
struct CodeTable: UIViewRepresentable {
    let sections: [CodeTableSection]
    /// A section's title and row, with what they need from the environment (a table's cells
    /// don't get the SwiftUI environment around it).
    let header: @MainActor (Int) -> AnyView
    let row: @MainActor (Int) -> AnyView
    /// A row with nothing to show now (a collapsed symbol's code): no height.
    let isRowEmpty: @MainActor (Int) -> Bool
    /// A section's title's or row's touch-and-hold menu, asked for only as it opens (SwiftUI's,
    /// on each row, was all made every time a row was drawn).
    let menu: @MainActor (Int, CodeTableMenuPart) -> CodeTableMenu?
    /// About how tall a row and a title will be, before they're made.
    let estimatedRowHeight: @MainActor (Int) -> CGFloat
    let estimatedHeaderHeight: @MainActor (Int) -> CGFloat
    /// Where the list starts, asked once (`nil`: the top).
    let initialID: @MainActor () -> Int?
    let scrollRequest: CodeTableScrollRequest?
    let isScrollEnabled: Bool
    /// Only the list on screen answers a tap on the status bar.
    let scrollsToTop: Bool
    /// Room at the end for the bar.
    let bottomInset: CGFloat
    /// The section at the top changed (reported once the list is where it starts).
    let onTopSectionChange: @MainActor (Int) -> Void
    /// The list moved to where it starts: later top sections are the reader's.
    let onPositioned: @MainActor () -> Void
    let onScroll: @MainActor (CodeTableScroll) -> Void
    let onBeginDragging: @MainActor (CGFloat) -> Void
    let onScrollingChange: (@MainActor (Bool) -> Void)?
    /// Reads what rows' heights depend on (what's collapsed): when it changes, the rows on
    /// screen take their new heights, animated (a collapsed row has none, so it isn't drawn to
    /// tell the table itself).
    let observeHeights: @MainActor () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITableView {
        let table = UITableView(frame: .zero, style: .plain)
        table.backgroundColor = .clear
        table.separatorStyle = .none
        table.allowsSelection = false
        table.sectionHeaderTopPadding = 0
        table.sectionFooterHeight = 0
        table.estimatedSectionFooterHeight = 0
        table.estimatedRowHeight = 120
        table.estimatedSectionHeaderHeight = SymbolTitleHeight.symbol
        // A row's SwiftUI content growing (its code laid out) resizes it.
        table.selfSizingInvalidation = .enabledIncludingConstraints
        table.register(UITableViewCell.self, forCellReuseIdentifier: Coordinator.cellID)
        table.register(CodeTableHeaderView.self, forHeaderFooterViewReuseIdentifier: Coordinator.headerID)
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        context.coordinator.table = table
        context.coordinator.trackHeights()
        return table
    }

    func updateUIView(_ table: UITableView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        table.isScrollEnabled = isScrollEnabled
        table.scrollsToTop = scrollsToTop
        if table.contentInset.bottom != bottomInset { table.contentInset.bottom = bottomInset }
        coordinator.update(sections)
        if let scrollRequest, scrollRequest != coordinator.lastScrollRequest {
            coordinator.lastScrollRequest = scrollRequest
            coordinator.scroll(to: scrollRequest.id)
        }
    }

    @MainActor
    final class Coordinator: NSObject, UITableViewDataSource, UITableViewDelegate, UIContextMenuInteractionDelegate {
        static let cellID = "row"
        static let headerID = "title"

        var parent: CodeTable
        weak var table: UITableView?
        private var sections: [CodeTableSection] = []
        private var indexByID: [Int: Int] = [:]
        var lastScrollRequest: CodeTableScrollRequest?
        /// Moved to where it starts (after its first layout).
        private var isPositioned = false
        private var topID: Int?

        init(_ parent: CodeTable) {
            self.parent = parent
        }

        // MARK: Contents

        /// New sections: the table shows them (keeping the section at the top where it was on
        /// screen), and the titles and rows on screen take what the list has now.
        func update(_ new: [CodeTableSection]) {
            guard let table else { return }
            guard new != sections else {
                refreshVisible()
                return
            }
            // Nothing yet (its symbols still coming): it starts once there's something.
            let isFirst = !isPositioned && !new.isEmpty
            let anchor = isPositioned ? topAnchor() : nil
            sections = new
            indexByID = Dictionary(new.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
            table.reloadData()
            if isFirst {
                // The first time: at the saved place, once the table has its size.
                let start = parent.initialID()
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    if let start { self.scroll(to: start) }
                    self.isPositioned = true
                    self.parent.onPositioned()
                    self.reportTop()
                }
            } else if let anchor {
                restore(anchor)
            }
        }

        /// The titles and rows on screen, made again from the list's current state (a file
        /// downloading, a new theme): the table has the same sections.
        private func refreshVisible() {
            guard let table else { return }
            for indexPath in table.indexPathsForVisibleRows ?? [] {
                guard let cell = table.cellForRow(at: indexPath), sections.indices.contains(indexPath.section)
                else { continue }
                configure(cell, id: sections[indexPath.section].id)
            }
            // Only the sections on screen (a big project has tens of thousands).
            for index in visibleSections() where sections[index].hasHeader {
                guard let header = table.headerView(forSection: index) else { continue }
                configure(header, id: sections[index].id)
            }
        }

        /// The sections on screen, from the one at the top to the one at the bottom.
        private func visibleSections() -> [Int] {
            guard let table, let first = topIndex() else { return [] }
            let bottom = table.contentOffset.y + table.bounds.height
            var last = first
            while last + 1 < sections.count, table.rect(forSection: last + 1).minY < bottom { last += 1 }
            return Array(first...last)
        }

        private func configure(_ cell: UITableViewCell, id: Int) {
            cell.contentConfiguration = UIHostingConfiguration { parent.row(id) }
                .margins(.all, 0)
                .minSize(width: 0, height: 0)
        }

        private func configure(_ header: UITableViewHeaderFooterView, id: Int) {
            header.contentConfiguration = UIHostingConfiguration { parent.header(id) }
                .margins(.all, 0)
                .minSize(width: 0, height: 0)
        }

        func numberOfSections(in tableView: UITableView) -> Int {
            sections.count
        }

        func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
            sections.indices.contains(section) && sections[section].hasRow ? 1 : 0
        }

        func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
            let cell = tableView.dequeueReusableCell(withIdentifier: Self.cellID, for: indexPath)
            cell.backgroundConfiguration = .clear()
            cell.selectionStyle = .none
            configure(cell, id: sections[indexPath.section].id)
            if isAnimatingHeights { madeWhileAnimating.append(cell.contentView) }
            return cell
        }

        func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
            guard sections.indices.contains(section), sections[section].hasHeader,
                  let header = tableView.dequeueReusableHeaderFooterView(withIdentifier: Self.headerID) as? CodeTableHeaderView
            else { return nil }
            header.backgroundConfiguration = .clear()
            header.sectionID = sections[section].id
            if !header.hasMenu {
                header.addInteraction(UIContextMenuInteraction(delegate: self))
                header.hasMenu = true
            }
            configure(header, id: sections[section].id)
            if isAnimatingHeights { madeWhileAnimating.append(header.contentView) }
            return header
        }

        // MARK: Menus

        /// A row held: its menu, made now.
        func tableView(_ tableView: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath,
                       point: CGPoint) -> UIContextMenuConfiguration? {
            guard sections.indices.contains(indexPath.section),
                  let made = parent.menu(sections[indexPath.section].id, .row)
            else { return nil }
            return configuration(made)
        }

        /// A title held (headers aren't rows: each has its own interaction).
        func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                    configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
            guard let header = interaction.view as? CodeTableHeaderView,
                  let made = parent.menu(header.sectionID, .title)
            else { return nil }
            return configuration(made)
        }

        private func configuration(_ made: CodeTableMenu) -> UIContextMenuConfiguration {
            let preview = made.preview
            let menu = made.menu
            previewTap = made.onPreviewTap
            return UIContextMenuConfiguration(identifier: nil,
                                              previewProvider: preview.map { make in { MainActor.assumeIsolated { make() } } },
                                              actionProvider: { _ in menu })
        }

        /// The open menu's preview tap.
        private var previewTap: (@MainActor () -> Void)?

        /// The preview tapped (a row's): the menu closes, then what it opens.
        func tableView(_ tableView: UITableView,
                       willPerformPreviewActionForMenuWith configuration: UIContextMenuConfiguration,
                       animator: any UIContextMenuInteractionCommitAnimating) {
            commitPreview(animator)
        }

        /// The preview tapped (a title's).
        func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                    willPerformPreviewActionForMenuWith configuration: UIContextMenuConfiguration,
                                    animator: any UIContextMenuInteractionCommitAnimating) {
            commitPreview(animator)
        }

        private func commitPreview(_ animator: any UIContextMenuInteractionCommitAnimating) {
            guard let tap = previewTap else { return }
            animator.preferredCommitStyle = .dismiss
            animator.addCompletion { tap() }
        }

        func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
            sections.indices.contains(section) && sections[section].hasHeader ? UITableView.automaticDimension : 0
        }

        func tableView(_ tableView: UITableView, estimatedHeightForHeaderInSection section: Int) -> CGFloat {
            guard sections.indices.contains(section), sections[section].hasHeader else { return 0 }
            return parent.estimatedHeaderHeight(sections[section].id)
        }

        func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
            guard sections.indices.contains(indexPath.section) else { return 0 }
            return parent.isRowEmpty(sections[indexPath.section].id) ? 0 : UITableView.automaticDimension
        }

        func tableView(_ tableView: UITableView, estimatedHeightForRowAt indexPath: IndexPath) -> CGFloat {
            guard sections.indices.contains(indexPath.section) else { return 0 }
            let id = sections[indexPath.section].id
            return parent.isRowEmpty(id) ? 0 : parent.estimatedRowHeight(id)
        }

        func tableView(_ tableView: UITableView, heightForFooterInSection section: Int) -> CGFloat {
            0
        }

        func tableView(_ tableView: UITableView, viewForFooterInSection section: Int) -> UIView? {
            nil
        }

        /// While the heights change (in their animation): the cells and titles made meanwhile
        /// (`madeWhileAnimating`, their content).
        private var isAnimatingHeights = false
        private var madeWhileAnimating: [UIView] = []

        /// A cell made in the heights' animation (a symbol just opened: its row, 0 high, had no
        /// cell) had its content laid out in it, from where a new view starts: its code flew in
        /// from the top left corner. Its content doesn't animate; the cell itself still moves
        /// with the others.
        private func stopInnerAnimations() {
            let made = madeWhileAnimating
            madeWhileAnimating = []
            func stop(_ layer: CALayer) {
                layer.removeAllAnimations()
                layer.sublayers?.forEach(stop)
            }
            for view in made { stop(view.layer) }
        }

        /// Heights follow what's collapsed: each change takes the rows' new heights (animated, as
        /// SwiftUI's own list did), then watches again.
        func trackHeights() {
            withObservationTracking {
                parent.observeHeights()
            } onChange: { [weak self] in
                Task { @MainActor in
                    guard let self, let table = self.table else { return }
                    self.isAnimatingHeights = true
                    // SwiftUI's `.smooth(duration: 0.25)` (a spring without bounce), as the
                    // title's chevron and the code's fade go: UIKit's own ease in and out
                    // felt different.
                    UIView.animate(springDuration: 0.25, bounce: 0) {
                        table.performBatchUpdates(nil)
                    }
                    self.isAnimatingHeights = false
                    self.stopInnerAnimations()
                    self.trackHeights()
                }
            }
        }

        // MARK: Places

        /// The section at the top of the screen: the last one starting above it.
        private func topIndex() -> Int? {
            guard let table, !sections.isEmpty else { return nil }
            let y = table.contentOffset.y + table.adjustedContentInset.top + 1
            var low = 0, high = sections.count - 1
            while low < high {
                let middle = (low + high + 1) / 2
                if table.rect(forSection: middle).minY <= y { low = middle } else { high = middle - 1 }
            }
            return low
        }

        /// The section at the top and how far its start is above the top of the screen.
        private func topAnchor() -> (id: Int, offset: CGFloat)? {
            guard let table, let index = topIndex() else { return nil }
            let top = table.contentOffset.y + table.adjustedContentInset.top
            return (sections[index].id, top - table.rect(forSection: index).minY)
        }

        /// That section back where it was on screen, after the table's heights were worked out
        /// again (reloading forgets them, and the estimates above it moved it).
        private func restore(_ anchor: (id: Int, offset: CGFloat)) {
            guard let table, let index = indexByID[anchor.id] else { return }
            table.layoutIfNeeded()
            for _ in 0..<2 {
                let y = table.rect(forSection: index).minY + anchor.offset - table.adjustedContentInset.top
                table.setContentOffset(CGPoint(x: 0, y: clamped(y)), animated: false)
                table.layoutIfNeeded()  // the rows it lands on measured: their real heights
            }
        }

        /// A section at the top. Twice: the first jump measures the rows it lands on, which moves
        /// the section from its estimated place.
        func scroll(to id: Int) {
            guard let table, let index = indexByID[id] else { return }
            table.layoutIfNeeded()
            for _ in 0..<2 {
                let y = table.rect(forSection: index).minY - table.adjustedContentInset.top
                table.setContentOffset(CGPoint(x: 0, y: clamped(y)), animated: false)
                table.layoutIfNeeded()
            }
        }

        private func clamped(_ y: CGFloat) -> CGFloat {
            guard let table else { return y }
            let top = -table.adjustedContentInset.top
            let bottom = max(top, table.contentSize.height - table.bounds.height + table.adjustedContentInset.bottom)
            return min(max(y, top), bottom)
        }

        private func reportTop() {
            guard isPositioned, let index = topIndex() else { return }
            let id = sections[index].id
            guard id != topID else { return }
            topID = id
            parent.onTopSectionChange(id)
        }

        // MARK: Scrolling

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            let inset = scrollView.adjustedContentInset
            parent.onScroll(CodeTableScroll(
                offset: scrollView.contentOffset.y,
                top: -inset.top,
                bottom: scrollView.contentSize.height - scrollView.bounds.height + inset.bottom,
                isUserScrolling: scrollView.isTracking || scrollView.isDecelerating,
                isCoasting: scrollView.isDecelerating,
                contentHeight: scrollView.contentSize.height
            ))
            reportTop()
        }

        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            parent.onScrollingChange?(true)
            parent.onBeginDragging(scrollView.contentOffset.y)
        }

        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            if !decelerate { parent.onScrollingChange?(false) }
        }

        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
            parent.onScrollingChange?(false)
        }

        func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
            parent.onScrollingChange?(false)
        }

        func scrollViewDidScrollToTop(_ scrollView: UIScrollView) {
            parent.onScrollingChange?(false)
        }
    }
}

/// Titles' heights before they're made, for the table's estimates.
enum SymbolTitleHeight {
    static let symbol: CGFloat = 28
    static let file: CGFloat = 44
}

/// A title's view in the table, knowing its section (for its menu).
final class CodeTableHeaderView: UITableViewHeaderFooterView {
    var sectionID = 0
    var hasMenu = false
}
