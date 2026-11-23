import SwiftUI
import UIKit

/// Sizes for the bottom bar. Tune them against Safari screenshots on a device.
enum FileBarMetrics {
    // iOS 26+: floating Liquid Glass capsule.
    static let glassHeight: CGFloat = 48
    static let glassCollapsedHeight: CGFloat = 30
    static let glassHorizontalMargin: CGFloat = 20
    static let glassBottomPadding: CGFloat = 4
    static let glassGapAboveCapsule: CGFloat = 8

    // iOS 18: rounded field in a full-width material bar.
    static let fieldHeight: CGFloat = 44
    static let fieldCollapsedHeight: CGFloat = 24
    static let fieldCornerRadius: CGFloat = 12
    static let fieldHorizontalMargin: CGFloat = 12
    static let barVerticalPadding: CGFloat = 8


    static let titleFont = Font.system(size: 17)
    static let collapsedTitleFont = Font.system(size: 12)
    static let progressHeight: CGFloat = 3

    /// Height of the expanded bar alone, above the bottom safe area.
    static var barHeight: CGFloat {
        if #available(iOS 26.0, *) {
            return glassGapAboveCapsule + glassHeight + glassBottomPadding
        } else {
            return fieldHeight + 2 * barVerticalPadding
        }
    }

    /// Height of the expanded bar, above the bottom safe area. Content keeps this much free at
    /// its end, and never changes it, so nothing jumps when the bar collapses.
    static var expandedHeight: CGFloat {
        barHeight
    }
}

/// Safari-style bottom bar that shows only the file name, with Safari's loading line.
/// It looks like the Safari of the iOS version it runs on.
/// Tapping it expands it when collapsed, and starts editing the address when expanded.
struct FileBar: View {
    /// Empty shows the "Enter URL" placeholder (start page).
    let title: String
    let isCollapsed: Bool
    let progressFraction: Double
    let isProgressVisible: Bool
    let onExpand: @MainActor () -> Void
    let onEdit: @MainActor () -> Void
    /// Long-press menu, like Safari's: copy the current URL…
    let copyText: String?
    /// …and Paste and Go.
    let onPasteAndGo: (@MainActor () -> Void)?
    /// Only for web pages.
    let onOpenInBrowser: (@MainActor () -> Void)?
    /// In Symbols mode: the symbol search (empty when there's none, `nil` in other modes). A
    /// non-empty search is shown instead of the title, with a clear button.
    let searchQuery: String?
    let onClearSearch: (@MainActor () -> Void)?
    /// At the Code level: Collapse All and Expand All in the menu.
    let onCollapseAll: (@MainActor () -> Void)?
    let onExpandAll: (@MainActor () -> Void)?
    /// In an album: Delete Album in the menu (`nil`: the whole project, which can't be).
    let onDeleteAlbum: (@MainActor () -> Void)?
    /// Before the title: an album's icon while one shows.
    let titleIcon: String?

    // An explicit init (not the memberwise one) so passing in an existing `@MainActor` closure
    // doesn't warn about converting it to `@Sendable`.
    init(title: String, isCollapsed: Bool, progressFraction: Double, isProgressVisible: Bool,
         onExpand: @escaping @MainActor () -> Void, onEdit: @escaping @MainActor () -> Void,
         copyText: String? = nil, onPasteAndGo: (@MainActor () -> Void)? = nil,
         onOpenInBrowser: (@MainActor () -> Void)? = nil,
         searchQuery: String? = nil, onClearSearch: (@MainActor () -> Void)? = nil,
         onCollapseAll: (@MainActor () -> Void)? = nil, onExpandAll: (@MainActor () -> Void)? = nil,
         onDeleteAlbum: (@MainActor () -> Void)? = nil,
         titleIcon: String? = nil) {
        self.title = title
        self.titleIcon = titleIcon
        self.isCollapsed = isCollapsed
        self.progressFraction = progressFraction
        self.isProgressVisible = isProgressVisible
        self.onExpand = onExpand
        self.onEdit = onEdit
        self.copyText = copyText
        self.onPasteAndGo = onPasteAndGo
        self.onOpenInBrowser = onOpenInBrowser
        self.searchQuery = searchQuery
        self.onClearSearch = onClearSearch
        self.onCollapseAll = onCollapseAll
        self.onExpandAll = onExpandAll
        self.onDeleteAlbum = onDeleteAlbum
    }

    private var activeSearch: String? {
        guard let searchQuery, !searchQuery.isEmpty else { return nil }
        return searchQuery
    }

    private var clearButton: ClearSearchButton? {
        guard activeSearch != nil, !isCollapsed, let onClearSearch else { return nil }
        return ClearSearchButton(action: onClearSearch)
    }

    private var accessibilityTitle: Text {
        if let activeSearch { return Text("Search: \(activeSearch)") }
        return title.isEmpty ? Text("Enter URL") : Text(title)
    }

    private var accessibilityEditHint: Text {
        if isCollapsed { return Text("Shows the bar") }
        return searchQuery == nil ? Text("Edits the address") : Text("Searches symbols")
    }

    private func tap() {
        if isCollapsed { onExpand() } else { onEdit() }
    }

    var body: some View {
        Group {
            if #available(iOS 26.0, *) {
                GlassFileBar(title: title, titleIcon: titleIcon, search: activeSearch, isCollapsed: isCollapsed,
                             progress: ProgressLine(fraction: progressFraction, isVisible: isProgressVisible),
                             clearButton: clearButton)
            } else {
                ClassicFileBar(title: title, titleIcon: titleIcon, search: activeSearch, isCollapsed: isCollapsed,
                               progress: ProgressLine(fraction: progressFraction, isVisible: isProgressVisible),
                               clearButton: clearButton)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { tap() }
        .contextMenu {
            if let copyText {
                Button("Copy", systemImage: "doc.on.doc") {
                    UIPasteboard.general.string = copyText
                }
            }
            if let onPasteAndGo, Clipboard.hasAddress {
                Button("Paste and Go", systemImage: "doc.on.clipboard") { onPasteAndGo() }
            }
            if let onOpenInBrowser {
                Button("Open in Browser", systemImage: "safari") { onOpenInBrowser() }
            }
            if let onCollapseAll, let onExpandAll {
                Section {
                    Button("Collapse All", systemImage: "chevron.right.2") { onCollapseAll() }
                    Button("Expand All", systemImage: "chevron.down.2") { onExpandAll() }
                }
            }
            if let onDeleteAlbum {
                Section {
                    Button("Delete Album", systemImage: "trash", role: .destructive) { onDeleteAlbum() }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityTitle)
        .accessibilityValue(isProgressVisible ? Text("Loading") : Text(""))
        .accessibilityHint(accessibilityEditHint)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { tap() }
        .accessibilityActions {
            if activeSearch != nil, let onClearSearch {
                Button("Clear Search") { onClearSearch() }
            }
        }
    }
}

/// The file name, the "Enter URL" placeholder, or the active symbol search.
private struct BarTitle: View {
    let title: String
    /// Before the title (an album's icon while one shows).
    var icon: String? = nil
    let search: String?
    let isCollapsed: Bool

    private var font: Font {
        isCollapsed ? FileBarMetrics.collapsedTitleFont : FileBarMetrics.titleFont
    }

    var body: some View {
        if let search {
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                Text(search)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .font(font)
        } else {
            HStack(spacing: 5) {
                if let icon {
                    Image(systemName: icon)
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)
                }
                Text(title.isEmpty ? "Enter URL" : title)
                    .contentTransition(.interpolate)  // smooth size change between states
                    .foregroundStyle(title.isEmpty ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .font(font)
        }
    }
}

/// Clears the symbol search, at the trailing end of the bar.
private struct ClearSearchButton: View {
    let action: @MainActor () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.secondary)
                .frame(width: 36, height: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.trailing, 6)
    }
}

/// iOS 26+: Safari 26's floating glass capsule.
@available(iOS 26.0, *)
private struct GlassFileBar: View {
    let title: String
    let titleIcon: String?
    let search: String?
    let isCollapsed: Bool
    let progress: ProgressLine
    let clearButton: ClearSearchButton?

    var body: some View {
        BarTitle(title: title, icon: titleIcon, search: search, isCollapsed: isCollapsed)
            .padding(.horizontal, isCollapsed ? 14 : (clearButton == nil ? 20 : 44))
            .frame(maxWidth: isCollapsed ? nil : .infinity)
            .frame(height: isCollapsed ? FileBarMetrics.glassCollapsedHeight : FileBarMetrics.glassHeight)
            .overlay(alignment: .trailing) { clearButton }
            .overlay(alignment: .bottom) { progress }
            .clipShape(Capsule())
            .glassEffect(.regular.interactive(), in: Capsule())
            .padding(.horizontal, FileBarMetrics.glassHorizontalMargin)
            .padding(.bottom, FileBarMetrics.glassBottomPadding)
    }
}

/// iOS 18: Safari 18's rounded field. The toolbar material behind it is drawn by `BottomBarStack`.
private struct ClassicFileBar: View {
    let title: String
    let titleIcon: String?
    let search: String?
    let isCollapsed: Bool
    let progress: ProgressLine
    let clearButton: ClearSearchButton?

    private var field: RoundedRectangle {
        RoundedRectangle(cornerRadius: FileBarMetrics.fieldCornerRadius, style: .continuous)
    }

    var body: some View {
        BarTitle(title: title, icon: titleIcon, search: search, isCollapsed: isCollapsed)
            .padding(.horizontal, clearButton == nil ? 12 : 40)
            .frame(maxWidth: .infinity)
            .frame(height: isCollapsed ? FileBarMetrics.fieldCollapsedHeight : FileBarMetrics.fieldHeight)
            .overlay(alignment: .trailing) { clearButton }
            .background {
                field
                    .fill(Color(uiColor: .tertiarySystemFill))
                    .opacity(isCollapsed ? 0 : 1)
            }
            .overlay(alignment: .bottom) { progress }
            .clipShape(field)
            .padding(.horizontal, FileBarMetrics.fieldHorizontalMargin)
            .padding(.vertical, isCollapsed ? 0 : FileBarMetrics.barVerticalPadding)
            .frame(maxWidth: .infinity)
    }
}

/// Safari's thin loading line. Hidden whenever nothing is loading.
private struct ProgressLine: View {
    let fraction: Double
    let isVisible: Bool

    var body: some View {
        Rectangle()
            .fill(.tint)
            .frame(height: FileBarMetrics.progressHeight)
            // scaleEffect is drawn on the GPU and doesn't trigger layout while animating.
            .scaleEffect(x: min(max(fraction, 0), 1), y: 1, anchor: .leading)
            .opacity(isVisible ? 1 : 0)
            .allowsHitTesting(false)
    }
}

/// The bottom of the screen: the file bar, with a set-aside review docked above it.
struct BottomBarStack: View {
    let title: String
    let isCollapsed: Bool
    let progressFraction: Double
    let isProgressVisible: Bool
    let onExpand: @MainActor () -> Void
    let onEdit: @MainActor () -> Void
    let copyText: String?
    let onPasteAndGo: (@MainActor () -> Void)?
    let onOpenInBrowser: (@MainActor () -> Void)?
    let searchQuery: String?
    let onClearSearch: (@MainActor () -> Void)?
    let onCollapseAll: (@MainActor () -> Void)?
    let onExpandAll: (@MainActor () -> Void)?
    /// In an album: Delete Album in the menu (`nil`: the whole project, which can't be).
    let onDeleteAlbum: (@MainActor () -> Void)?
    /// Before the title: an album's icon while one shows.
    let titleIcon: String?
    /// Swiping the bar sideways switches albums, like Safari's tabs (`nil`: it doesn't).
    let swipe: BarSwipe?
    /// A review set aside shows above the bar, like a minimized Mail draft.
    @Environment(ReviewDraft.self) private var review: ReviewDraft?
    /// How far the bar is dragged sideways (its neighbours follow it).
    @State private var dragX: CGFloat = 0
    /// Decided on the drag's first move: sideways switches, anything else is left alone.
    @State private var isSwiping: Bool?
    @State private var barWidth: CGFloat = 0

    // An explicit init (not the memberwise one) so passing in an existing `@MainActor` closure
    // doesn't warn about converting it to `@Sendable`.
    init(title: String, isCollapsed: Bool, progressFraction: Double, isProgressVisible: Bool,
         onExpand: @escaping @MainActor () -> Void, onEdit: @escaping @MainActor () -> Void,
         copyText: String? = nil, onPasteAndGo: (@MainActor () -> Void)? = nil,
         onOpenInBrowser: (@MainActor () -> Void)? = nil,
         searchQuery: String? = nil, onClearSearch: (@MainActor () -> Void)? = nil,
         onCollapseAll: (@MainActor () -> Void)? = nil, onExpandAll: (@MainActor () -> Void)? = nil,
         onDeleteAlbum: (@MainActor () -> Void)? = nil,
         titleIcon: String? = nil, swipe: BarSwipe? = nil) {
        self.title = title
        self.titleIcon = titleIcon
        self.swipe = swipe
        self.isCollapsed = isCollapsed
        self.progressFraction = progressFraction
        self.isProgressVisible = isProgressVisible
        self.onExpand = onExpand
        self.onEdit = onEdit
        self.copyText = copyText
        self.onPasteAndGo = onPasteAndGo
        self.onOpenInBrowser = onOpenInBrowser
        self.searchQuery = searchQuery
        self.onClearSearch = onClearSearch
        self.onCollapseAll = onCollapseAll
        self.onExpandAll = onExpandAll
        self.onDeleteAlbum = onDeleteAlbum
    }

    var body: some View {
        let stack = VStack(spacing: 0) {
            if !isCollapsed, let review, review.isDocked {
                ReviewDock(draft: review)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            swipeable(FileBar(title: title, isCollapsed: isCollapsed, progressFraction: progressFraction,
                              isProgressVisible: isProgressVisible, onExpand: onExpand, onEdit: onEdit,
                              copyText: copyText, onPasteAndGo: onPasteAndGo, onOpenInBrowser: onOpenInBrowser,
                              searchQuery: searchQuery, onClearSearch: onClearSearch,
                              onCollapseAll: onCollapseAll, onExpandAll: onExpandAll,
                              onDeleteAlbum: onDeleteAlbum, titleIcon: titleIcon))
        }

        if #available(iOS 26.0, *) {
            stack
        } else {
            stack.background(.bar, ignoresSafeAreaEdges: .bottom)
        }
    }

    /// The bar, following a sideways drag with its neighbours' bars beside it, like Safari's
    /// tabs. Let go far enough (or flung) and the neighbour slides in; where there's none, the
    /// bar stretches a little and springs back.
    @ViewBuilder
    private func swipeable(_ bar: FileBar) -> some View {
        if let swipe, !isCollapsed {
            bar
                .offset(x: dragX)
                .background {
                    if dragX != 0 {
                        ZStack {
                            if let previous = swipe.previous { neighbour(previous).offset(x: dragX - barWidth) }
                            if let next = swipe.next { neighbour(next).offset(x: dragX + barWidth) }
                        }
                    }
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { barWidth = $0 }
                .simultaneousGesture(swipeGesture(swipe))
                .accessibilityActions {
                    if let previous = swipe.previous {
                        Button(String(localized: "Show \(previous.title)")) { swipe.onSwitch(false) }
                    }
                    if let next = swipe.next {
                        Button(String(localized: "Show \(next.title)")) { swipe.onSwitch(true) }
                    }
                }
        } else {
            bar
        }
    }

    private func neighbour(_ neighbour: BarSwipe.Neighbour) -> some View {
        FileBar(title: neighbour.title, isCollapsed: false, progressFraction: 0, isProgressVisible: false,
                onExpand: {}, onEdit: {}, titleIcon: neighbour.icon)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private func swipeGesture(_ swipe: BarSwipe) -> some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                let dx = value.translation.width, dy = value.translation.height
                if isSwiping == nil { isSwiping = abs(dx) > abs(dy) }
                guard isSwiping == true else { return }
                // Toward a side with nothing there: a little, and less the further it goes.
                let hasNeighbour = dx < 0 ? swipe.next != nil : swipe.previous != nil
                dragX = hasNeighbour ? dx : dx / (1 + abs(dx) / 60)
            }
            .onEnded { value in
                defer { isSwiping = nil }
                guard isSwiping == true else { return }
                let dx = value.translation.width
                let flung = value.predictedEndTranslation.width
                let forward = dx < 0
                let hasNeighbour = forward ? swipe.next != nil : swipe.previous != nil
                let width = max(barWidth, 1)
                let farEnough = abs(dx) > width * 0.3 || (abs(flung) > width * 0.5 && (flung < 0) == forward)
                guard hasNeighbour, farEnough else {
                    withAnimation(.spring(duration: 0.3)) { dragX = 0 }
                    return
                }
                // The neighbour slides into place, then becomes the bar.
                withAnimation(.smooth(duration: 0.22)) {
                    dragX = forward ? -width : width
                } completion: {
                    swipe.onSwitch(forward)
                    var instant = Transaction()
                    instant.disablesAnimations = true
                    withTransaction(instant) { dragX = 0 }
                }
            }
    }
}

/// Swiping the bottom bar sideways, between albums: the bars beside it, and what a swipe does.
struct BarSwipe {
    struct Neighbour: Equatable {
        let title: String
        let icon: String?
    }

    /// To the left (swiping right shows it); `nil`: nothing there, the bar springs back.
    let previous: Neighbour?
    /// To the right (swiping left shows it).
    let next: Neighbour?
    /// `true`: the next one.
    let onSwitch: @MainActor (_ forward: Bool) -> Void
}
