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
    /// iOS 26's glass swells and stretches under the finger: not on a bar that's swiped
    /// sideways, which should keep its size as it moves.
    let reactsToTouch: Bool

    // An explicit init (not the memberwise one) so passing in an existing `@MainActor` closure
    // doesn't warn about converting it to `@Sendable`.
    init(title: String, isCollapsed: Bool, progressFraction: Double, isProgressVisible: Bool,
         onExpand: @escaping @MainActor () -> Void, onEdit: @escaping @MainActor () -> Void,
         copyText: String? = nil, onPasteAndGo: (@MainActor () -> Void)? = nil,
         onOpenInBrowser: (@MainActor () -> Void)? = nil,
         searchQuery: String? = nil, onClearSearch: (@MainActor () -> Void)? = nil,
         onCollapseAll: (@MainActor () -> Void)? = nil, onExpandAll: (@MainActor () -> Void)? = nil,
         onDeleteAlbum: (@MainActor () -> Void)? = nil,
         titleIcon: String? = nil, reactsToTouch: Bool = true) {
        self.title = title
        self.titleIcon = titleIcon
        self.reactsToTouch = reactsToTouch
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
                             clearButton: clearButton, reactsToTouch: reactsToTouch)
            } else {
                ClassicFileBar(title: title, titleIcon: titleIcon, search: activeSearch, isCollapsed: isCollapsed,
                               progress: ProgressLine(fraction: progressFraction, isVisible: isProgressVisible),
                               clearButton: clearButton)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { tap() }
        // TEMPORARY: the hold menu is off, to see whether it's what holds up pulling the bar up.
        // .contextMenu {
        //     BarMenu(copyText: copyText, onPasteAndGo: onPasteAndGo, onOpenInBrowser: onOpenInBrowser,
        //             onCollapseAll: onCollapseAll, onExpandAll: onExpandAll, onDeleteAlbum: onDeleteAlbum)
        // }
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

extension EnvironmentValues {
    /// The bottom bar leaves out its iOS 18 material: something with the same material is
    /// behind it (the albums page, rising from it).
    @Entry var barBackgroundHidden = false
}

/// The bar's touch-and-hold menu: Copy (the address), Paste and Go, Open in Browser (a web
/// page), Collapse All and Expand All, and Delete Album (an album's). The same on a results
/// page's capsule, whose Collapse and Expand All are its own list's.
struct BarMenu: View {
    var copyText: String?
    var onPasteAndGo: (@MainActor () -> Void)?
    var onOpenInBrowser: (@MainActor () -> Void)?
    var onCollapseAll: (@MainActor () -> Void)?
    var onExpandAll: (@MainActor () -> Void)?
    var onDeleteAlbum: (@MainActor () -> Void)?

    var body: some View {
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
    let reactsToTouch: Bool

    var body: some View {
        BarTitle(title: title, icon: titleIcon, search: search, isCollapsed: isCollapsed)
            .padding(.horizontal, isCollapsed ? 14 : (clearButton == nil ? 20 : 44))
            .frame(maxWidth: isCollapsed ? nil : .infinity)
            .frame(height: isCollapsed ? FileBarMetrics.glassCollapsedHeight : FileBarMetrics.glassHeight)
            .overlay(alignment: .trailing) { clearButton }
            .overlay(alignment: .bottom) { progress }
            .clipShape(Capsule())
            .glassEffect(.regular.interactive(reactsToTouch), in: Capsule())
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
    @Environment(\.barBackgroundHidden) private var isBackgroundHidden
    /// How far the bar is dragged sideways (its neighbours follow it).
    @State private var dragX: CGFloat = 0
    /// Decided on the drag's first move: sideways switches, anything else is left alone.
    @State private var isSwiping: Bool?
    @State private var barWidth: CGFloat = 0
    /// Dragged far enough to make a new album on letting go (a tap of haptics as it crosses).
    @State private var makesNew = false
    /// Let go, and still moving back into place or on to the neighbour.
    @State private var isSettling = false
    /// 1 at rest. Just after a switch, 0: the neighbour on the far side, new on screen, comes in
    /// from just off it.
    @State private var arrival: CGFloat = 1
    /// That far side is the right one (the switch went forward).
    @State private var arrivedForward = true
    /// Switching away from this album (its id), until the bar shows the new one: the slide
    /// stays where it ended meanwhile, so nothing jumps back and forth.
    @State private var switchingFrom: String?
    /// How far the bar is being pulled up (to the albums page): the neighbours' edges go out to
    /// the sides as it rises.
    @State private var liftDistance: CGFloat = 0
    /// Where the drag was when it was first seen moving: the moves count from there.
    @State private var dragOrigin: CGSize?

    /// Where it rests, not being swiped (or the albums page rising from it): only then does a
    /// tap open Project.
    private var isAtHome: Bool {
        dragX == 0 && isSwiping == nil && !isSettling && switchingFrom == nil && !(swipe?.isAway?() ?? false)
    }

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
            swipeable(FileBar(title: title, isCollapsed: isCollapsed, progressFraction: progressFraction,
                              isProgressVisible: isProgressVisible,
                              onExpand: { if isAtHome { onExpand() } }, onEdit: { if isAtHome { onEdit() } },
                              copyText: copyText, onPasteAndGo: onPasteAndGo, onOpenInBrowser: onOpenInBrowser,
                              searchQuery: searchQuery, onClearSearch: onClearSearch,
                              onCollapseAll: onCollapseAll, onExpandAll: onExpandAll,
                              onDeleteAlbum: onDeleteAlbum, titleIcon: titleIcon, reactsToTouch: swipe == nil))
        }
        // A review set aside floats above the bar, at either end (swipe it across): not part of it.
        .overlay(alignment: .top) {
            if !isCollapsed, let review, review.isDocked {
                ReviewDock(draft: review)
                    .offset(y: -ReviewDock.floatingRise)  // all of it above, clear of the bar
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }

        if #available(iOS 26.0, *) {
            stack
        } else {
            // While the albums page rises from it, the page's own material is behind the bar:
            // with this one too, it was darker there than above and below.
            stack.background(Material.bar.opacity(isBackgroundHidden ? 0 : 1), ignoresSafeAreaEdges: .bottom)
        }
    }

    /// The bar, following a sideways drag with its neighbours' bars beside it, like Safari's
    /// tabs. Let go far enough (or flung) and the neighbour slides in; where there's none, the
    /// bar stretches a little and springs back. At rest, the neighbours' edges peek in at the
    /// screen's sides, so it shows there's more that way; a handle on top says it pulls up.
    @ViewBuilder
    private func swipeable(_ bar: FileBar) -> some View {
        if let swipe, !isCollapsed {
            // With an edge showing, the bar narrows to leave room for it. The bar and its
            // neighbours move as one strip, each where the next one's edge shows: a switch ends
            // with the old bar exactly where a neighbour rests.
            let inset = edgeInset(swipe)
            let spacing = neighbourSpacing(swipe)
            // The new album showing already (the slide over): from here, at rest.
            let switched = switchingFrom != nil && swipe.currentID != switchingFrom
            let x = switched ? 0 : dragX
            let arrived = switched ? 0 : arrival
            // Pulled up, the edges leave to the sides, gone by a few dozen points; just after a
            // switch, the far one comes in from there.
            let lifted = min(1, liftDistance / Self.liftToHideEdges)
            let previousOut = max(lifted, arrivedForward ? 0 : 1 - arrived) * Self.edgeShown
            let nextOut = max(lifted, arrivedForward ? 1 - arrived : 0) * Self.edgeShown
            bar
                .padding(.horizontal, inset)
                .overlay(alignment: .top) {
                    if swipe.onLift != nil { AlbumsHandle() }
                }
                .offset(x: x)
                .background {
                    ZStack {
                        if let previous = swipe.previous {
                            neighbour(previous).padding(.horizontal, inset).offset(x: x - spacing - previousOut)
                        }
                        if let next = swipe.next {
                            if next.isNew {
                                newAlbumBox(inset: inset, spacing: spacing, x: x, out: nextOut)
                            } else {
                                neighbour(next).padding(.horizontal, inset).offset(x: x + spacing + nextOut)
                            }
                        }
                    }
                }
                // The new album shows: the strip is at rest around it now.
                .onChange(of: swipe.currentID) {
                    guard switchingFrom != nil else { return }
                    var instant = Transaction()
                    instant.disablesAnimations = true
                    withTransaction(instant) {
                        dragX = 0
                        arrival = 0
                        switchingFrom = nil
                    }
                    withAnimation(.smooth(duration: 0.25)) { arrival = 1 }
                    isSettling = false
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
                    if let onLift = swipe.onLift, let onLiftEnded = swipe.onLiftEnded {
                        Button(String(localized: "Show Albums")) {
                            onLift(1)
                            onLiftEnded(.greatestFiniteMagnitude, .greatestFiniteMagnitude)
                        }
                    }
                }
        } else {
            bar
        }
    }

    /// How much narrower the bar is on each side, to leave room for a neighbour's edge.
    private func edgeInset(_ swipe: BarSwipe) -> CGFloat {
        // A new album's box shows its edge too: there's one to make.
        let showsEdges = swipe.previous != nil || swipe.next != nil
        return showsEdges ? Self.edgeShown + Self.edgeGap : 0
    }

    /// From the bar's place to a neighbour's, at rest and as it slides: where its edge shows.
    private func neighbourSpacing(_ swipe: BarSwipe) -> CGFloat {
        max(barWidth - Self.capsuleMargin - edgeInset(swipe) - Self.edgeShown, 1)
    }

    /// Back to where it rests (taps wait until it's there).
    private func springBack() {
        isSettling = true
        withAnimation(.spring(duration: 0.3), completionCriteria: .removed) {
            dragX = 0
        } completion: {
            isSettling = false
        }
    }

    /// Between the screen's side and the bar's capsule.
    private static var capsuleMargin: CGFloat {
        if #available(iOS 26.0, *) { return FileBarMetrics.glassHorizontalMargin }
        return FileBarMetrics.fieldHorizontalMargin
    }

    /// How much of a neighbour's capsule shows at rest.
    private static let edgeShown: CGFloat = 12
    /// How far up the bar is pulled before the neighbours' edges are out of sight.
    private static let liftToHideEdges: CGFloat = 60
    /// Between a neighbour's edge and the bar.
    private static let edgeGap: CGFloat = 6

    private func neighbour(_ neighbour: BarSwipe.Neighbour) -> some View {
        FileBar(title: neighbour.title, isCollapsed: false, progressFraction: 0, isProgressVisible: false,
                onExpand: {}, onEdit: {}, titleIcon: neighbour.icon)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    /// Past the last album, like Safari's new tab: just a +, in the middle of what the bar
    /// uncovers, stronger once letting go makes the album.
    /// Past the last album, like Safari's new tab: a grey box in the bar's shape, the +
    /// in its middle. At rest just its edge shows, as a neighbour's does; dragged, its near end
    /// follows the bar's and its far end comes in from the screen's side, so it grows into the
    /// bar's place.
    /// - Parameter out: how far its edge has gone off the screen's side (pulled up).
    private func newAlbumBox(inset: CGFloat, spacing: CGFloat, x: CGFloat, out: CGFloat) -> some View {
        let progress = min(1, abs(x) / spacing)
        let margin = Self.capsuleMargin + inset
        // From the bar's left, in its own space: where a neighbour's capsule would start, and
        // the screen's side, moving in to the bar's end.
        let left = x + spacing + out + margin
        let right = barWidth - margin * progress
        let width = max(0, right - left)
        return Self.capsuleShape
            .fill(Color(uiColor: .secondarySystemFill))
            .frame(width: width, height: Self.capsuleHeight)
            .overlay {
                Image(systemName: "plus")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(makesNew ? Color.primary : Color.secondary)
                    .scaleEffect(makesNew ? 1.15 : 0.9)
                    .opacity(min(1, max(0, width - 20) / 30))
                    .animation(.spring(duration: 0.2), value: makesNew)
            }
            .offset(x: (left + right) / 2 - barWidth / 2, y: Self.capsuleCenterY)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    /// The bar's capsule (iOS 26) or rounded field (iOS 18).
    private static var capsuleShape: AnyShape {
        if #available(iOS 26.0, *) { return AnyShape(Capsule()) }
        return AnyShape(RoundedRectangle(cornerRadius: FileBarMetrics.fieldCornerRadius, style: .continuous))
    }

    private static var capsuleHeight: CGFloat {
        if #available(iOS 26.0, *) { return FileBarMetrics.glassHeight }
        return FileBarMetrics.fieldHeight
    }

    /// Where the capsule's middle is from the bar's (iOS 26's sits on a little padding).
    private static var capsuleCenterY: CGFloat {
        if #available(iOS 26.0, *) { return -FileBarMetrics.glassBottomPadding / 2 }
        return 0
    }

    /// How far a drag toward a new album must go to make it.
    private var newAlbumDistance: CGFloat { max(barWidth, 1) * 0.3 }

    /// In the screen's space: pulled up, the bar moves with the finger, and in its own the drag
    /// would shake. Measured from where it was first seen moving: the drag starts a few points
    /// along, and counted from where the finger went down, the bar jumped those points (and
    /// stood still until then: a short pull held looked stuck, then caught up).
    private func swipeGesture(_ swipe: BarSwipe) -> some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .global)
            .onChanged { value in
                let origin = dragOrigin ?? value.translation
                if dragOrigin == nil { dragOrigin = origin }
                // Which way, from how it moved to get here: sideways switches, otherwise up.
                if isSwiping == nil { isSwiping = abs(value.translation.width) > abs(value.translation.height) }
                swipeChanged(value.translation - origin, swipe)
            }
            .onEnded { value in
                let origin = dragOrigin ?? .zero
                dragOrigin = nil
                swipeEnded(value.translation - origin, predicted: value.predictedEndTranslation - origin, swipe)
            }
    }

    private func swipeChanged(_ translation: CGSize, _ swipe: BarSwipe) {
        let dx = translation.width, dy = translation.height
        if isSwiping == nil { isSwiping = abs(dx) > abs(dy) }
        guard isSwiping == true else {
            // Up: the albums page rises with the finger.
            liftDistance = max(0, -dy)
            swipe.onLift?(max(0, -dy))
            return
        }
        // Toward a side with nothing there: a little, and less the further it goes.
        let hasNeighbour = dx < 0 ? swipe.next != nil : swipe.previous != nil
        dragX = hasNeighbour ? dx : dx / (1 + abs(dx) / 60)
        // Toward a new album: a tap as it gets far enough to make one.
        let crossed = dx < 0 && swipe.next?.isNew == true && -dx > newAlbumDistance
        if crossed != makesNew {
            makesNew = crossed
            if crossed { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
        }
    }

    private func swipeEnded(_ translation: CGSize, predicted: CGSize, _ swipe: BarSwipe) {
        let wasPastNew = makesNew
        defer {
            isSwiping = nil
            makesNew = false
        }
        guard isSwiping == true else {
            swipe.onLiftEnded?(max(0, -translation.height), -predicted.height)
            withAnimation(.smooth(duration: 0.3)) { liftDistance = 0 }
            return
        }
        let dx = translation.width
        let flung = predicted.width
        let forward = dx < 0
        let hasNeighbour = forward ? swipe.next != nil : swipe.previous != nil
        let width = max(barWidth, 1)
        let farEnough = abs(dx) > width * 0.3 || (abs(flung) > width * 0.5 && (flung < 0) == forward)
        // A new album only once it's past the threshold (a fling doesn't make one): then
        // its box grows into the bar, as a neighbour slides in.
        let switches = forward && swipe.next?.isNew == true ? wasPastNew : hasNeighbour && farEnough
        guard switches else {
            springBack()
            return
        }
        // The neighbour slides into the bar's place (the bar into a neighbour's), then
        // becomes the bar once the album shows (see `onChange(of: currentID)`).
        isSettling = true
        arrivedForward = forward
        // Once it's really there: "logically" complete, a spring still had a few points to go,
        // and the new album's bar jumped them as it took over.
        withAnimation(.smooth(duration: 0.22), completionCriteria: .removed) {
            dragX = forward ? -neighbourSpacing(swipe) : neighbourSpacing(swipe)
        } completion: {
            switchingFrom = swipe.currentID
            swipe.onSwitch(forward)
            // Should the album not change after all: back to rest.
            Task {
                try? await Task.sleep(for: .seconds(1))
                guard switchingFrom != nil else { return }
                switchingFrom = nil
                springBack()
            }
        }
    }
}

private extension CGSize {
    static func - (lhs: CGSize, rhs: CGSize) -> CGSize {
        CGSize(width: lhs.width - rhs.width, height: lhs.height - rhs.height)
    }
}

/// On top of the bottom bar, like a sheet's grabber: it pulls up (to the albums page). In the gap
/// above the iOS 26 capsule; inside the iOS 18 bar's top padding.
struct AlbumsHandle: View {
    var body: some View {
        Capsule()
            .fill(.tertiary)
            .frame(width: 36, height: 4)
            .offset(y: Self.y)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private static var y: CGFloat {
        if #available(iOS 26.0, *) { return -6 }
        return 2
    }
}

/// Swiping the bottom bar sideways, between albums: the bars beside it, and what a swipe does.
struct BarSwipe {
    struct Neighbour: Equatable {
        let title: String
        let icon: String?
        /// Past the last album: a new one, shown as just a +.
        var isNew = false
    }

    /// To the left (swiping right shows it); `nil`: nothing there, the bar springs back.
    let previous: Neighbour?
    /// To the right (swiping left shows it).
    let next: Neighbour?
    /// The album shown ("" for the whole project): a switch is over once it changes.
    let currentID: String
    /// `true`: the next one.
    let onSwitch: @MainActor (_ forward: Bool) -> Void
    /// Swiping up instead: how far (the albums page follows), then where it was let go and
    /// where it was flung to.
    var onLift: (@MainActor (CGFloat) -> Void)? = nil
    var onLiftEnded: (@MainActor (_ distance: CGFloat, _ predicted: CGFloat) -> Void)? = nil
    /// The albums page is up, or on its way (the bar's taps wait).
    var isAway: (@MainActor () -> Bool)? = nil
}
