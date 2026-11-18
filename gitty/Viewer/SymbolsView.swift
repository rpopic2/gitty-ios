import SwiftUI
import UIKit

/// Symbols mode: every top-level definition as a full-width card, like photos in Photos.
/// Tapping a card zooms into that symbol (see `SymbolPager`).
struct SymbolsView: View {
    let symbols: [CodeSymbol]
    /// The symbol search the list is filtered by ("" for none). Clearing it brings back the
    /// place from before the search.
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
    let onOpen: @MainActor (CodeSymbol) -> Void
    let onBarCollapsedChange: @MainActor (Bool) -> Void
    /// While searching: scrolling the cards closes the search field (the filter stays), like
    /// scrolling a page in Safari ends editing the address.
    let onCloseSearch: (@MainActor () -> Void)?

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
         isBarCollapsed: Bool, barTapCount: Int,
         onOpen: @escaping @MainActor (CodeSymbol) -> Void,
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
        self.onOpen = onOpen
        self.onBarCollapsedChange = onBarCollapsedChange
        self.onCloseSearch = onCloseSearch
    }

    var body: some View {
        ScrollViewReader { reader in
            list
                .onAppear {
                    // `scrollPosition(id:)` ignores a starting value during the first layout and
                    // opens on the first card. Move to the saved card explicitly.
                    let target = scrolledID ?? initialID()
                    if let target { reader.scrollTo(target, anchor: .center) }
                    position = target
                    isPositioned = true
                }
                .onChange(of: query) { _, query in
                    // Cleared: back to where the list was before the search. Chosen here rather
                    // than left to `scrollPosition`, which would chase the card that was in the
                    // middle of the results through the much longer list.
                    guard query.isEmpty, let target = initialID() else { return }
                    reader.scrollTo(target, anchor: .center)
                    position = target
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
    }

    private var list: some View {
        ScrollView {
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
        .scrollPosition(id: $position, anchor: .center)
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        .scrollDismissesKeyboard(.immediately)  // any swipe hides the keyboard
        .scrollDisabled(!isActive)  // hidden: stays put, and leaves status-bar taps to File
        .contentMargins(.bottom, FileBarMetrics.expandedHeight, for: .scrollContent)
        .background(Color(uiColor: .systemGroupedBackground))
        .onScrollPhaseChange { _, phase, context in
            scroll.isUserScrolling = phase == .interacting || phase == .decelerating
            if phase == .interacting {
                scroll.tracker.beginDrag(at: context.geometry.contentOffset.y)
                // The drag hides the keyboard; without it the search field would stay, alone,
                // in place of the bar and the mode selector.
                if isActive { onCloseSearch?() }
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
                    Text("Line \(symbol.line)")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityLabel("\(symbol.kind.title) \(symbol.name), line \(symbol.line)")
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
                Text("Line \(symbol.line)")
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
        .accessibilityLabel("\(symbol.kind.title) \(symbol.name), line \(symbol.line)")
    }
}
