import SwiftUI
import UIKit

/// Symbols mode: every top-level definition as a full-width card, like photos in Photos.
/// Tapping a card zooms into that symbol (see `SymbolPager`).
///
/// Pinching zooms in and out, like Photos, through the levels of `ViewMode` (the selector under
/// the bar follows):
/// - Files: one-line rows, grouped under a sticky header per file (its name and count; tap to
///   fold it, or show it in Code). Tapping a row zooms back in to its card. Zooming out from
///   here goes to Project.
/// - Symbols: the cards.
/// - Code: every symbol's whole code, edge to edge in the raw-text style, each under a slim
///   title that sticks to the top while you read it. Tap one to open its page.
struct SymbolsView: View {
    let symbols: [CodeSymbol]
    /// The symbol search the list is filtered by ("" for none). Give each search its own list
    /// (`.id(query)`): the results start at the top, and clearing the search starts a fresh full
    /// list at the place from before the search. (One list kept through searches piles up the
    /// cards it built for every set of results, and scrolling gets slower.)
    let query: String
    /// False while another mode covers the list (it stays alive to keep its place).
    let isActive: Bool
    /// Brings a card into view (the pager closing on another card). Each request scrolls once,
    /// even to the same card as last time.
    let scrollRequest: SymbolScrollRequest?
    /// The saved place in the list, where it starts.
    let initialID: @MainActor () -> Int?
    /// Another card reached the middle of the screen (to save the place). It's reported without
    /// redrawing anything, here or in the screen around it: that happens many times a second.
    let onCenteredSymbolChange: @MainActor (Int) -> Void
    let isBarCollapsed: Bool
    let barTapCount: Int
    /// The open file, which symbols without a `fileURL` are in (for the grouped view).
    let openFile: URL
    let onOpen: @MainActor (CodeSymbol) -> Void
    /// A file header's open button: show that file's code (the Code level, at its entry).
    let onOpenFile: @MainActor (URL) -> Void
    let onBarCollapsedChange: @MainActor (Bool) -> Void
    /// While searching: a swipe on the cards closes the search field (the filter stays). That
    /// swipe only closes it: the list doesn't scroll and the bar doesn't shrink.
    let onCloseSearch: (@MainActor () -> Void)?

    /// The zoom level, shared with the selector under the bar (Project hides this view).
    @Binding var mode: ViewMode
    /// The level on screen. It follows `mode`, one step behind, so the new level can open at the
    /// symbol that was in the middle (see `onChange(of: mode)`).
    @State private var zoom: ViewMode
    @State private var folded = SymbolFoldStore.standard.foldedFiles()
    @State private var groupCache = GroupCache()
    /// The Code level's prepared code, per symbol (this list's ids).
    @State private var codeBlocks = CodeBlockStore()
    /// This pinch has already switched the layout (one switch per pinch).
    @State private var pinchHandled = false
    /// Where the other layout should open: the symbol that was in the middle, or a tapped row.
    @State private var switchAnchor: Int?
    /// Not observed: updated every scroll frame without redrawing anything.
    @State private var scroll = ScrollTracking()

    // An explicit init (not the memberwise one) so passing in an existing `@MainActor` closure
    // doesn't warn about converting it to `@Sendable`.
    init(symbols: [CodeSymbol], query: String, mode: Binding<ViewMode>, isActive: Bool,
         scrollRequest: SymbolScrollRequest?,
         initialID: @escaping @MainActor () -> Int? = { nil },
         onCenteredSymbolChange: @escaping @MainActor (Int) -> Void,
         isBarCollapsed: Bool, barTapCount: Int, openFile: URL,
         onOpen: @escaping @MainActor (CodeSymbol) -> Void,
         onOpenFile: @escaping @MainActor (URL) -> Void,
         onBarCollapsedChange: @escaping @MainActor (Bool) -> Void,
         onCloseSearch: (@MainActor () -> Void)? = nil) {
        self.symbols = symbols
        self.query = query
        _mode = mode
        _zoom = State(initialValue: mode.wrappedValue.showsSymbols ? mode.wrappedValue : .files)
        self.isActive = isActive
        self.scrollRequest = scrollRequest
        self.initialID = initialID
        self.onCenteredSymbolChange = onCenteredSymbolChange
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
                switch zoom {
                case .project, .files:
                    scrollContainer { groupedRows }
                        .onAppear { moveToStart(reader) }
                        .transition(.opacity)
                case .symbols:
                    scrollContainer { cards }
                        .onAppear { moveToStart(reader) }
                        .transition(.opacity)
                case .code:
                    scrollContainer { fullCode }
                        .onAppear { moveToStart(reader) }
                        .transition(.opacity)
                }
            }
            .onChange(of: scrollRequest) { _, request in
                guard let request else { return }
                reader.scrollTo(request.id, anchor: anchor)
            }
        }
        .onChange(of: mode) { _, mode in
            // Another level (a pinch, or the selector): it opens at the symbol in the middle.
            guard mode.showsSymbols, mode != zoom else { return }
            switchAnchor = scroll.centeredID
            scroll.isPositioned = false  // until the new level has moved to the anchor
            withAnimation(.smooth(duration: 0.3)) { zoom = mode }
        }
        // For VoiceOver, which has no pinch.
        .accessibilityAction(named: "Zoom In") { zoomIn() }
        .accessibilityAction(named: "Zoom Out") { zoomOut() }
    }

    /// Where a symbol lands when it's brought into view: zoomed in, a symbol can be taller than
    /// the screen, so its start goes to the top; otherwise it's centered.
    private var anchor: UnitPoint {
        zoom == .code ? .top : .center
    }

    /// `scrollPosition(id:)` ignores a starting value during the first layout and opens on the
    /// first item, so move to the start explicitly: after a pinch, the symbol that was in the
    /// middle; otherwise the saved place. Search results start at the top, with the best match.
    private func moveToStart(_ reader: ScrollViewProxy) {
        let target = switchAnchor ?? (query.isEmpty ? initialID() ?? scroll.centeredID : nil)
        switchAnchor = nil
        if let target { reader.scrollTo(target, anchor: anchor) }
        scroll.centeredID = target
        scroll.isPositioned = true
    }

    /// The card in the middle, for `scrollPosition`: kept in the unobserved `scroll`, so a new
    /// card reaching the middle redraws nothing, and reported to `onCenteredSymbolChange` once
    /// the list has moved to where it starts (its first layout, on the first card, isn't).
    /// It's the same binding on every redraw: a new one makes SwiftUI apply the position again,
    /// which stops a fling dead (as the bar collapsing redraws this view mid-fling).
    private var centeredID: Binding<Int?> {
        scroll.report = onCenteredSymbolChange
        return scroll.centeredBinding
    }

    // MARK: Layouts

    private var cards: some View {
        LazyVStack(spacing: 12) {
            ForEach(symbols) { symbol in
                Button { onOpen(symbol) } label: {
                    SymbolCard(symbol: symbol)
                }
                .buttonStyle(.plain)
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

    /// Every symbol's whole code, edge to edge, each under a slim title that sticks while you
    /// read it. A file's own entry is just a title line before its symbols: tap it to read the
    /// whole file on its page. The text isn't selectable (it's plain `Text`, cheap to scroll
    /// through a big project); tap a symbol to open its page.
    ///
    /// Each symbol's code is rows of at most 30 lines, so a long function is laid out a piece at
    /// a time as it scrolls in. The code is prepared in the background (`CodeBlockStore`), and
    /// the next symbols' starts loading before they reach the screen.
    private var fullCode: some View {
        codeBlocks.symbols = symbols
        codeBlocks.openFile = openFile
        return LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
            ForEach(symbols) { symbol in
                Section {
                    if symbol.kind != .file {
                        SymbolCodeRows(block: codeBlocks.block(for: symbol),
                                       onAppear: { codeBlocks.prefetch(after: symbol) },
                                       onTap: { onOpen(symbol) })
                    }
                } header: {
                    // A file's title opens its page with the whole file (as its card does);
                    // a symbol's opens its page, like its code.
                    Button { onOpen(symbol) } label: {
                        SymbolTitle(symbol: symbol)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .scrollTargetLayout()
    }

    // MARK: Switching

    /// Pinching in (fingers together) zooms out a level; pinching out zooms in. Each pinch
    /// switches once, when it passes the threshold, and the change animates from there.
    private var pinch: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                guard !pinchHandled else { return }
                if value.magnification < 0.8 {
                    pinchHandled = true
                    zoomOut()
                } else if value.magnification > 1.25 {
                    pinchHandled = true
                    zoomIn()
                }
            }
            .onEnded { _ in pinchHandled = false }
    }

    private func zoomIn() {
        if let level = zoom.zoomedIn { withAnimation(.smooth(duration: 0.3)) { mode = level } }
    }

    /// From Files, out to Project.
    private func zoomOut() {
        if let level = zoom.zoomedOut { withAnimation(.smooth(duration: 0.3)) { mode = level } }
    }

    /// A row tapped in the Files level: in to the cards, at that symbol.
    private func showCard(_ symbol: CodeSymbol) {
        switchAnchor = symbol.id
        scroll.isPositioned = false
        withAnimation(.smooth(duration: 0.3)) {
            zoom = .symbols
            mode = .symbols
        }
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
        .scrollPosition(id: centeredID, anchor: .center)
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

/// Zoomed in: the slim title above a symbol's code (or a file's title line, before its symbols).
private struct SymbolTitle: View {
    let symbol: CodeSymbol

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol.kind.systemImage)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text(symbol.name)
                .font(symbol.kind == .file ? .subheadline.weight(.semibold) : .subheadline)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            if symbol.kind != .file {
                Text(symbol.lineLabel)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: symbol.kind == .file ? 36 : 28)
        .background(.bar)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(symbol.spokenDescription)
        .accessibilityHint(symbol.kind == .file ? Text("Opens the whole file") : Text("Opens its page"))
        .accessibilityAddTraits(.isHeader)
    }
}

/// One symbol's code at the Code level: `chunks` once it's prepared (`nil` until then, when
/// the preview stands in). Observed by that symbol's rows alone, so preparing it redraws
/// nothing else.
@Observable
private final class CodeBlock {
    let symbol: CodeSymbol
    private(set) var chunks: [String]?
    @ObservationIgnored private var isLoading = false

    init(symbol: CodeSymbol) {
        self.symbol = symbol
    }

    func load(openFile: URL) {
        guard chunks == nil, !isLoading else { return }
        isLoading = true
        let file = symbol.fileURL ?? openFile
        let range = symbol.range
        let preview = symbol.preview
        Task {
            chunks = await FileTextCache.shared.chunks(of: range, in: file) ?? [TabExpansion.expand(preview)]
        }
    }
}

/// The Code level's blocks, made as symbols scroll in and kept for this list. Not observed.
private final class CodeBlockStore {
    /// The list's symbols and the open file, set as the list is drawn.
    var symbols: [CodeSymbol] = []
    var openFile: URL?
    private var blocks: [Int: CodeBlock] = [:]
    /// Where each symbol is in `symbols`, for loading ahead (worked out when `symbols` changes).
    private var positions: [Int: Int] = [:]
    private var positionsKey: [Int?] = []

    /// How many of the next symbols to prepare when one comes into view.
    static let lookahead = 12

    func block(for symbol: CodeSymbol) -> CodeBlock {
        if let block = blocks[symbol.id] { return block }
        let block = CodeBlock(symbol: symbol)
        blocks[symbol.id] = block
        return block
    }

    /// A symbol came into view: prepare it and the next few, so they rarely change height on
    /// screen.
    func prefetch(after symbol: CodeSymbol) {
        guard let openFile else { return }
        let key: [Int?] = [symbols.count, symbols.first?.id, symbols.last?.id]
        if key != positionsKey {
            positionsKey = key
            positions = Dictionary(symbols.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        }
        guard let start = positions[symbol.id] else { return }
        let end = min(start + Self.lookahead + 1, symbols.count)
        for next in symbols[start..<end] where next.kind != .file {
            block(for: next).load(openFile: openFile)
        }
    }
}

/// Zoomed in: one symbol's code in the raw-text style, as rows of at most 30 lines. Each row is
/// its own item in the lazy list. The first row carries the symbol's id (as a scroll target);
/// the others have ids that can't be a symbol's (negative), which the list ignores.
private struct SymbolCodeRows: View {
    let block: CodeBlock
    let onAppear: @MainActor () -> Void
    let onTap: @MainActor () -> Void

    init(block: CodeBlock, onAppear: @escaping @MainActor () -> Void, onTap: @escaping @MainActor () -> Void) {
        self.block = block
        self.onAppear = onAppear
        self.onTap = onTap
    }

    private struct Row: Identifiable {
        let id: Int
        let text: String
        let isFirst: Bool
        let isLast: Bool
    }

    private var rows: [Row] {
        let symbol = block.symbol
        let chunks = block.chunks ?? [TabExpansion.expand(symbol.preview)]
        return chunks.enumerated().map { index, text in
            Row(id: index == 0 ? symbol.id : -1 - (symbol.id * 10_000 + index),
                text: text, isFirst: index == 0, isLast: index == chunks.count - 1)
        }
    }

    var body: some View {
        ForEach(rows) { row in
            Button(action: onTap) {
                Text(verbatim: row.text)
                    .font(.custom(RawTextStyle.fontName, fixedSize: RawTextStyle.fontSize))
                    .foregroundStyle(Color(uiColor: RawTextStyle.textColor))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, RawTextStyle.insets.left)
                    .padding(.top, row.isFirst ? 8 : 0)
                    .padding(.bottom, row.isLast ? 8 : 0)
                    .background(Color(uiColor: RawTextStyle.backgroundColor))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // One element per symbol for VoiceOver: its first row.
            .accessibilityLabel(block.symbol.spokenDescription)
            .accessibilityHint(Text("Opens its page"))
            .accessibilityHidden(!row.isFirst)
            .onAppear {
                if row.isFirst { onAppear() }
            }
        }
    }
}

private final class ScrollTracking {
    var tracker = BarCollapseTracker()
    var isUserScrolling = false
    /// The card in the middle of the screen.
    var centeredID: Int?
    /// The list has moved to where it starts, so `centeredID` changes are the reader's.
    var isPositioned = false
    /// Told about each new card in the middle (the latest closure from the view).
    var report: (@MainActor (Int) -> Void)?

    /// `centeredID` for `scrollPosition`, made once.
    private(set) lazy var centeredBinding = Binding<Int?>(
        get: { [unowned self] in self.centeredID },
        set: { [unowned self] id in
            // Negative ids are the Code level's later rows of a symbol, not symbols.
            guard id != self.centeredID, (id ?? 0) >= 0 else { return }
            self.centeredID = id
            if self.isPositioned, let id { self.report?(id) }
        }
    )
}

/// A request to bring a card into view in Symbols. A new request (a new `token`) scrolls
/// again, even to the same card.
nonisolated struct SymbolScrollRequest: Equatable, Sendable {
    let id: Int
    let token = UUID()

    init(_ id: Int) {
        self.id = id
    }
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
