import SwiftUI
import UIKit

/// Symbols mode: every top-level definition as a full-width card, like photos in Photos.
/// Tapping a card zooms into that symbol (see `SymbolPager`).
struct SymbolsView: View {
    let symbols: [CodeSymbol]
    /// False while another mode covers the list (it stays alive to keep its place).
    let isActive: Bool
    let namespace: Namespace.ID
    /// The card scrolled into view. Set it to bring a card back on screen.
    @Binding var scrolledID: Int?
    let isBarCollapsed: Bool
    let barTapCount: Int
    let onOpen: @MainActor (CodeSymbol) -> Void
    let onBarCollapsedChange: @MainActor (Bool) -> Void
    /// While searching: pulling the cards down past their top closes the search field.
    let onPullDown: (@MainActor () -> Void)?

    /// Not observed: updated every scroll frame without redrawing anything.
    @State private var scroll = ScrollTracking()

    // An explicit init (not the memberwise one) so passing in an existing `@MainActor` closure
    // doesn't warn about converting it to `@Sendable`.
    init(symbols: [CodeSymbol], isActive: Bool, namespace: Namespace.ID, scrolledID: Binding<Int?>,
         isBarCollapsed: Bool, barTapCount: Int,
         onOpen: @escaping @MainActor (CodeSymbol) -> Void,
         onBarCollapsedChange: @escaping @MainActor (Bool) -> Void,
         onPullDown: (@MainActor () -> Void)? = nil) {
        self.symbols = symbols
        self.isActive = isActive
        self.namespace = namespace
        _scrolledID = scrolledID
        self.isBarCollapsed = isBarCollapsed
        self.barTapCount = barTapCount
        self.onOpen = onOpen
        self.onBarCollapsedChange = onBarCollapsedChange
        self.onPullDown = onPullDown
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(symbols) { symbol in
                    Button { onOpen(symbol) } label: {
                        SymbolCard(symbol: symbol)
                    }
                    .buttonStyle(.plain)
                    .matchedTransitionSource(id: symbol.id, in: namespace)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .scrollTargetLayout()
        }
        .scrollPosition(id: $scrolledID, anchor: .center)
        .scrollDismissesKeyboard(.immediately)  // any swipe hides the keyboard
        .scrollDisabled(!isActive)  // hidden: stays put, and leaves status-bar taps to File
        .modifier(OnPullDownPastTop(action: isActive ? onPullDown : nil))
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

/// Symbol search results over File: a compact list (kind, name, line), best matches first.
struct SymbolResultsList: View {
    let symbols: [CodeSymbol]
    /// Pulling the list down past its top closes the search.
    let onPullDown: @MainActor () -> Void
    let onOpen: @MainActor (CodeSymbol) -> Void

    init(symbols: [CodeSymbol], onPullDown: @escaping @MainActor () -> Void,
         onOpen: @escaping @MainActor (CodeSymbol) -> Void) {
        self.symbols = symbols
        self.onPullDown = onPullDown
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
        .modifier(OnPullDownPastTop(action: onPullDown))
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
