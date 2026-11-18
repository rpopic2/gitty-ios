import SwiftUI
import UIKit

/// Symbols mode: every top-level definition as a full-width card, like photos in Photos.
/// Tapping a card zooms into that symbol (see `SymbolPager`).
///
/// Pinching in zooms out, like Photos: the symbols shrink to one-line rows, grouped under a
/// sticky header per file (its name and count; tap to fold it, or open it in File). Pinching
/// out, or tapping a row, comes back to the cards, at that symbol. The choice is kept app-wide.
struct SymbolsView: View {
    let symbols: [CodeSymbol]
    /// The symbol search the list is filtered by ("" for none). Give each search its own list
    /// (`.id(query)`): the results start at the top, and clearing the search starts a fresh full
    /// list at the place from before the search. (One list kept through searches piles up the
    /// cards it built for every set of results, and scrolling gets slower.)
    let query: String
    /// False while another mode covers the list (it stays alive to keep its place).
    let isActive: Bool
    let namespace: Namespace.ID
    /// The card in the middle of the screen. Set it to bring a card back on screen.
    @Binding var scrolledID: Int?
    /// Where to start when `scrolledID` is still `nil`: the saved place in the list.
    let initialID: @MainActor () -> Int?
    let isBarCollapsed: Bool
    let barTapCount: Int
    /// The open file, which symbols without a `fileURL` are in (for the grouped view).
    let openFile: URL
    let onOpen: @MainActor (CodeSymbol) -> Void
    /// A file header's open button: show that file in File mode.
    let onOpenFile: @MainActor (URL) -> Void
    let onBarCollapsedChange: @MainActor (Bool) -> Void
    /// While searching: a swipe on the cards closes the search field (the filter stays). That
    /// swipe only closes it: the list doesn't scroll and the bar doesn't shrink.
    let onCloseSearch: (@MainActor () -> Void)?

    /// Zoomed out: rows grouped by file instead of cards.
    @AppStorage("symbolsGroupedByFile") private var isGrouped = false
    @State private var folded = SymbolFoldStore.standard.foldedFiles()
    @State private var groupCache = GroupCache()
    /// This pinch has already switched the layout (one switch per pinch).
    @State private var pinchHandled = false
    /// Where the other layout should open: the symbol that was in the middle, or a tapped row.
    @State private var switchAnchor: Int?
    /// Not observed: updated every scroll frame without redrawing anything.
    @State private var scroll = ScrollTracking()
    /// The list's own scroll position. It's passed on to `scrolledID` only once the list has
    /// moved to where it should start, so the first layout (on the first card) can't overwrite it.
    @State private var position: Int?
    @State private var isPositioned = false

    // An explicit init (not the memberwise one) so passing in an existing `@MainActor` closure
    // doesn't warn about converting it to `@Sendable`.
    init(symbols: [CodeSymbol], query: String, isActive: Bool, namespace: Namespace.ID,
         scrolledID: Binding<Int?>,
         initialID: @escaping @MainActor () -> Int? = { nil },
         isBarCollapsed: Bool, barTapCount: Int, openFile: URL,
         onOpen: @escaping @MainActor (CodeSymbol) -> Void,
         onOpenFile: @escaping @MainActor (URL) -> Void,
         onBarCollapsedChange: @escaping @MainActor (Bool) -> Void,
         onCloseSearch: (@MainActor () -> Void)? = nil) {
        self.symbols = symbols
        self.query = query
        self.isActive = isActive
        self.namespace = namespace
        _scrolledID = scrolledID
        self.initialID = initialID
        self.isBarCollapsed = isBarCollapsed
        self.barTapCount = barTapCount
        self.openFile = openFile
        self.onOpen = onOpen
        self.onOpenFile = onOpenFile
        self.onBarCollapsedChange = onBarCollapsedChange
        self.onCloseSearch = onCloseSearch
    }

    var body: some View {
        ScrollViewReader { reader in
            Group {
                if isGrouped {
                    scrollContainer { groupedRows }
                        .onAppear { moveToStart(reader) }
                        .transition(.opacity)
                } else {
                    scrollContainer { cards }
                        .onAppear { moveToStart(reader) }
                        .transition(.opacity)
                }
            }
        }
        .onChange(of: position) { _, id in
            guard isPositioned, let id, id != scrolledID else { return }
            scrolledID = id
        }
        .onChange(of: scrolledID) { _, id in
            // Set from outside (the pager closing on another card): bring that card into view.
            guard let id, id != position else { return }
            position = id
        }
        .accessibilityAction(named: layoutActionName) {
            switchLayout(grouped: !isGrouped, anchor: position)
        }
    }

    /// For VoiceOver, which has no pinch.
    private var layoutActionName: LocalizedStringKey {
        isGrouped ? "Show Cards" : "Group by File"
    }

    /// `scrollPosition(id:)` ignores a starting value during the first layout and opens on the
    /// first item, so move to the start explicitly: after a pinch, the symbol that was in the
    /// middle; otherwise the saved place. Search results start at the top, with the best match.
    private func moveToStart(_ reader: ScrollViewProxy) {
        let target = switchAnchor ?? (query.isEmpty ? initialID() ?? scrolledID : nil)
        switchAnchor = nil
        if let target { reader.scrollTo(target, anchor: .center) }
        position = target
        isPositioned = true
    }

    // MARK: Layouts

    private var cards: some View {
        LazyVStack(spacing: 12) {
            ForEach(symbols) { symbol in
                Button { onOpen(symbol) } label: {
                    SymbolCard(symbol: symbol)
                }
                .buttonStyle(.plain)
                .matchedTransitionSource(id: symbol.id, in: namespace)
                // The margin is part of each scroll target, so every target spans the full
                // width and centering one never scrolls sideways.
                .padding(.horizontal, 16)
            }
        }
        .padding(.vertical, 12)
        .scrollTargetLayout()
    }

    private var groupedRows: some View {
        LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
            ForEach(groupCache.groups(of: symbols, openFile: openFile, query: query)) { group in
                let isFolded = folded.contains(group.file)
                Section {
                    if !isFolded {
                        ForEach(group.symbols) { symbol in
                            Button { showCard(symbol) } label: {
                                SymbolRow(symbol: symbol)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                } header: {
                    SymbolFileHeader(
                        name: group.file.displayFileName,
                        count: group.symbols.count,
                        isFolded: isFolded,
                        onToggle: { toggleFold(group.file) },
                        onOpenFile: { onOpenFile(group.file) }
                    )
                }
            }
        }
        .padding(.bottom, 12)
        .scrollTargetLayout()
    }

    // MARK: Switching

    /// Pinching in (fingers together) groups by file; pinching out shows the cards again. Each
    /// pinch switches once, when it passes the threshold, and the change animates from there.
    private var pinch: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                guard !pinchHandled else { return }
                if value.magnification < 0.8, !isGrouped {
                    pinchHandled = true
                    switchLayout(grouped: true, anchor: position)
                } else if value.magnification > 1.25, isGrouped {
                    pinchHandled = true
                    switchLayout(grouped: false, anchor: position)
                }
            }
            .onEnded { _ in pinchHandled = false }
    }

    private func switchLayout(grouped: Bool, anchor: Int?) {
        switchAnchor = anchor
        withAnimation(.smooth(duration: 0.3)) { isGrouped = grouped }
    }

    /// A row tapped in the grouped view: back to the cards, at that symbol.
    private func showCard(_ symbol: CodeSymbol) {
        switchLayout(grouped: false, anchor: symbol.id)
    }

    private func toggleFold(_ file: URL) {
        let isFolded = !folded.contains(file)
        withAnimation(.smooth(duration: 0.25)) {
            if isFolded { folded.insert(file) } else { folded.remove(file) }
        }
        SymbolFoldStore.standard.setFolded(isFolded, file)
    }

    // MARK: Scrolling

    private var closesSearchOnSwipe: Bool {
        isActive && onCloseSearch != nil
    }

    /// The scroll view either layout sits in: its place, the bar collapsing as you scroll, the
    /// swipe that closes the search, and the pinch.
    private func scrollContainer<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        ScrollView {
            content()
        }
        .scrollPosition(id: $position, anchor: .center)
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        // Hidden: stays put, and leaves status-bar taps to File. While searching, the swipe that
        // closes the search mustn't scroll; scrolling comes back for the next swipe.
        .scrollDisabled(!isActive || closesSearchOnSwipe)
        .gesture(
            DragGesture(minimumDistance: 10).onChanged { _ in
                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                                to: nil, from: nil, for: nil)
                onCloseSearch?()
            },
            including: closesSearchOnSwipe ? .all : .subviews
        )
        .simultaneousGesture(pinch, including: isActive ? .all : .subviews)
        .contentMargins(.bottom, FileBarMetrics.expandedHeight, for: .scrollContent)
        .background(Color(uiColor: .systemGroupedBackground))
        .onScrollPhaseChange { _, phase, context in
            scroll.isUserScrolling = phase == .interacting || phase == .decelerating
            if phase == .interacting {
                scroll.tracker.beginDrag(at: context.geometry.contentOffset.y)
            }
        }
        .onScrollGeometryChange(for: ScrollGeometry.self) { $0 } action: { _, geometry in
            scroll.tracker.isCollapsed = isBarCollapsed
            let change = scroll.tracker.scrolled(
                to: geometry.contentOffset.y,
                top: -geometry.contentInsets.top,
                bottom: geometry.contentSize.height - geometry.containerSize.height + geometry.contentInsets.bottom,
                isUserScrolling: scroll.isUserScrolling
            )
            if isActive, let change { onBarCollapsedChange(change) }
        }
        .onChange(of: barTapCount) {
            scroll.tracker.holdOpen()
        }
    }
}

/// The grouped view's files, worked out again only when the symbols change (not on every
/// redraw: a big project has tens of thousands of symbols). Not observed.
private final class GroupCache {
    private var key: (query: String, count: Int, first: Int?, last: Int?)?
    private var groups: [SymbolFileGroup] = []

    func groups(of symbols: [CodeSymbol], openFile: URL, query: String) -> [SymbolFileGroup] {
        let key = (query: query, count: symbols.count, first: symbols.first?.id, last: symbols.last?.id)
        if let old = self.key, old == key { return groups }
        self.key = key
        groups = SymbolFileGroup.groups(of: symbols, openFile: openFile)
        return groups
    }
}

/// A file in the grouped view: fold it with a tap, open it with the button at the end. It
/// sticks to the top while its symbols scroll under it.
private struct SymbolFileHeader: View {
    let name: String
    let count: Int
    let isFolded: Bool
    let onToggle: @MainActor () -> Void
    let onOpenFile: @MainActor () -> Void

    init(name: String, count: Int, isFolded: Bool, onToggle: @escaping @MainActor () -> Void,
         onOpenFile: @escaping @MainActor () -> Void) {
        self.name = name
        self.count = count
        self.isFolded = isFolded
        self.onToggle = onToggle
        self.onOpenFile = onOpenFile
    }

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onToggle) {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isFolded ? 0 : 90))
                    Text(name)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("· \(count)")
                        .font(.subheadline)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(name), \(count) symbols")
            .accessibilityValue(isFolded ? Text("Folded") : Text("Unfolded"))
            .accessibilityHint(isFolded ? Text("Shows this file's symbols") : Text("Hides this file's symbols"))

            Button("Open \(name)", systemImage: "arrow.up.forward.square") { onOpenFile() }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 44)
        .background(.bar)
    }
}

/// A symbol in the grouped view: its kind, name and line, on one line.
private struct SymbolRow: View {
    let symbol: CodeSymbol

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol.kind.systemImage)
                .foregroundStyle(.tint)
                .frame(width: 22)
                .accessibilityHidden(true)
            Text(symbol.name)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            Text("Line \(symbol.line)")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 44)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .overlay(alignment: .bottom) {
            Divider().padding(.leading, 48)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(symbol.spokenDescription)
        .accessibilityHint(Text("Shows its card"))
    }
}

/// Symbol search results over File: a compact list (kind, name, line), best matches first.
struct SymbolResultsList: View {
    let symbols: [CodeSymbol]
    /// Pulling the list down past its top closes the search.
    let onCloseSearch: @MainActor () -> Void
    let onOpen: @MainActor (CodeSymbol) -> Void

    init(symbols: [CodeSymbol], onCloseSearch: @escaping @MainActor () -> Void,
         onOpen: @escaping @MainActor (CodeSymbol) -> Void) {
        self.symbols = symbols
        self.onCloseSearch = onCloseSearch
        self.onOpen = onOpen
    }

    var body: some View {
        List(symbols) { symbol in
            Button { onOpen(symbol) } label: {
                HStack(spacing: 10) {
                    Image(systemName: symbol.kind.systemImage)
                        .foregroundStyle(.tint)
                        .frame(width: 22)
                        .accessibilityHidden(true)
                    Text(symbol.name)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    Text(symbol.lineLabel)
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityLabel(symbol.spokenDescription)
        }
        .listStyle(.plain)
        .contentMargins(.bottom, FileBarMetrics.fieldHeight + 16, for: .scrollContent)  // the search field
        .modifier(OnPullDownPastTop(action: onCloseSearch))
        .scrollDismissesKeyboard(.immediately)  // any swipe hides the keyboard
    }
}

/// Pulling a list down past its top (about 60pt) runs `action` once per pull, like pulling down
/// to dismiss a sheet. `nil` turns it off.
struct OnPullDownPastTop: ViewModifier {
    let action: (@MainActor () -> Void)?

    init(action: (@MainActor () -> Void)?) {
        self.action = action
    }

    func body(content: Content) -> some View {
        content.onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.contentOffset.y < -geometry.contentInsets.top - 60
        } action: { wasPulled, isPulled in
            if isPulled && !wasPulled { action?() }
        }
    }
}

private final class ScrollTracking {
    var tracker = BarCollapseTracker()
    var isUserScrolling = false
}

/// One symbol in the list: its kind, name, line and the first lines of its code.
struct SymbolCard: View {
    let symbol: CodeSymbol

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: symbol.kind.systemImage)
                    .font(.subheadline)
                    .foregroundStyle(.tint)
                Text(symbol.name)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                Text(symbol.lineLabel)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Text(symbol.preview)
                .font(.custom(RawTextStyle.fontName, fixedSize: 11))
                .foregroundStyle(.secondary)
                .lineLimit(SymbolIndexer.previewLineCount)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: shape)
        .contentShape(shape)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(symbol.spokenDescription)
    }
}
