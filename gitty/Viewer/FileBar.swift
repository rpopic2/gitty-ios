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

    // Mode selector (Project / File / Symbols) under the bar.
    static let selectorHeight: CGFloat = 32
    static let selectorMaxWidth: CGFloat = 320
    static var selectorPadding: CGFloat {
        if #available(iOS 26.0, *) { return 4 } else { return 0 }  // glass padding around it
    }
    static let selectorBottomPadding: CGFloat = 8

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

    /// Height of the expanded bar plus the mode selector, above the bottom safe area. Content keeps
    /// this much free at its end, and never changes it, so nothing jumps when the bar collapses.
    static var expandedHeight: CGFloat {
        barHeight + selectorHeight + 2 * selectorPadding + selectorBottomPadding
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

    // An explicit init (not the memberwise one) so passing in an existing `@MainActor` closure
    // doesn't warn about converting it to `@Sendable`.
    init(title: String, isCollapsed: Bool, progressFraction: Double, isProgressVisible: Bool,
         onExpand: @escaping @MainActor () -> Void, onEdit: @escaping @MainActor () -> Void,
         copyText: String? = nil, onPasteAndGo: (@MainActor () -> Void)? = nil,
         onOpenInBrowser: (@MainActor () -> Void)? = nil,
         searchQuery: String? = nil, onClearSearch: (@MainActor () -> Void)? = nil) {
        self.title = title
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
                GlassFileBar(title: title, search: activeSearch, isCollapsed: isCollapsed,
                             progress: ProgressLine(fraction: progressFraction, isVisible: isProgressVisible),
                             clearButton: clearButton)
            } else {
                ClassicFileBar(title: title, search: activeSearch, isCollapsed: isCollapsed,
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
            Text(title.isEmpty ? "Enter URL" : title)
                .font(font)
                .contentTransition(.interpolate)  // smooth size change between states
                .foregroundStyle(title.isEmpty ? .secondary : .primary)
                .lineLimit(1)
                .truncationMode(.middle)
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
    let search: String?
    let isCollapsed: Bool
    let progress: ProgressLine
    let clearButton: ClearSearchButton?

    var body: some View {
        BarTitle(title: title, search: search, isCollapsed: isCollapsed)
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
    let search: String?
    let isCollapsed: Bool
    let progress: ProgressLine
    let clearButton: ClearSearchButton?

    private var field: RoundedRectangle {
        RoundedRectangle(cornerRadius: FileBarMetrics.fieldCornerRadius, style: .continuous)
    }

    var body: some View {
        BarTitle(title: title, search: search, isCollapsed: isCollapsed)
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

/// The bottom of the screen: the file bar with the mode selector under it.
/// When the bar collapses on scroll, the selector hides with it.
struct BottomBarStack: View {
    let title: String
    let isCollapsed: Bool
    let progressFraction: Double
    let isProgressVisible: Bool
    /// `nil` hides the mode selector (start page).
    let mode: Binding<ViewMode>?
    let onExpand: @MainActor () -> Void
    let onEdit: @MainActor () -> Void
    let copyText: String?
    let onPasteAndGo: (@MainActor () -> Void)?
    let onOpenInBrowser: (@MainActor () -> Void)?
    let searchQuery: String?
    let onClearSearch: (@MainActor () -> Void)?
    /// The sort button beside the mode selector (`nil`: none).
    let sorting: Binding<ListSorting>?
    /// A review set aside shows above the bar, like a minimized Mail draft.
    @Environment(ReviewDraft.self) private var review: ReviewDraft?

    // An explicit init (not the memberwise one) so passing in an existing `@MainActor` closure
    // doesn't warn about converting it to `@Sendable`.
    init(title: String, isCollapsed: Bool, progressFraction: Double, isProgressVisible: Bool,
         mode: Binding<ViewMode>?,
         onExpand: @escaping @MainActor () -> Void, onEdit: @escaping @MainActor () -> Void,
         copyText: String? = nil, onPasteAndGo: (@MainActor () -> Void)? = nil,
         onOpenInBrowser: (@MainActor () -> Void)? = nil,
         searchQuery: String? = nil, onClearSearch: (@MainActor () -> Void)? = nil,
         sorting: Binding<ListSorting>? = nil) {
        self.title = title
        self.isCollapsed = isCollapsed
        self.progressFraction = progressFraction
        self.isProgressVisible = isProgressVisible
        self.sorting = sorting
        self.mode = mode
        self.onExpand = onExpand
        self.onEdit = onEdit
        self.copyText = copyText
        self.onPasteAndGo = onPasteAndGo
        self.onOpenInBrowser = onOpenInBrowser
        self.searchQuery = searchQuery
        self.onClearSearch = onClearSearch
    }

    var body: some View {
        let stack = VStack(spacing: 0) {
            if !isCollapsed, let review, review.isDocked {
                ReviewDock(draft: review)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            FileBar(title: title, isCollapsed: isCollapsed, progressFraction: progressFraction,
                    isProgressVisible: isProgressVisible, onExpand: onExpand, onEdit: onEdit,
                    copyText: copyText, onPasteAndGo: onPasteAndGo, onOpenInBrowser: onOpenInBrowser,
                    searchQuery: searchQuery, onClearSearch: onClearSearch)
            if !isCollapsed, let mode {
                HStack(spacing: 8) {
                    if let sorting {
                        ListSortMenu(sorting: sorting)
                            .transition(.opacity)
                    }
                    ModeSelector(mode: mode)
                    if sorting != nil {
                        // As wide as the button, so the selector stays centered.
                        Color.clear.frame(width: ListSortMenu.size, height: 1)
                    }
                }
                .padding(.bottom, FileBarMetrics.selectorBottomPadding)
                .padding(.horizontal, FileBarMetrics.fieldHorizontalMargin)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }

        if #available(iOS 26.0, *) {
            stack
        } else {
            stack.background(.bar, ignoresSafeAreaEdges: .bottom)
        }
    }
}
