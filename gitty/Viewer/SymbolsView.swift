import SwiftUI
import UIKit

/// Symbols mode: every top-level definition as a full-width card, like photos in Photos.
/// Tapping a card zooms into that symbol (see `SymbolPager`).
///
/// Pinching zooms in and out, like Photos, through the levels of `ViewMode` (the selector under
/// the bar follows):
/// - Files: each file's declarations, one line per symbol like a C header, under a sticky header
///   (its name and count; tap to fold it, or show it in Code). Tapping a line goes to its card.
///   Zooming out from here goes to Project.
/// - Symbols: the cards.
/// - Code: every symbol's whole code, edge to edge in the raw-text style, each under a slim
///   title that sticks to the top while you read it. Tap one to open its page.
///
/// Equatable, so the bar collapsing or expanding (which redraws the screen around it, several
/// times in a fling) doesn't redraw this list and its every symbol: use `.equatable()`.
struct SymbolsView: View, Equatable {
    let symbols: [CodeSymbol]
    /// The symbol search the list is filtered by ("" for none). Give each search its own list
    /// (`.id(query)`): the results start at the top, and clearing the search starts a fresh full
    /// list at the place from before the search. (One list kept through searches piles up the
    /// cards it built for every set of results, and scrolling gets slower.)
    let query: String
    /// False while another mode covers the list (it stays alive to keep its place).
    let isActive: Bool
    /// The open file's text, for its symbols' code at the Code level (ready at once).
    let ownText: NSString?
    /// Brings a card into view (the pager closing on another card). Each request scrolls once,
    /// even to the same card as last time.
    let scrollRequest: SymbolScrollRequest?
    /// The saved place in the list, where it starts.
    let initialID: @MainActor () -> Int?
    /// Another card reached the middle of the screen (to save the place). It's reported without
    /// redrawing anything, here or in the screen around it: that happens many times a second.
    let onCenteredSymbolChange: @MainActor (Int) -> Void
    /// Whether the bar is collapsed now. Read as the list scrolls rather than passed in, so the
    /// bar changing doesn't redraw the list.
    let isBarCollapsed: @MainActor () -> Bool
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
    /// For the long-press menus' Add to Album (`nil`: the file isn't in a project).
    let albumContext: AlbumMenuContext?
    /// Select at the Symbols level: while it's on, tapping a card chooses it.
    let selection: SymbolSelection

    /// The zoom level, shared with the selector under the bar (Project hides this view).
    @Binding var mode: ViewMode
    /// `mode` when this was made, for `==`.
    private let modeValue: ViewMode
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
    /// The Code level's line-number peek.
    @State private var peek = CodePeek()
    /// The list's width, which the Code level's code wraps in.
    @State private var codeWidth: CGFloat = 0
    @Environment(\.colorScheme) private var colorScheme
    /// The font and syntax colors: a new theme colors the Code level's blocks again.
    @Environment(\.codeTextStyle) private var codeTextStyle

    // An explicit init (not the memberwise one) so passing in an existing `@MainActor` closure
    // doesn't warn about converting it to `@Sendable`.
    init(symbols: [CodeSymbol], query: String, mode: Binding<ViewMode>, isActive: Bool,
         ownText: NSString?,
         scrollRequest: SymbolScrollRequest?,
         initialID: @escaping @MainActor () -> Int? = { nil },
         onCenteredSymbolChange: @escaping @MainActor (Int) -> Void,
         isBarCollapsed: @escaping @MainActor () -> Bool, barTapCount: Int, openFile: URL,
         onOpen: @escaping @MainActor (CodeSymbol) -> Void,
         onOpenFile: @escaping @MainActor (URL) -> Void,
         onBarCollapsedChange: @escaping @MainActor (Bool) -> Void,
         onCloseSearch: (@MainActor () -> Void)? = nil,
         albumContext: AlbumMenuContext? = nil,
         selection: SymbolSelection) {
        self.symbols = symbols
        self.query = query
        _mode = mode
        modeValue = mode.wrappedValue
        _zoom = State(initialValue: mode.wrappedValue.showsSymbols ? mode.wrappedValue : .files)
        self.isActive = isActive
        self.ownText = ownText
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
        self.albumContext = albumContext
        self.selection = selection
    }

    /// What the list shows. The closures aren't compared: they reach the screen's state and
    /// model, which stay current.
    nonisolated static func == (lhs: SymbolsView, rhs: SymbolsView) -> Bool {
        lhs.symbols == rhs.symbols && lhs.query == rhs.query && lhs.modeValue == rhs.modeValue
            && lhs.isActive == rhs.isActive && lhs.ownText === rhs.ownText
            && lhs.scrollRequest == rhs.scrollRequest && lhs.barTapCount == rhs.barTapCount
            && lhs.openFile == rhs.openFile && (lhs.onCloseSearch == nil) == (rhs.onCloseSearch == nil)
            && lhs.albumContext == rhs.albumContext
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
                reader.scrollTo(scrollTarget(for: request.id), anchor: anchor)
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

    /// What to scroll to for a symbol: itself, except at the Files level, where a whole file is
    /// one item (its declarations), so the file's.
    private func scrollTarget(for id: Int) -> Int {
        guard zoom == .files || zoom == .project else { return id }
        return groupCache.anchor(for: id, in: symbols, openFile: openFile, query: query) ?? id
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
        let target = (switchAnchor ?? (query.isEmpty ? initialID() ?? scroll.centeredID : nil)).map(scrollTarget(for:))
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
                // While selecting, a tap chooses the card instead of opening it.
                Button {
                    if selection.isActive { selection.toggle(symbol.id) } else { onOpen(symbol) }
                } label: {
                    SymbolCard(symbol: symbol, fileExtension: (symbol.fileURL ?? openFile).pathExtension)
                        .overlay(alignment: .bottomTrailing) { SelectionMark(selection: selection, id: symbol.id) }
                }
                .buttonStyle(.plain)
                .contextMenu {
                    CardMenu(item: albumItem(for: symbol), context: albumContext, selection: selection,
                             id: symbol.id)
                }
                // The margin is part of each scroll target, so every target spans the full
                // width and centering one never scrolls sideways.
                .padding(.horizontal, 16)
            }
        }
        .padding(.vertical, 12)
        .scrollTargetLayout()
    }

    /// One item per file, not per symbol: the file's declarations are a single block, so the
    /// lazy list has a file's worth of items to deal with, not a project's worth of symbols.
    private var groupedRows: some View {
        LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
            ForEach(groupCache.groups(of: symbols, openFile: openFile, query: query)) { group in
                let isFolded = folded.contains(group.file)
                Section {
                    // Always there (empty when folded): see `fullCode`.
                    FileDeclarations(symbols: isFolded ? [] : group.symbols,
                                     fileExtension: group.file.pathExtension, file: group.file,
                                     albumContext: albumContext) { showCard($0) }
                        .id(group.anchorID ?? -1)  // the file as a scroll target (never -1 here)
                } header: {
                    SymbolFileHeader(
                        name: group.file.displayFileName,
                        count: group.symbols.count,
                        isFolded: isFolded,
                        onToggle: { toggleFold(group.file) },
                        onOpenFile: { onOpenFile(group.file) }
                    )
                    .contextMenu {
                        if let albumContext { AlbumMenuItems(items: [.file(group.file)], context: albumContext) }
                    }
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
    /// Each symbol is exactly one view, whatever it is (a file's entry is an empty one), so the
    /// lazy list can count them from their types alone. With an `if` here, it had to run this
    /// closure for every symbol of the project before showing anything, which took seconds on a
    /// big one. Nothing per symbol is made until it scrolls in: its block is made in its view's
    /// body. The open file's code is ready at once; other files' is prepared in the background,
    /// the symbols on screen first and the next few ahead of time (`CodeBlockStore`).
    private var fullCode: some View {
        codeBlocks.symbols = symbols
        codeBlocks.ownText = ownText
        codeBlocks.use(theme: codeTextStyle.theme, openFile: openFile)
        codeBlocks.layoutKey = codeWidth > 0
            ? CodeLayoutKey(width: codeWidth - 2 * RawTextStyle.insets.left, style: codeTextStyle,
                            isDark: colorScheme == .dark)
            : nil
        return LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
            ForEach(symbols) { symbol in
                Section {
                    SymbolCode(symbol: symbol, store: codeBlocks, peek: peek, onTap: { onOpen(symbol) })
                } header: {
                    // A file's title opens its page with the whole file (as its card does);
                    // a symbol's opens its page, like its code.
                    Button { onOpen(symbol) } label: {
                        SymbolTitle(symbol: symbol)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        if let albumContext { AlbumMenuItems(items: [albumItem(for: symbol)], context: albumContext) }
                    }
                }
            }
        }
        .scrollTargetLayout()
        .modifier(PeekShift(peek: peek))  // the whole list slides while peeking
    }

    /// What adding this entry to an album adds.
    private func albumItem(for symbol: CodeSymbol) -> AlbumItem {
        AlbumItem(symbol, openFile: openFile)
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

    /// At the Code level: a drag from the left edge peeks at the line numbers.
    private var peekGesture: some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .global)
            .onChanged { value in
                guard value.startLocation.x <= CodePeek.edgeWidth else { return }
                peek.follow(value.translation.width)
            }
            .onEnded { value in
                if value.startLocation.x <= CodePeek.edgeWidth { peek.end() }
            }
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
        .modifier(PositionTracking(position: centeredID, byVisibility: zoom == .code))
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
        .simultaneousGesture(peekGesture, including: isActive && zoom == .code ? .all : .subviews)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
            if zoom == .code, width != codeWidth { codeWidth = width }
        }
        .contentMargins(.bottom, FileBarMetrics.expandedHeight, for: .scrollContent)
        // At the Code level, the strip a peek uncovers is the code's background.
        .background(Color(uiColor: zoom == .code ? RawTextStyle.backgroundColor : .systemGroupedBackground))
        .onScrollPhaseChange { _, phase, context in
            scroll.isUserScrolling = phase == .interacting || phase == .decelerating
            scroll.isCoasting = phase == .decelerating
            if phase == .interacting {
                scroll.tracker.beginDrag(at: context.geometry.contentOffset.y)
            }
        }
        .onScrollGeometryChange(for: ScrollGeometry.self) { $0 } action: { _, geometry in
            scroll.tracker.isCollapsed = isBarCollapsed()
            let change = scroll.tracker.scrolled(
                to: geometry.contentOffset.y,
                top: -geometry.contentInsets.top,
                bottom: geometry.contentSize.height - geometry.containerSize.height + geometry.contentInsets.bottom,
                isUserScrolling: scroll.isUserScrolling,
                isCoasting: scroll.isCoasting
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

    /// Each symbol's file's anchor (see `SymbolFileGroup.anchorID`), made with `groups`.
    private var anchors: [Int: Int] = [:]

    func groups(of symbols: [CodeSymbol], openFile: URL, query: String) -> [SymbolFileGroup] {
        let key = (query: query, count: symbols.count, first: symbols.first?.id, last: symbols.last?.id)
        if let old = self.key, old == key { return groups }
        self.key = key
        groups = SymbolFileGroup.groups(of: symbols, openFile: openFile)
        anchors = [:]
        for group in groups {
            guard let anchor = group.anchorID else { continue }
            if let entry = group.entryID { anchors[entry] = anchor }
            for symbol in group.symbols { anchors[symbol.id] = anchor }
        }
        return groups
    }

    func anchor(for id: Int, in symbols: [CodeSymbol], openFile: URL, query: String) -> Int? {
        _ = groups(of: symbols, openFile: openFile, query: query)
        return anchors[id]
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

/// A file's symbols at the Files level, like a C header: each one's declaration (the first line
/// of its definition), with its kind's icon, long ones wrapped. One view for the whole file;
/// tapping a line goes to that symbol's card.
private struct FileDeclarations: View {
    let symbols: [CodeSymbol]
    /// The file's, for its syntax colors.
    let fileExtension: String
    /// The file they're in, for Add to Album.
    let file: URL
    let albumContext: AlbumMenuContext?
    let onTap: @MainActor (CodeSymbol) -> Void
    @Environment(\.codeTextStyle) private var codeTextStyle

    init(symbols: [CodeSymbol], fileExtension: String, file: URL, albumContext: AlbumMenuContext?,
         onTap: @escaping @MainActor (CodeSymbol) -> Void) {
        self.symbols = symbols
        self.fileExtension = fileExtension
        self.file = file
        self.albumContext = albumContext
        self.onTap = onTap
    }

    /// Nothing when there are no symbols (folded, or a file without any), but always one view.
    var body: some View {
        VStack(spacing: 0) {
            if !symbols.isEmpty { lines }
        }
    }

    private var lines: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(symbols) { symbol in
                (Text(Image(systemName: symbol.kind.systemImage)).foregroundStyle(.tint)
                    + Text(verbatim: " ")
                    + Text(SyntaxColoring.shared.attributed(Self.declaration(of: symbol), fileExtension: fileExtension,
                                                            theme: codeTextStyle.theme)))
                    .font(codeTextStyle.swiftUIFont)
                    .foregroundStyle(Color(uiColor: RawTextStyle.textColor))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                    .onTapGesture { onTap(symbol) }
                    .contextMenu {
                        if let albumContext {
                            AlbumMenuItems(items: [AlbumItem(symbol, openFile: file)], context: albumContext)
                        }
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(symbol.spokenDescription)
                    .accessibilityHint(Text("Shows its card"))
                    .accessibilityAddTraits(.isButton)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
    }

    /// The first line of the definition (the preview starts at it, after any comment), without
    /// the spaces around it; the name if there's none.
    static func declaration(of symbol: CodeSymbol) -> String {
        let line = symbol.preview.prefix { $0 != "\n" }.trimmingCharacters(in: .whitespaces)
        return line.isEmpty ? symbol.name : line
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
            // No line number: peek at the numbers instead.
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

/// One symbol's code at the Code level, laid out (`layouts`) once it's read, colored and laid
/// out in the background; `nil` until then, while the preview stands in. Observed by that
/// symbol's view alone, so preparing it redraws nothing else.
@Observable
private final class CodeBlock {
    let symbol: CodeSymbol
    /// The code's pieces, laid out for `layoutKey`.
    private(set) var layouts: [CodePieceLayout]?
    /// The line of its file the code starts at, for the line peek.
    private(set) var firstLine = 1
    /// The part of the file shown: the symbol, or for a type, up to its first member.
    private let range: NSRange
    /// The open file's symbol's code, plain, ready at once.
    private let ownCode: String?
    private let fileExtension: String
    private let theme: SyntaxTheme
    /// Read and colored, once.
    @ObservationIgnored private var texts: [CodeText]?
    @ObservationIgnored private(set) var layoutKey: CodeLayoutKey?
    @ObservationIgnored private var task: Task<Void, Never>?

    init(symbol: CodeSymbol, range: NSRange, ownText: NSString?, ownFirstLine: Int?, fileExtension: String,
         theme: SyntaxTheme) {
        self.symbol = symbol
        self.range = range
        self.fileExtension = fileExtension
        self.theme = theme
        if symbol.fileURL == nil, let ownText, NSMaxRange(range) <= ownText.length {
            ownCode = CodePieces.trimmingTrailingWhitespace(TabExpansion.expand(ownText.substring(with: range)))
        } else {
            ownCode = nil
        }
        if let ownFirstLine { firstLine = ownFirstLine }
    }

    /// Lays the code out for `key` in the background (reading and coloring it first, the first
    /// time). On screen it goes first; the ones prepared ahead wait at a lower priority.
    func prepare(for key: CodeLayoutKey, isVisible: Bool) {
        guard key != layoutKey else { return }
        layoutKey = key
        task?.cancel()
        let priority: TaskPriority = isVisible ? .userInitiated : .utility
        let known = texts
        let file = symbol.fileURL
        let range = range
        let preview = symbol.preview
        let ownCode = ownCode
        let fileExtension = fileExtension
        let highlighted = theme != .none
        task = Task {
            var texts = known
            if texts == nil {
                var plain = ownCode
                if plain == nil, let file {
                    if let loaded = await FileTextCache.shared.code(of: range, in: file, priority: priority) {
                        plain = CodePieces.trimmingTrailingWhitespace(loaded.code)
                        firstLine = loaded.firstLine
                    } else {
                        plain = TabExpansion.expand(preview)
                    }
                }
                guard let plain else { return }
                let made = await Task.detached(priority: priority) {
                    CodePieces.texts(plain, fileExtension: fileExtension, highlighted: highlighted)
                }.value
                self.texts = made
                texts = made
            }
            guard let texts, !Task.isCancelled else { return }
            let laidOut = await Task.detached(priority: priority) {
                texts.map { CodePieceLayout($0, key: key) }
            }.value
            guard !Task.isCancelled, layoutKey == key else { return }
            layouts = laidOut
        }
    }

    /// Off screen for a while: lets its layout go (it's made again when it comes back).
    func discardLayout() {
        task?.cancel()
        layoutKey = nil
        layouts = nil
    }
}

/// The Code level's blocks, made as symbols scroll in and kept for this list. Not observed.
private final class CodeBlockStore {
    /// The list's symbols and the open file's text, set as the list is drawn.
    var symbols: [CodeSymbol] = []
    var ownText: NSString?
    private var blocks: [Int: CodeBlock] = [:]
    private var theme = SyntaxTheme.none
    private var openFileExtension = ""
    /// Where each symbol is in `symbols`, for loading ahead (worked out when `symbols` changes).
    private var positions: [Int: Int] = [:]
    private var positionsKey: [Int?] = []

    /// How many of the next symbols to prepare when one comes into view.
    static let lookahead = 6

    /// The colors, and the open file (whose symbols have no `fileURL`). Another theme starts
    /// the blocks over.
    func use(theme: SyntaxTheme, openFile: URL) {
        if theme != self.theme { blocks.removeAll() }
        self.theme = theme
        openFileExtension = openFile.pathExtension
    }

    func block(for symbol: CodeSymbol) -> CodeBlock {
        if let block = blocks[symbol.id] { return block }
        let range = shownRange(of: symbol)
        let block = CodeBlock(symbol: symbol, range: range, ownText: ownText,
                              ownFirstLine: symbol.fileURL == nil ? ownLine(at: range.location) : nil,
                              fileExtension: symbol.fileURL?.pathExtension ?? openFileExtension, theme: theme)
        blocks[symbol.id] = block
        return block
    }

    /// What a symbol's block shows. A type (a class and its members) stops where its first
    /// member starts: the members follow as their own blocks, so the type isn't shown twice
    /// (and a big class isn't one huge block). Members follow their type in the full list;
    /// in search results, where they don't, the type is whole.
    private func shownRange(of symbol: CodeSymbol) -> NSRange {
        updatePositions()
        guard let position = positions[symbol.id], position + 1 < symbols.count else { return symbol.range }
        let next = symbols[position + 1]
        guard next.kind != .file, next.kind != .lines, next.fileURL == symbol.fileURL,
              next.range.location > symbol.range.location, NSMaxRange(next.range) <= NSMaxRange(symbol.range)
        else { return symbol.range }
        return NSRange(location: symbol.range.location, length: next.range.location - symbol.range.location)
    }

    /// Where each of the open file's lines starts, worked out once per text.
    private var ownLineStarts: (text: ObjectIdentifier, starts: [Int])?

    /// The open file's line at a place in its text.
    private func ownLine(at location: Int) -> Int {
        guard let ownText else { return 1 }
        if ownLineStarts?.text != ObjectIdentifier(ownText) {
            var starts = [0]
            var index = 0
            while index < ownText.length {
                let found = ownText.range(of: "\n", options: .literal,
                                          range: NSRange(location: index, length: ownText.length - index))
                guard found.location != NSNotFound else { break }
                index = NSMaxRange(found)
                starts.append(index)
            }
            ownLineStarts = (ObjectIdentifier(ownText), starts)
        }
        let starts = ownLineStarts?.starts ?? [0]
        var low = 0, high = starts.count
        while low < high {
            let middle = (low + high) / 2
            if starts[middle] <= location { low = middle + 1 } else { high = middle }
        }
        return max(1, low)
    }

    private func updatePositions() {
        let key: [Int?] = [symbols.count, symbols.first?.id, symbols.last?.id]
        guard key != positionsKey else { return }
        positionsKey = key
        positions = Dictionary(symbols.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// What the blocks are laid out for: the width the code wraps at, the font and colors, and
    /// light or dark mode. `nil` until the list's width is known.
    var layoutKey: CodeLayoutKey?

    /// The most blocks kept laid out; the ones used longest ago let theirs go.
    static let laidOutLimit = 120
    private var laidOut: [Int] = []

    /// A symbol came into view: prepare it first, then the next few, so they're usually ready
    /// (at their final height) before they're on screen.
    func appeared(_ symbol: CodeSymbol) {
        guard let key = layoutKey else { return }
        prepare(symbol, for: key, isVisible: true)
        updatePositions()
        guard let start = positions[symbol.id] else { return }
        let end = min(start + Self.lookahead + 1, symbols.count)
        for next in symbols[(start + 1)..<max(start + 1, end)] where next.kind != .file {
            prepare(next, for: key, isVisible: false)
        }
    }

    func prepare(_ symbol: CodeSymbol, for key: CodeLayoutKey, isVisible: Bool) {
        block(for: symbol).prepare(for: key, isVisible: isVisible)
        laidOut.removeAll { $0 == symbol.id }
        laidOut.append(symbol.id)
        while laidOut.count > Self.laidOutLimit {
            blocks[laidOut.removeFirst()]?.discardLayout()
        }
    }
}

/// Zoomed in: one symbol's whole code in the raw-text style, or nothing for a file's entry (its
/// title is all it has). Always a single view, so the lazy list can count its items without
/// making them; its block is made here, once the symbol scrolls in.
private struct SymbolCode: View {
    let symbol: CodeSymbol
    let store: CodeBlockStore
    let peek: CodePeek
    let onTap: @MainActor () -> Void
    /// Read so a new theme makes it take its new block.
    @Environment(\.codeTextStyle) private var codeTextStyle

    init(symbol: CodeSymbol, store: CodeBlockStore, peek: CodePeek, onTap: @escaping @MainActor () -> Void) {
        self.symbol = symbol
        self.store = store
        self.peek = peek
        self.onTap = onTap
    }

    var body: some View {
        VStack(spacing: 0) {
            if symbol.kind != .file {
                let block = store.block(for: symbol)
                SymbolCodeText(block: block, peek: peek, layoutKey: store.layoutKey, onTap: onTap)
                    .onAppear { store.appeared(symbol) }
                    // A new theme's block, while this is on screen.
                    .onChange(of: ObjectIdentifier(block)) { store.appeared(symbol) }
            }
        }
    }
}

/// A symbol's code, redrawn when its block is laid out: drawn from Core Text layouts made in
/// the background (`CodePieceLayout`), so scrolling a block in neither measures nor shapes text.
/// Long code is several pieces of `CodePieces.linesPerPiece` lines in a lazy stack.
private struct SymbolCodeText: View {
    let block: CodeBlock
    let peek: CodePeek
    let layoutKey: CodeLayoutKey?
    let onTap: @MainActor () -> Void
    @Environment(\.codeTextStyle) private var codeTextStyle

    init(block: CodeBlock, peek: CodePeek, layoutKey: CodeLayoutKey?, onTap: @escaping @MainActor () -> Void) {
        self.block = block
        self.peek = peek
        self.layoutKey = layoutKey
        self.onTap = onTap
    }

    var body: some View {
        code
            .font(codeTextStyle.swiftUIFont)
            .foregroundStyle(Color(uiColor: RawTextStyle.textColor))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, RawTextStyle.insets.left)
            .padding(.vertical, 8)
            .background(Color(uiColor: RawTextStyle.backgroundColor))
            .contentShape(Rectangle())
            .onTapGesture { onTap() }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(block.symbol.spokenDescription)
            .accessibilityHint(Text("Opens its page"))
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { onTap() }
            // Laid out again for another width, font, colors or appearance.
            .task(id: layoutKey) {
                if let layoutKey { block.prepare(for: layoutKey, isVisible: true) }
            }
    }

    @ViewBuilder
    private var code: some View {
        if let layouts = block.layouts, layouts.count > 1 {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(layouts.indices, id: \.self) { index in
                    piece(layouts[index])
                }
            }
        } else if let layout = block.layouts?.first {
            piece(layout)
        } else {
            Text(verbatim: TabExpansion.expand(block.symbol.preview))
        }
    }

    /// While peeking, slid right with its line numbers.
    private func piece(_ layout: CodePieceLayout) -> some View {
        CodePieceView(layout: layout, firstFileLine: block.firstLine, isPeeking: peek.isActive)
    }
}

/// Which symbol is in the middle (at the Code level, at the top), for coming back to it.
///
/// The other levels use `scrollPosition(id:)`. The Code level's blocks vary a lot in height (a
/// one-line macro, a 300-line function), and `scrollPosition` keeps its symbol anchored while
/// the ones scrolling in are measured, which stalled scrolling each time a long one came in.
/// There, the list is only watched: the first symbol on screen is reported.
private struct PositionTracking: ViewModifier {
    let position: Binding<Int?>
    let byVisibility: Bool

    func body(content: Content) -> some View {
        if byVisibility {
            content.onScrollTargetVisibilityChange(idType: Int.self, threshold: 0.01) { ids in
                if let first = ids.first { position.wrappedValue = first }
            }
        } else {
            content.scrollPosition(id: position, anchor: .center)
        }
    }
}

private final class ScrollTracking {
    var tracker = BarCollapseTracker()
    var isUserScrolling = false
    /// Decelerating after a fling.
    var isCoasting = false
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
            guard id != self.centeredID else { return }
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

/// A card's long-press menu: Add to Album, and Select (not while selecting already).
private struct CardMenu: View {
    let item: AlbumItem
    let context: AlbumMenuContext?
    let selection: SymbolSelection
    let id: Int

    var body: some View {
        // Selecting is for albums: only for a project's files.
        if !selection.isActive, let context {
            AlbumMenuItems(items: [item], context: context)
            Button("Select", systemImage: "checkmark.circle") { selection.begin(with: id) }
        }
    }
}

/// One symbol in the list: its kind, name, line and the first lines of its code.
struct SymbolCard: View {
    let symbol: CodeSymbol
    /// The symbol's file's, for its syntax colors.
    var fileExtension = ""
    @Environment(\.codeTextStyle) private var codeTextStyle

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
            Text(SyntaxColoring.shared.attributed(symbol.preview, fileExtension: fileExtension,
                                                  theme: codeTextStyle.theme))
                .font(codeTextStyle.previewFont)
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
