import SwiftUI
import UIKit

/// The Code level: every top-level definition of the open file and its project, as an outline.
/// Each file has a title line, and each symbol a title with its declaration, which sticks to the
/// top while you read its code, edge to edge in the raw-text style under it. Tap a title to
/// collapse or expand it (a file's folds all its symbols); Collapse All (the bar's menu, or
/// pinching in) leaves just the titles, like a C header, and Expand All
/// brings the code back, keeping your place. Tap the code to open its page,
/// full screen (see `SymbolPager`).
///
/// Equatable, so the bar collapsing or expanding (which redraws the screen around it, several
/// times in a fling) doesn't redraw this list and its every symbol: use `.equatable()`.
struct SymbolsView: View, Equatable {
    let symbols: [CodeSymbol]
    /// The symbol search the list is filtered by ("" for none). Give each search its own list
    /// (`.id(query)`): the results start at the top, and clearing the search starts a fresh full
    /// list at the place from before the search. (One list kept through searches piles up the
    /// blocks it built for every set of results, and scrolling gets slower.)
    let query: String
    /// False while another mode covers the list (it stays alive to keep its place).
    let isActive: Bool
    /// The open file's text, for its symbols' code (ready at once).
    let ownText: NSString?
    /// Brings a symbol into view (the pager closing on another one). Each request scrolls once,
    /// even to the same symbol as last time.
    let scrollRequest: SymbolScrollRequest?
    /// Collapse All or Expand All, from the bar's menu. Each request runs once.
    let collapseRequest: CollapseRequest?
    /// The saved place in the list, where it starts.
    let initialID: @MainActor () -> Int?
    /// Another symbol reached the top of the screen (to save the place). It's reported without
    /// redrawing anything, here or in the screen around it: that happens many times a second.
    let onCenteredSymbolChange: @MainActor (CodeSymbol) -> Void
    /// Whether the bar is collapsed now. Read as the list scrolls rather than passed in, so the
    /// bar changing doesn't redraw the list.
    let isBarCollapsed: @MainActor () -> Bool
    let barTapCount: Int
    /// The open file, which symbols without a `fileURL` are in.
    let openFile: URL
    /// Where the list's files are, for what's collapsed (see `CollapsedCodeStore`).
    let collapseScope: String
    /// The top folder's name, in the grouped view (the project's).
    let rootFolderName: String
    let onOpen: @MainActor (CodeSymbol) -> Void
    /// A tap on a symbol's code: open its page with the tapped line where it was on screen.
    let onOpenAt: (@MainActor (CodeSymbol, PageAnchor) -> Void)?
    let onBarCollapsedChange: @MainActor (Bool) -> Void
    /// While searching: a swipe on the list closes the search field (the filter stays). That
    /// swipe only closes it: the list doesn't scroll and the bar doesn't shrink.
    let onCloseSearch: (@MainActor () -> Void)?
    /// For the long-press menus' Add to Album (`nil`: the file isn't in a project).
    let albumContext: AlbumMenuContext?
    /// The long-press menu's Show History: a file's info and history.
    /// Show History: a file's, and the symbol it was asked from (`nil` for a file's title).
    let onShowHistory: (@MainActor (URL, CodeSymbol?) -> Void)?
    /// A not-downloaded file's title was tapped: download it (its symbols then show).
    let onDownloadFile: (@MainActor (URL) -> Void)?
    /// Files downloading now (their titles show it).
    let downloadingFiles: Set<URL>
    /// `symbols`' folders, built with them away from the main thread (`nil`: grouped here).
    let folders: [FolderGroup]?
    /// A file's title came on screen before its symbols were known: read them now.
    let onNeedsSymbols: (@MainActor (URL) -> Void)?
    /// Open on a not-downloaded file's title: open the file (which downloads it).
    let onOpenURL: (@MainActor (URL) -> Void)?
    /// A blame's commit was tapped (its project and hash): show it.
    let onShowCommit: (@MainActor (String, String) -> Void)?
    /// A file with no symbols shows its whole text while unfolded. Only where the list has
    /// every file's symbols (the Code level): a results page or the stack has a file's title
    /// without them.
    let showsWholeFiles: Bool
    /// The hold menu's text items (Comment, Search, Occurrences, Copy, Share, as when selecting
    /// text on a page): what Search, Occurrences and Comment do. `nil`: just Copy and Share.
    let textActions: CodeTextActions?
    /// The list started or stopped scrolling (dragged, coasting, or moved to a symbol).
    let onScrollingChange: (@MainActor (Bool) -> Void)?

    /// The prepared code, per symbol (this list's ids).
    @State private var codeBlocks = CodeBlockStore()
    /// Each file's symbol count, for its title.
    @State private var fileCounts = FileSymbolCounts()
    /// The files by folder, while every file is folded.
    @State private var folderGroups = FolderGroupCache()
    /// The folders as a tree, for grouping a project with many.
    @State private var folderTrees = FolderTreeCache()
    /// Not observed: updated every scroll frame without redrawing anything.
    @State private var scroll = ScrollTracking()
    /// The line-number peek.
    @State private var peek = CodePeek()
    /// Who last changed the lines, for the peek's second stop.
    @State private var blames = BlameStore()
    /// The list follows the fingers while pinching, like Photos' grid (`PinchScale`).
    @State private var pinchZoom = PinchZoom()
    /// What's collapsed: the Code level's (shared, saved), or a results page's own.
    let collapsed: CollapsedCodeStore
    /// The list's width, which the code wraps in.
    @State private var codeWidth: CGFloat = 0
    @Environment(\.colorScheme) private var colorScheme
    /// The font and syntax colors: a new theme colors the blocks again.
    @Environment(\.codeTextStyle) private var codeTextStyle

    // An explicit init (not the memberwise one) so passing in an existing `@MainActor` closure
    // doesn't warn about converting it to `@Sendable`.
    init(symbols: [CodeSymbol], query: String, isActive: Bool,
         ownText: NSString?,
         scrollRequest: SymbolScrollRequest?,
         collapseRequest: CollapseRequest?,
         initialID: @escaping @MainActor () -> Int? = { nil },
         onCenteredSymbolChange: @escaping @MainActor (CodeSymbol) -> Void,
         isBarCollapsed: @escaping @MainActor () -> Bool, barTapCount: Int, openFile: URL,
         collapseScope: String,
         rootFolderName: String = "",
         onOpen: @escaping @MainActor (CodeSymbol) -> Void,
         onOpenAt: (@MainActor (CodeSymbol, PageAnchor) -> Void)? = nil,
         onBarCollapsedChange: @escaping @MainActor (Bool) -> Void,
         onCloseSearch: (@MainActor () -> Void)? = nil,
         albumContext: AlbumMenuContext? = nil,
         onShowHistory: (@MainActor (URL, CodeSymbol?) -> Void)? = nil,
         onDownloadFile: (@MainActor (URL) -> Void)? = nil,
         downloadingFiles: Set<URL> = [],
         folders: [FolderGroup]? = nil,
         onNeedsSymbols: (@MainActor (URL) -> Void)? = nil,
         onOpenURL: (@MainActor (URL) -> Void)? = nil,
         collapsed: CollapsedCodeStore = .shared,
         onShowCommit: (@MainActor (String, String) -> Void)? = nil,
         showsWholeFiles: Bool = false,
         textActions: CodeTextActions? = nil,
         onScrollingChange: (@MainActor (Bool) -> Void)? = nil) {
        self.onScrollingChange = onScrollingChange
        self.showsWholeFiles = showsWholeFiles
        self.textActions = textActions
        self.collapsed = collapsed
        self.onShowCommit = onShowCommit
        self.symbols = symbols
        self.query = query
        self.isActive = isActive
        self.ownText = ownText
        self.scrollRequest = scrollRequest
        self.collapseRequest = collapseRequest
        self.initialID = initialID
        self.onCenteredSymbolChange = onCenteredSymbolChange
        self.isBarCollapsed = isBarCollapsed
        self.barTapCount = barTapCount
        self.openFile = openFile
        self.collapseScope = collapseScope
        self.rootFolderName = rootFolderName
        self.onOpen = onOpen
        self.onOpenAt = onOpenAt
        self.onBarCollapsedChange = onBarCollapsedChange
        self.onCloseSearch = onCloseSearch
        self.albumContext = albumContext
        self.onShowHistory = onShowHistory
        self.onDownloadFile = onDownloadFile
        self.downloadingFiles = downloadingFiles
        self.folders = folders
        self.onNeedsSymbols = onNeedsSymbols
        self.onOpenURL = onOpenURL
    }

    /// What the list shows. The closures aren't compared: they reach the screen's state and
    /// model, which stay current.
    nonisolated static func == (lhs: SymbolsView, rhs: SymbolsView) -> Bool {
        lhs.symbols == rhs.symbols && lhs.query == rhs.query
            && lhs.isActive == rhs.isActive && lhs.ownText === rhs.ownText
            && lhs.scrollRequest == rhs.scrollRequest && lhs.collapseRequest == rhs.collapseRequest
            && lhs.barTapCount == rhs.barTapCount
            && lhs.openFile == rhs.openFile && lhs.collapseScope == rhs.collapseScope
            && lhs.rootFolderName == rhs.rootFolderName
            && (lhs.onCloseSearch == nil) == (rhs.onCloseSearch == nil)
            && lhs.albumContext == rhs.albumContext && (lhs.onShowHistory == nil) == (rhs.onShowHistory == nil)
            && lhs.downloadingFiles == rhs.downloadingFiles && lhs.collapsed === rhs.collapsed
            && lhs.folders?.count == rhs.folders?.count
            && (lhs.onShowCommit == nil) == (rhs.onShowCommit == nil)
            && lhs.showsWholeFiles == rhs.showsWholeFiles && (lhs.textActions == nil) == (rhs.textActions == nil)
    }

    var body: some View {
        ScrollViewReader { reader in
            scrollContainer { fullCode }
                .overlay(alignment: .leading) {
                    BlameStrip(peek: peek, blames: blames, onTap: openBlameCommit(at:),
                               onClone: cloneForBlame)
                }
                .modifier(PinchScale(zoom: pinchZoom))
                .onAppear { moveToStart(reader) }
                .simultaneousGesture(pinch(reader), including: isActive ? .all : .subviews)
                .onChange(of: scrollRequest) { _, request in
                    guard let request else { return }
                    reader.scrollTo(request.id, anchor: .top)
                }
                .onChange(of: collapseRequest) { _, request in
                    guard let request else { return }
                    setAllCollapsed(request.collapses, reader)
                }
        }
    }

    /// `scrollPosition(id:)` ignores a starting value during the first layout and opens on the
    /// first item, so move to the start explicitly: the saved place. Search results start at the
    /// top, with the best match.
    private func moveToStart(_ reader: ScrollViewProxy) {
        let target = query.isEmpty ? initialID() ?? scroll.centeredID : nil
        if let target { reader.scrollTo(target, anchor: .top) }
        scroll.centeredID = target
        scroll.isPositioned = true
    }

    /// The symbol at the top, kept in the unobserved `scroll`, so a new one reaching the top
    /// redraws nothing, and reported to `onCenteredSymbolChange` once the list has moved to
    /// where it starts (its first layout, on the first symbol, isn't).
    private var centeredID: Binding<Int?> {
        let report = onCenteredSymbolChange
        let blocks = codeBlocks
        // The symbol, found from its id with the list's own map (not by looking through it).
        scroll.report = { id in if let symbol = blocks.symbol(withID: id) { report(symbol) } }
        return scroll.centeredBinding
    }

    /// Collapse All or Expand All, keeping the symbol at the top where it is.
    private func setAllCollapsed(_ isCollapsed: Bool, _ reader: ScrollViewProxy) {
        let anchor = scroll.centeredID
        collapsed.setAllCollapsed(isCollapsed, scope: collapseScope)
        keep(anchor, reader)
    }

    /// Folds (or unfolds) every file to its title, keeping the file at the top where it is.
    private func setAllFilesFolded(_ isFolded: Bool, _ reader: ScrollViewProxy) {
        // The top symbol's file: its symbols go away.
        let anchor = scroll.centeredID.flatMap { id -> Int? in
            guard let index = symbols.firstIndex(where: { $0.id == id }) else { return id }
            return symbols[...index].last { $0.kind == .file }?.id ?? id
        }
        collapsed.setAllFilesFolded(isFolded, scope: collapseScope)
        keep(anchor, reader)
    }

    private func keep(_ anchor: Int?, _ reader: ScrollViewProxy) {
        guard let anchor else { return }
        Task { @MainActor in
            await Task.yield()  // once the list has its new heights
            reader.scrollTo(anchor, anchor: .top)
        }
    }

    // MARK: Layout

    /// Every symbol, each under a title that sticks while you read its code. A file's own
    /// entry is just a title line before its symbols.
    ///
    /// Each symbol is exactly one view, whatever it is (a file's entry is an empty one, and so
    /// is a collapsed or hidden symbol's code), so the lazy list can count them from their types
    /// alone. With an `if` here, it had to run this closure for every symbol of the project
    /// before showing anything, which took seconds on a big one. Nothing per symbol is made until
    /// it scrolls in: its block is made in its view's body. The open file's code is ready at
    /// once; other files' is prepared in the background, the symbols on screen first and the
    /// next few ahead of time (`CodeBlockStore`).
    private var fullCode: some View {
        codeBlocks.symbols = symbols
        codeBlocks.ownText = ownText
        codeBlocks.use(theme: codeTextStyle.theme, openFile: openFile)
        let collapsed = collapsed
        let openFile = openFile
        let scope = collapseScope
        codeBlocks.isShown = {
            !collapsed.isHidden($0, openFile: openFile, scope: scope)
                && !collapsed.isCollapsed($0, openFile: openFile, scope: scope)
        }
        codeBlocks.layoutKey = codeWidth > 0
            ? CodeLayoutKey(width: codeWidth - 2 * RawTextStyle.insets.left, style: codeTextStyle,
                            isDark: colorScheme == .dark)
            : nil
        return Group {
            if collapsed.areAllFilesFolded(scope: scope) {
                groupedByFolder
            } else {
                // A fresh list when Collapse All turns on or off (`keep` brings the top symbol
                // back): in the same one, every section changing at once made it match each
                // row's old place against its new one, over a second on a big list.
                outline
                    .id(collapsed.areAllCollapsed(scope: scope))
            }
        }
        .scrollTargetLayout()
        .modifier(PeekShift(peek: peek))  // the whole list slides while peeking
    }

    /// Each symbol under its title, which sticks while you read its code.
    private var outline: some View {
        LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
            ForEach(symbols) { symbol in
                Section {
                    code(for: symbol)
                } header: {
                    // Tap to collapse: a symbol's code, or a whole file's symbols.
                    header(for: symbol)
                }
            }
        }
    }

    /// Every file folded: the files grouped by folder, each folder's header (tap it to fold the
    /// folder) a plain row above its files. The titles stick, as in the outline: a file's, and
    /// a symbol's under a file unfolded here.
    private var groupedByFolder: some View {
        let collapsed = collapsed
        let scope = collapseScope
        let openFile = openFile
        let groups = folders ?? folderGroups.groups(of: symbols, openFile: openFile, scope: scope)
        let tree = folderTrees.tree(of: groups)
        let layout = FolderRows(groups: groups, tree: tree,
                                isGroupOpen: { collapsed.isGroupOpen($0, scope: scope) },
                                isFolded: { collapsed.isFolderFolded($0.path, scope: scope) },
                                // A folded file's symbols aren't items at all: thousands of empty
                                // ones made scrolling here lag.
                                isShown: { !collapsed.isHidden($0, openFile: openFile, scope: scope) })
        // Each header is an item of its own, like each symbol: made only as it scrolls in. (As
        // part of the symbol before it, every header after the last unfolded file was made at
        // once, thousands in a project as big as Linux: unfolding a folder took seconds.)
        // Every item is a section of exactly one view and one header, whatever it is (a folder's
        // header is the section's content, under an empty header), so the lazy list counts the
        // items from their types alone. With a header item that wasn't a section, it ran this
        // closure for every item in each layout pass: unfolding something hung for seconds.
        return LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
            ForEach(layout.items) { item in
                Section {
                    switch item.content {
                    case .header(let folder): folderRowHeader(folder)
                    case .symbol(let symbol, _): code(for: symbol)
                    }
                } header: {
                    switch item.content {
                    // One view all the same (an empty one would make the count vary), with no height.
                    case .header: Color.clear.frame(height: 0)
                    // In line with its folder's header (inside a group); the code stays edge to edge.
                    case .symbol(let symbol, let indent): header(for: symbol, indent: indent)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func folderRowHeader(_ header: FolderRows.Header) -> some View {
        switch header {
        case .folder(let group, let label, let indent): folderHeader(group, label: label, indent: indent)
        case .group(let node, let label, let indent): groupHeader(node, label: label, indent: indent)
        }
    }

    /// A group's header (a folder with many folders under it): tap it for its folders.
    private func groupHeader(_ node: FolderTree.Node, label: String, indent: Int) -> some View {
        let collapsed = collapsed
        let scope = collapseScope
        let isOpen = collapsed.isGroupOpen(node.path, scope: scope)
        let toggle = { withAnimation(.smooth(duration: 0.25)) { collapsed.toggleGroup(node.path, scope: scope) } }
        return FolderHeader(path: label, fileCount: node.fileCount, isFolded: !isOpen, indent: indent, onToggle: toggle)
            .contextMenu {
                Button(isOpen ? "Fold Folder" : "Unfold Folder",
                       systemImage: isOpen ? "chevron.right" : "chevron.down", action: toggle)
                commentOnFolder(node.path)
            } preview: {
                FolderPathPreview(path: rootFolderName + "/" + node.path, fileCount: node.fileCount)
            }
    }

    /// - Parameter label: its path from the group it's in ("" for the project's top files).
    private func folderHeader(_ group: FolderGroup, label: String, indent: Int) -> some View {
        let collapsed = collapsed
        let scope = collapseScope
        let isFolded = collapsed.isFolderFolded(group.path, scope: scope)
        let toggle = { withAnimation(.smooth(duration: 0.25)) { collapsed.toggleFolder(group.path, scope: scope) } }
        let fullPath = group.path.isEmpty ? rootFolderName : rootFolderName + "/" + group.path
        return FolderHeader(path: label.isEmpty ? rootFolderName : label, fileCount: group.fileCount,
                            isFolded: isFolded, indent: indent, onToggle: toggle)
            .contextMenu {
                folderMenu(group, isFolded: isFolded, toggle: toggle)
            } preview: {
                FolderPathPreview(path: fullPath, fileCount: group.fileCount)
            }
    }

    /// Comment on a folder (its path in the project): adds its path to the review.
    @ViewBuilder
    private func commentOnFolder(_ path: String) -> some View {
        if let onCommentOnFolder = textActions?.onCommentOnFolder {
            Button("Comment", systemImage: "text.bubble") { onCommentOnFolder(path) }
        }
    }

    /// A folder's long-press menu: fold or unfold it (or all of them), comment on it, and add
    /// its files to an album.
    @ViewBuilder
    private func folderMenu(_ group: FolderGroup, isFolded: Bool, toggle: @escaping () -> Void) -> some View {
        let collapsed = collapsed
        let scope = collapseScope
        Button(isFolded ? "Unfold Folder" : "Fold Folder",
               systemImage: isFolded ? "chevron.down" : "chevron.right", action: toggle)
        commentOnFolder(group.path)
        if let albumContext {
            let files = group.symbols.compactMap { symbol -> AlbumItem? in
                symbol.kind == .file ? AlbumItem(symbol, openFile: openFile) : nil
            }
            AlbumMenuItems(items: files, context: albumContext)
        }
        Section {
            Button("Fold All Folders", systemImage: "chevron.right.2") {
                withAnimation(.smooth(duration: 0.25)) { collapsed.setAllFoldersFolded(true, scope: scope) }
            }
            Button("Unfold All Folders", systemImage: "chevron.down.2") {
                withAnimation(.smooth(duration: 0.25)) { collapsed.setAllFoldersFolded(false, scope: scope) }
            }
        }
    }

    /// A file with no symbols (a README, a config file) shows its whole text under its title
    /// instead: otherwise unfolding it would show nothing.
    private func code(for symbol: CodeSymbol) -> some View {
        let isWholeFile = showsWholeFiles && symbol.kind == .file && symbol.isDownloaded && symbol.isIndexed
            && fileCounts.count(of: symbol, in: symbols) == 0
        return SymbolCode(symbol: symbol, isWholeFile: isWholeFile, store: codeBlocks, peek: peek, blames: blames,
                   collapsed: collapsed, openFile: openFile,
                   scope: collapseScope, contextMenu: contextMenu(for: symbol, part: .code), onTap: { onOpen(symbol) },
                   onTapAt: { anchor in
                       if let onOpenAt { onOpenAt(symbol, anchor) } else { onOpen(symbol) }
                   })
    }

    /// - Parameter indent: steps in, one step in from its folder's header inside a group.
    private func header(for symbol: CodeSymbol, indent: Int = 0) -> some View {
        CodeHeader(symbol: symbol, collapsed: collapsed, blocks: codeBlocks, peek: peek, openFile: openFile,
                   scope: collapseScope, indent: indent,
                   symbolCount: symbol.kind == .file ? fileCounts.count(of: symbol, in: symbols) : 0,
                   isDownloading: symbol.fileURL.map(downloadingFiles.contains) ?? false,
                   onDownload: onDownloadFile,
                   onNeedsSymbols: onNeedsSymbols,
                   contextMenu: contextMenu(for: symbol, part: .title))
    }

    /// The long-press menu of a symbol's title or code: a small preview (not a snapshot of what
    /// may be hundreds of lines), Open, Show History, the text items (see `CodeMenu`) and Add
    /// to Album.
    private func contextMenu(for symbol: CodeSymbol, part: CodeMenu.Part) -> CodeMenu {
        let onOpen = onOpen
        let onOpenURL = onOpenURL
        let blocks = codeBlocks
        return CodeMenu(symbol: symbol, part: part, openFile: openFile, albumContext: albumContext,
                        onOpen: { symbol in
                            // Not downloaded: open the file itself, which downloads it.
                            if !symbol.isDownloaded, let url = symbol.fileURL, let onOpenURL { onOpenURL(url) } else { onOpen(symbol) }
                        },
                        onShowHistory: onShowHistory,
                        textActions: textActions,
                        ownText: ownText,
                        codeRange: { blocks.shownRange(of: symbol) })
    }

    // MARK: Gestures

    /// A drag from the left edge peeks at the line numbers.
    private var peekGesture: some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .global)
            .onChanged { value in
                // From the left edge; or anywhere while the blame stays open (a swipe left closes it).
                guard peek.isLocked || value.startLocation.x <= CodePeek.edgeWidth else { return }
                peek.follow(value.translation)
            }
            .onEnded { value in
                if peek.isLocked || value.startLocation.x <= CodePeek.edgeWidth { peek.end() }
            }
    }

    /// Clone for Blame: the open file's info, where Clone is.
    private var cloneForBlame: (@MainActor () -> Void)? {
        guard let onShowHistory else { return nil }
        let file = openFile
        return { onShowHistory(file, nil) }
    }

    /// A tap in the blame (left of the code, while it stays open): that line's commit.
    private func openBlameCommit(at point: CGPoint) {
        guard let onShowCommit,
              let window = UIApplication.shared.connectedScenes.compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first,
              let found = CodePieceUIView.piece(atWindowY: point.y, in: window)?.blameHunk(atWindowY: point.y),
              !found.hunk.commitID.allSatisfy({ $0 == "0" })  // not committed
        else { return }
        onShowCommit(found.projectID, found.hunk.commitID)
    }

    /// Pinching in (fingers together) zooms out a step, one per pinch, when the fingers lift past
    /// the threshold: from the code, to every symbol collapsed to its title (an outline), every
    /// file folded to its title (grouped by folder), every folder folded to its header. There's
    /// no pinching back in: unfolding everything at once hung a project as big as Linux, so
    /// folders and files unfold from their long-press menus and titles.
    private func pinch(_ reader: ScrollViewProxy) -> some Gesture {
        MagnifyGesture()
            .onChanged { value in
                // Spreading doesn't unfold (that could unfold a huge project at once): the list
                // follows only fingers coming together.
                pinchZoom.follow(min(value.magnification, 1), anchor: value.startAnchor)
            }
            .onEnded { value in
                // One level, when the fingers lift past the threshold.
                if value.magnification < 0.8 {
                    let scope = collapseScope
                    if !collapsed.areAllCollapsed(scope: scope) {
                        setAllCollapsed(true, reader)
                    } else if !collapsed.areAllFilesFolded(scope: scope) {
                        setAllFilesFolded(true, reader)
                    } else if !collapsed.areAllFoldersFolded(scope: scope) {
                        withAnimation(.smooth(duration: 0.25)) { collapsed.setAllFoldersFolded(true, scope: scope) }
                    }
                }
                pinchZoom.settle()  // back as it was
            }
    }

    // MARK: Scrolling

    private var closesSearchOnSwipe: Bool {
        isActive && onCloseSearch != nil
    }

    /// The scroll view: its place, the bar collapsing as you scroll, the swipe that closes the
    /// search, and the peek.
    private func scrollContainer<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        ScrollView {
            content()
        }
        .modifier(PositionTracking(position: centeredID))
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
        .simultaneousGesture(peekGesture, including: isActive ? .all : .subviews)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
            if width != codeWidth { codeWidth = width }
        }
        .contentMargins(.bottom, FileBarMetrics.expandedHeight, for: .scrollContent)
        // The strip a peek uncovers is the code's background.
        .background(Color(uiColor: RawTextStyle.backgroundColor))
        .onScrollPhaseChange { _, phase, context in
            scroll.isUserScrolling = phase == .interacting || phase == .decelerating
            scroll.isCoasting = phase == .decelerating
            onScrollingChange?(phase != .idle)
            if phase == .interacting {
                scroll.tracker.beginDrag(at: context.geometry.contentOffset.y)
            }
        }
        // Gone mid-scroll, it never says it stopped: new lists would wait for good.
        .onDisappear { onScrollingChange?(false) }
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

/// Collapse All (`collapses`) or Expand All, from the bar's menu. A new request (a new `token`)
/// runs again, even the same one.
nonisolated struct CollapseRequest: Equatable, Sendable {
    let collapses: Bool
    let token = UUID()

    init(collapses: Bool) {
        self.collapses = collapses
    }
}

/// A title: tap it to collapse or expand what's under it (a symbol's code, or a file's
/// symbols); touch and hold for Add to Album (and on a file's, Collapse All and Expand All in
/// it). Hidden (but still one view) in a collapsed file. Observes the collapsed state itself, so
/// a tap redraws just the titles and blocks on screen, not the list.
private struct CodeHeader: View {
    let symbol: CodeSymbol
    let collapsed: CollapsedCodeStore
    /// For whether there's any code under the title.
    let blocks: CodeBlockStore
    /// While peeking, the title's line number shows beside it, like the code's.
    let peek: CodePeek
    let openFile: URL
    let scope: String
    /// Steps in (inside a group), for the title.
    let indent: Int
    /// A file's: how many symbols it has.
    let symbolCount: Int
    /// A not-downloaded file's: it's downloading.
    let isDownloading: Bool
    /// A not-downloaded file's title was tapped.
    let onDownload: (@MainActor (URL) -> Void)?
    /// A file's title showed before its symbols were known.
    let onNeedsSymbols: (@MainActor (URL) -> Void)?
    /// Touch and hold (the same menu as the code's).
    let contextMenu: CodeMenu

    var body: some View {
        VStack(spacing: 0) {
            if !collapsed.isHidden(symbol, openFile: openFile, scope: scope) {
                let isCollapsed = symbol.kind == .file
                    ? collapsed.isFileCollapsed(symbol.fileURL ?? openFile, scope: scope)
                    : collapsed.isCollapsed(symbol, openFile: openFile, scope: scope)
                Button {
                    toggle(isCollapsed)
                } label: {
                    if symbol.kind == .file {
                        FileTitle(name: symbol.name, count: symbolCount, isFolded: isCollapsed,
                                  isDownloaded: symbol.isDownloaded, isDownloading: isDownloading,
                                  isIndexed: symbol.isIndexed, indent: indent)
                            .onAppear {
                                if !symbol.isIndexed, let url = symbol.fileURL { onNeedsSymbols?(url) }
                            }
                    } else {
                        // Collapsed, the title has its line's number. Otherwise the code draws it,
                        // above its first line, so it scrolls away with the code instead of staying
                        // with the title pinned at the top (over the code's numbers).
                        SymbolTitle(symbol: symbol, isCollapsed: isCollapsed, canCollapse: canCollapse(isCollapsed),
                                    fileExtension: (symbol.fileURL ?? openFile).pathExtension, indent: indent)
                            .overlay(alignment: .leading) {
                                if isCollapsed { PeekLineNumber(peek: peek, line: symbol.line) }
                            }
                    }
                }
                .buttonStyle(.plain)
                .modifier(contextMenu)
            }
        }
    }

    /// Nothing to do for a one-line symbol: there's nothing under its title.
    private func toggle(_ isCollapsed: Bool) {
        if !symbol.isDownloaded {
            if let url = symbol.fileURL { onDownload?(url) }
            return
        }
        guard symbol.kind == .file || canCollapse(isCollapsed) else { return }
        withAnimation(.smooth(duration: 0.25)) { collapsed.toggle(symbol, openFile: openFile, scope: scope) }
    }

    /// Whether there's code under the title (not just its declaration, a one-line symbol), so
    /// it has a chevron. Known once its code is laid out (the same block its code shows; read
    /// here, so the title follows it); until then, or while it's collapsed, guessed from its
    /// first lines.
    private func canCollapse(_ isCollapsed: Bool) -> Bool {
        if symbol.kind == .lines { return true }
        if !isCollapsed, let layouts = blocks.block(for: symbol).layouts { return !layouts.isEmpty }
        let lines = symbol.preview.split(separator: "\n", omittingEmptySubsequences: false).dropFirst()
        return lines.contains { !$0.allSatisfy(\.isWhitespace) }
    }

    /// The first line of the definition (the preview starts at it, after any comment), without
    /// the spaces around it; the name if there's none.
    static func declaration(of symbol: CodeSymbol) -> String {
        let line = symbol.preview.prefix { $0 != "\n" }.trimmingCharacters(in: .whitespaces)
        return line.isEmpty ? symbol.name : line
    }
}

/// A file's title, bigger than a symbol's so it stands out: its name and how many symbols it
/// has, with a chevron (down while its symbols show, right while it's folded). Like the old
/// Files level's headers.
private struct FileTitle: View {
    let name: String
    let count: Int
    let isFolded: Bool
    /// Not downloaded: grayed, with a download mark (a tap downloads it), no chevron or count.
    var isDownloaded = true
    var isDownloading = false
    /// Its symbols aren't known yet (being read): no count until they are.
    var isIndexed = true
    /// Steps in, in line with its folder's header (inside a group).
    var indent = 0

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(isFolded ? 0 : 90))
                .opacity(isDownloaded ? 1 : 0)
            Text(name)
                .font(.headline)
                .foregroundStyle(isDownloaded ? .primary : .secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            if isDownloaded, isIndexed {
                Text("· \(count)")
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if isDownloading || !isIndexed {
                ProgressView()
            } else if !isDownloaded {
                Image(systemName: "arrow.down.circle")
                    .foregroundStyle(.tint)
            }
        }
        .padding(.leading, 16 + CGFloat(indent) * 16)
        .padding(.trailing, 16)
        .frame(minHeight: 44)
        .background(.bar)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isDownloaded ? Text("\(name), \(count) symbols") : Text("\(name), not downloaded"))
        .accessibilityValue(isDownloaded ? (isFolded ? Text("Folded") : Text("Unfolded")) : Text(verbatim: ""))
        .accessibilityHint(!isDownloaded ? Text("Downloads the file")
            : count == 0 ? (isFolded ? Text("Shows the file’s text") : Text("Hides the file’s text"))
            : isFolded ? Text("Shows the file’s symbols") : Text("Hides the file’s symbols"))
        .accessibilityAddTraits([.isHeader, .isButton])
    }
}

/// A folder's header while every file is folded: its path (the project's name for its top) and
/// how many files it has, with a chevron; tap it to fold the folder.
/// A folder's long-press preview: its whole path from the project's top (the header cuts a long
/// one short), wrapped, and how many files it has.
private struct FolderPathPreview: View {
    let path: String
    let fileCount: Int

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "folder.fill")
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 4) {
                Text(path)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                Text(fileCount == 1 ? "1 file" : "\(fileCount) files")
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(width: 320, alignment: .leading)
    }
}

private struct FolderHeader: View {
    let path: String
    let fileCount: Int
    let isFolded: Bool
    /// How many groups it's in (a step in for each).
    let indent: Int
    let onToggle: @MainActor () -> Void

    init(path: String, fileCount: Int, isFolded: Bool, indent: Int = 0, onToggle: @escaping @MainActor () -> Void) {
        self.path = path
        self.fileCount = fileCount
        self.isFolded = isFolded
        self.indent = indent
        self.onToggle = onToggle
    }

    var body: some View {
        // Bigger than a file's title, and on another background, so a folder doesn't look like
        // one of its files.
        Button(action: onToggle) {
            HStack(spacing: 10) {
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isFolded ? 0 : 90))
                Image(systemName: "folder.fill")
                    .foregroundStyle(.tint)
                Text(path)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.head)
                Text("· \(fileCount)")
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
            }
            .padding(.leading, 16 + CGFloat(indent) * 16)
            .padding(.trailing, 16)
            .frame(minHeight: 50)
            .background(Color(uiColor: .systemGroupedBackground))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(path), \(fileCount) files")
        .accessibilityValue(isFolded ? Text("Folded") : Text("Unfolded"))
        .accessibilityHint(isFolded ? Text("Shows the folder’s files") : Text("Hides the folder’s files"))
        .accessibilityAddTraits([.isHeader, .isButton])
    }
}

/// The grouped view's items, in order: each folder's header (a top folder's, showing only those),
/// then its shown symbols (a folded folder's aren't).
private struct FolderRows {
    /// A folder's header (its files' folder), or a group's (a folder with many folders under
    /// it, `FolderTree`).
    enum Header {
        /// `label`: its path from the group it's in ("" for the project's top files); `indent`:
        /// how many groups it's in.
        case folder(FolderGroup, label: String, indent: Int)
        case group(FolderTree.Node, label: String, indent: Int)

        var key: String {
            switch self {
            case .folder(let group, _, _): "folder:" + group.path
            case .group(let node, _, _): "group:" + node.path
            }
        }
    }

    /// One item of the list: a header, or a symbol that shows (under its title).
    struct Item: Identifiable {
        enum Content {
            case header(Header)
            /// `indent`: one step in from its folder's header (inside a group), for its title.
            case symbol(CodeSymbol, indent: Int)
        }

        /// A symbol's is its id (which the list's position goes by); a header's is negative, so it never meets one, and the position passes over it.
        let id: Int
        let content: Content
    }

    private(set) var items: [Item] = []

    /// - Parameters:
    ///   - tree: the folders as a tree, when the project has so many that it's a group itself:
    ///     each open group shows its folders (groups closed until opened, the others with all
    ///     their folders), then its own files' folder. `nil`: every folder, as they come.
    ///   - isShown: whether a symbol shows (not in a folded file).
    init(groups: [FolderGroup], tree: FolderTree?, isGroupOpen: (String) -> Bool,
         isFolded: (FolderGroup) -> Bool, isShown: (CodeSymbol) -> Bool) {
        func add(_ header: Header) {
            let hash = UInt(bitPattern: header.key.hashValue) >> 1
            items.append(Item(id: -1 - Int(hash), content: .header(header)))
        }
        /// `fileIndent`: its files', one step in from its header inside a group (0 outside).
        func add(_ group: FolderGroup, label: String, indent: Int, fileIndent: Int? = nil) {
            add(.folder(group, label: label, indent: indent))
            guard !isFolded(group) else { return }
            let fileIndent = fileIndent ?? indent + 1
            for symbol in group.symbols where isShown(symbol) {
                items.append(Item(id: symbol.id, content: .symbol(symbol, indent: fileIndent)))
            }
        }
        guard let tree, tree.root.isGroup else {
            for group in groups { add(group, label: group.path, indent: 0, fileIndent: 0) }
            return
        }
        func relative(_ path: String, to base: String) -> String {
            base.isEmpty ? path : String(path.dropFirst(base.count + 1))
        }
        func addChildren(of node: FolderTree.Node, indent: Int) {
            for path in node.children {
                guard let child = tree.node(path) else { continue }
                if child.isGroup {
                    add(.group(child, label: relative(child.path, to: node.path), indent: indent))
                    guard isGroupOpen(child.path) else { continue }
                    addChildren(of: child, indent: indent + 1)
                    if let own = child.group { add(own, label: child.name, indent: indent + 1) }
                } else {
                    for group in (child.group.map { [$0] } ?? []) + child.below {
                        add(group, label: relative(group.path, to: node.path), indent: indent)
                    }
                }
            }
        }
        addChildren(of: tree.root, indent: 0)
        if let own = tree.root.group { add(own, label: "", indent: 0) }
    }
}

/// The folders as a tree, worked out again only when they change. Not observed.
private final class FolderTreeCache {
    private var key: [Int] = []
    private var tree: FolderTree?

    func tree(of groups: [FolderGroup]) -> FolderTree {
        let key = [groups.count, groups.first?.symbols.first?.id ?? -1, groups.last?.symbols.last?.id ?? -1,
                   groups.reduce(0) { $0 + $1.symbols.count }]
        if key != self.key || tree == nil {
            self.key = key
            tree = FolderTree(groups)
        }
        return tree!
    }
}

/// The files by folder, worked out again only when the list changes. Not observed.
private final class FolderGroupCache {
    private var key: [String] = []
    private var groups: [FolderGroup] = []

    func groups(of symbols: [CodeSymbol], openFile: URL, scope: String) -> [FolderGroup] {
        let key = ["\(symbols.count)", "\(symbols.first?.id ?? -1)", "\(symbols.last?.id ?? -1)", scope,
                   openFile.absoluteString]
        if key != self.key {
            self.key = key
            groups = FolderGroup.groups(of: symbols, openFile: openFile, scope: scope)
        }
        return groups
    }
}

/// Each file's symbol count in the list, worked out again only when the list changes (not on
/// every redraw: a big project has tens of thousands of symbols). Not observed.
private final class FileSymbolCounts {
    private var key: [Int?] = []
    private var counts: [Int: Int] = [:]

    /// A file entry's count: the symbols after it, up to the next file.
    func count(of entry: CodeSymbol, in symbols: [CodeSymbol]) -> Int {
        // A new list is a new array (ids stay the same from one list to the next).
        let buffer = symbols.withUnsafeBufferPointer { Int(bitPattern: $0.baseAddress) }
        let key: [Int?] = [buffer, symbols.count, symbols.first?.id, symbols.last?.id]
        if key != self.key {
            self.key = key
            counts = [:]
            // One pass: a file's entry, then its symbols (the same `fileURL`).
            var current: (id: Int, file: URL?)?
            for symbol in symbols {
                if symbol.kind == .file {
                    current = (symbol.id, symbol.fileURL)
                    counts[symbol.id] = 0
                } else if let current, symbol.fileURL == current.file {
                    counts[current.id, default: 0] += 1
                }
            }
        }
        return counts[entry.id] ?? 0
    }
}

/// A title's line number while peeking: in the strip the slide uncovers, left of the title, its
/// right edge where the code's numbers end. Observes the peek itself, so only it redraws when a
/// peek starts and ends.
private struct PeekLineNumber: View {
    let peek: CodePeek
    let line: Int
    @Environment(\.codeTextStyle) private var codeTextStyle

    var body: some View {
        if peek.isActive {
            let width = CodePieceUIView.gutterWidth
            Text(verbatim: String(line))
                .font(Font(UIFont.monospacedDigitSystemFont(ofSize: max(9, codeTextStyle.size - 2), weight: .regular)))
                .foregroundStyle(Color(uiColor: .secondaryLabel))
                .lineLimit(1)
                .frame(width: width, alignment: .trailing)
                // Where the code's numbers end: a little left of the code, which starts at the inset.
                .offset(x: RawTextStyle.insets.left - CodePeek.numberGap - width)
                .accessibilityHidden(true)
        }
    }
}

/// A title, with a chevron (down while what's under it shows, right while it's collapsed): a
/// symbol's declaration, in the code font and colors, like a line of a C header (its code under
/// it starts after that line), or a file's name, before its symbols.
private struct SymbolTitle: View {
    /// A symbol's title's height with its declaration on one line.
    static let minHeight: CGFloat = 28

    let symbol: CodeSymbol
    let isCollapsed: Bool
    /// There's code under it: a one-line symbol has no chevron (there's nothing to collapse).
    let canCollapse: Bool
    /// The symbol's file's, for its colors.
    let fileExtension: String
    /// Steps in, in line with its folder's header (inside a group).
    var indent = 0
    @Environment(\.codeTextStyle) private var codeTextStyle

    var body: some View {
        // The declaration starts where the code under it does; its kind's icon and the chevron
        // are at the end.
        HStack(spacing: 6) {
            title
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            Image(systemName: symbol.kind.systemImage)
                .font(.caption)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            if canCollapse {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                    .frame(width: 10)
                    .accessibilityHidden(true)
            } else {
                Color.clear.frame(width: 10, height: 1)  // the icons stay lined up
            }
        }
        .padding(.leading, RawTextStyle.insets.left + CGFloat(indent) * 16)
        .padding(.trailing, 12)
        .padding(.vertical, 4)
        .frame(minHeight: symbol.kind == .file ? 36 : Self.minHeight)
        .background(.bar)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(symbol.spokenDescription)
        .accessibilityValue(canCollapse ? (isCollapsed ? Text("Collapsed") : Text("Expanded")) : Text(verbatim: ""))
        .accessibilityHint(canCollapse ? (isCollapsed ? Text("Shows its code") : Text("Hides its code")) : Text(verbatim: ""))
        .accessibilityAddTraits(canCollapse ? [.isHeader, .isButton] : .isHeader)
    }

    @ViewBuilder
    private var title: some View {
        switch symbol.kind {
        case .file:
            Text(symbol.name)
                .font(.subheadline.weight(.semibold))
        case .lines:
            Text(symbol.name)
                .font(codeTextStyle.swiftUIFont)
                .foregroundStyle(Color(uiColor: RawTextStyle.textColor))
        default:
            Text(SyntaxColoring.shared.attributed(CodeHeader.declaration(of: symbol), fileExtension: fileExtension,
                                                  theme: codeTextStyle.theme))
                .font(codeTextStyle.swiftUIFont)
                .foregroundStyle(Color(uiColor: RawTextStyle.textColor))
        }
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
        // The title shows the declaration: the code leaves its line out.
        let dropsDeclaration = symbol.kind != .file && symbol.kind != .lines
        let declarationLine = symbol.line
        task = Task {
            var texts = known
            if texts == nil {
                var plain = ownCode
                var fromPreview = false
                if plain == nil, let file {
                    if let loaded = await FileTextCache.shared.code(of: range, in: file, priority: priority) {
                        plain = CodePieces.trimmingTrailingWhitespace(loaded.code)
                        firstLine = loaded.firstLine
                    } else {
                        plain = TabExpansion.expand(preview)
                        fromPreview = true  // starts at the declaration
                    }
                }
                guard let plain else { return }
                // Its line in the code: after any comment above the definition.
                let dropped = dropsDeclaration ? (fromPreview ? 0 : max(0, declarationLine - firstLine)) : nil
                let made = await Task.detached(priority: priority) {
                    CodeBlock.texts(plain, leavingOut: dropped, fileExtension: fileExtension, highlighted: highlighted)
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

    /// The code's pieces, without line `dropped` (0-based; the declaration, which the title
    /// shows): the lines before it (a comment), then the ones after, each piece numbered with
    /// its lines in the whole code, so line numbers and taps stay right. Empty when that line was
    /// all there is.
    nonisolated static func texts(_ plain: String, leavingOut dropped: Int?, fileExtension: String,
                                  highlighted: Bool) -> [CodeText] {
        let lines = plain.components(separatedBy: "\n")
        guard let dropped, dropped < lines.count else {
            return CodePieces.texts(plain, fileExtension: fileExtension, highlighted: highlighted)
        }
        var result: [CodeText] = []
        if dropped > 0 {
            result += CodePieces.texts(lines[..<dropped].joined(separator: "\n"), fileExtension: fileExtension,
                                       highlighted: highlighted)
        }
        let after = lines[(dropped + 1)...].joined(separator: "\n")
        if !after.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            result += CodePieces.texts(after, fileExtension: fileExtension, highlighted: highlighted).map {
                CodeText(string: $0.string, runs: $0.runs, firstLine: $0.firstLine + dropped + 1)
            }
        }
        return result
    }

    /// What stands in until the code is laid out: its first lines, without the declaration.
    var placeholder: String {
        let preview = TabExpansion.expand(symbol.preview)
        guard symbol.kind != .file, symbol.kind != .lines else { return preview }
        return preview.split(separator: "\n", omittingEmptySubsequences: false).dropFirst().joined(separator: "\n")
    }

    /// Its code's height when its layout went, for that width and style: until it's laid out
    /// again, its stand-in keeps that height, so coming back into view doesn't push the list.
    private(set) var rememberedHeight: (key: CodeLayoutKey, height: CGFloat)?

    /// Off screen for a while: lets its layout go (it's made again when it comes back).
    func discardLayout() {
        if let layouts, let layoutKey {
            rememberedHeight = (layoutKey, layouts.reduce(0) { $0 + $1.height })
        }
        task?.cancel()
        layoutKey = nil
        layouts = nil
    }
}

/// The Code level's blocks, made as symbols scroll in and kept for this list. Not observed.
///
/// Kept by what they show (the file, the part of it, and how), not by the symbol's id: ids are
/// places in the list, and a new list (more of the project's symbols read) moves them, which
/// gave a row another symbol's block. This way the blocks still match, and stay ready.
private final class CodeBlockStore {
    private struct Key: Hashable {
        let file: URL?
        let range: NSRange
        let kind: CodeSymbol.Kind
        /// The declaration's, which a symbol's block leaves out (the title shows it).
        let line: Int
    }

    /// The list's symbols and the open file's text, set as the list is drawn.
    var symbols: [CodeSymbol] = []
    var ownText: NSString?
    private var blocks: [Key: CodeBlock] = [:]
    private var theme = SyntaxTheme.none
    private var openFileExtension = ""
    /// Where each symbol is in `symbols`, for loading ahead (worked out when `symbols` changes).
    private var positions: [Int: Int] = [:]
    private var positionsKey: [Int?] = []

    /// How many of the next symbols to prepare when one comes into view.
    static let lookahead = 6
    /// Whether a symbol's code shows (not collapsed): only those are prepared ahead.
    var isShown: @MainActor (CodeSymbol) -> Bool = { _ in true }

    /// The colors, and the open file (whose symbols have no `fileURL`). Another theme starts
    /// the blocks over.
    func use(theme: SyntaxTheme, openFile: URL) {
        if theme != self.theme {
            blocks.removeAll()
            laidOut.removeAll()
            laidOutOrder.removeAll()
        }
        self.theme = theme
        openFileExtension = openFile.pathExtension
    }

    func block(for symbol: CodeSymbol) -> CodeBlock {
        let range = shownRange(of: symbol)
        let key = Key(file: symbol.fileURL, range: range, kind: symbol.kind, line: symbol.line)
        if let block = blocks[key] { return block }
        let block = CodeBlock(symbol: symbol, range: range, ownText: ownText,
                              ownFirstLine: symbol.fileURL == nil ? ownLine(at: range.location) : nil,
                              fileExtension: symbol.fileURL?.pathExtension ?? openFileExtension, theme: theme)
        blocks[key] = block
        return block
    }

    /// What a symbol's block shows. A type (a class and its members) stops where its first
    /// member starts: the members follow as their own blocks, so the type isn't shown twice
    /// (and a big class isn't one huge block). Members follow their type in the full list;
    /// in search results, where they don't, the type is whole.
    func shownRange(of symbol: CodeSymbol) -> NSRange {
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

    /// The list's symbol with this id.
    func symbol(withID id: Int) -> CodeSymbol? {
        updatePositions()
        return positions[id].map { symbols[$0] }
    }

    private func updatePositions() {
        // A new list is a new array (ids alone don't tell: they stay the same from one to the next).
        let buffer = symbols.withUnsafeBufferPointer { Int(bitPattern: $0.baseAddress) }
        let key: [Int?] = [buffer, symbols.count, symbols.first?.id, symbols.last?.id]
        guard key != positionsKey else { return }
        positionsKey = key
        positions = Dictionary(symbols.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// What the blocks are laid out for: the width the code wraps at, the font and colors, and
    /// light or dark mode. `nil` until the list's width is known.
    var layoutKey: CodeLayoutKey?

    /// The most blocks kept laid out; the ones used longest ago let theirs go.
    static let laidOutLimit = 120
    private var laidOut: [ObjectIdentifier: CodeBlock] = [:]
    /// The laid-out blocks, the one used longest ago first.
    private var laidOutOrder: [ObjectIdentifier] = []

    /// A symbol came into view: prepare it first, then the next few below it and above it, so
    /// they're usually ready (at their final height) before they're on screen whichever way the
    /// list scrolls. (A block coming in above at its stand-in's height, then growing, pushed the
    /// list down: scrolling up jumped by about its height.)
    func appeared(_ symbol: CodeSymbol) {
        guard let key = layoutKey else { return }
        prepare(symbol, for: key, isVisible: true)
        updatePositions()
        guard let start = positions[symbol.id] else { return }
        let end = min(start + Self.lookahead + 1, symbols.count)
        for next in symbols[(start + 1)..<max(start + 1, end)] where next.kind != .file && isShown(next) {
            prepare(next, for: key, isVisible: false)
        }
        let begin = max(start - Self.lookahead, 0)
        for previous in symbols[begin..<start].reversed() where previous.kind != .file && isShown(previous) {
            prepare(previous, for: key, isVisible: false)
        }
    }

    func prepare(_ symbol: CodeSymbol, for key: CodeLayoutKey, isVisible: Bool) {
        let block = block(for: symbol)
        block.prepare(for: key, isVisible: isVisible)
        let id = ObjectIdentifier(block)
        laidOutOrder.removeAll { $0 == id }
        laidOutOrder.append(id)
        laidOut[id] = block
        while laidOutOrder.count > Self.laidOutLimit {
            laidOut.removeValue(forKey: laidOutOrder.removeFirst())?.discardLayout()
        }
    }
}

/// Zoomed in: one symbol's whole code in the raw-text style. A file's entry has nothing (its
/// title is all it has), unless the file has no symbols: then its whole text (`isWholeFile`). Always a single view, so the lazy list can count its items without
/// making them; its block is made here, once the symbol scrolls in.
private struct SymbolCode: View {
    let symbol: CodeSymbol
    /// A file's entry that has no symbols: its whole text shows while it's unfolded.
    let isWholeFile: Bool
    let store: CodeBlockStore
    let peek: CodePeek
    let blames: BlameStore
    let collapsed: CollapsedCodeStore
    let openFile: URL
    let scope: String
    /// Touch and hold (the same menu as the title's).
    let contextMenu: CodeMenu
    let onTap: @MainActor () -> Void
    let onTapAt: @MainActor (PageAnchor) -> Void
    /// Read so a new theme makes it take its new block.
    @Environment(\.codeTextStyle) private var codeTextStyle

    init(symbol: CodeSymbol, isWholeFile: Bool = false, store: CodeBlockStore, peek: CodePeek, blames: BlameStore,
         collapsed: CollapsedCodeStore, openFile: URL, scope: String, contextMenu: CodeMenu,
         onTap: @escaping @MainActor () -> Void, onTapAt: @escaping @MainActor (PageAnchor) -> Void) {
        self.symbol = symbol
        self.isWholeFile = isWholeFile
        self.store = store
        self.peek = peek
        self.blames = blames
        self.collapsed = collapsed
        self.openFile = openFile
        self.scope = scope
        self.contextMenu = contextMenu
        self.onTap = onTap
        self.onTapAt = onTapAt
    }

    var body: some View {
        VStack(spacing: 0) {
            if isShown {
                let block = store.block(for: symbol)
                SymbolCodeText(block: block, peek: peek, blames: blames, file: symbol.fileURL ?? openFile,
                               layoutKey: store.layoutKey, onTap: onTap, onTapAt: onTapAt)
                    .onAppear { store.appeared(symbol) }
                    // A new theme's block, while this is on screen.
                    .onChange(of: ObjectIdentifier(block)) { store.appeared(symbol) }
                    .modifier(contextMenu)
            }
        }
    }

    /// Unfolded: a symbol's code, or a whole file's (`isWholeFile`); a file's entry otherwise
    /// has nothing under its title.
    private var isShown: Bool {
        if isWholeFile {
            return !collapsed.isHidden(symbol, openFile: openFile, scope: scope)
                && !collapsed.isFileCollapsed(symbol.fileURL ?? openFile, scope: scope)
        }
        return symbol.kind != .file && !collapsed.isHidden(symbol, openFile: openFile, scope: scope)
            && !collapsed.isCollapsed(symbol, openFile: openFile, scope: scope)
    }
}

/// What the hold menu's Search, Occurrences and Comment do (see `SymbolsView.textActions`).
struct CodeTextActions {
    let onSearch: @MainActor (String) -> Void
    let onFindOccurrences: (@MainActor (OccurrenceTerm) -> Void)?
    /// A range of a file (`nil`: the open file), and the file's text the range is in.
    let onComment: (@MainActor (NSRange, URL?, NSString) -> Void)?
    /// A whole file (a file's title) or folder (its path in the project, "" for its top): just
    /// its path.
    var onCommentOnFile: (@MainActor (URL) -> Void)? = nil
    var onCommentOnFolder: (@MainActor (String) -> Void)? = nil
}

/// The long-press menu of a symbol's title and code: a small preview, then Open (its page) and
/// Show History; then the items selecting text on its page has (Comment, Search, Occurrences,
/// Copy, Share), for what was held: a title's text (its declaration, or a file's name), or for
/// the code, the title and its code together (all a block shows); then Add to Album.
private struct CodeMenu: ViewModifier {
    enum Part { case title, code }

    let symbol: CodeSymbol
    let part: Part
    let openFile: URL
    let albumContext: AlbumMenuContext?
    let onOpen: @MainActor (CodeSymbol) -> Void
    /// Show History: a file's, and the symbol it was asked from (`nil` for a file's title).
    let onShowHistory: (@MainActor (URL, CodeSymbol?) -> Void)?
    let textActions: CodeTextActions?
    /// The open file's text (its symbols have no `fileURL`).
    let ownText: NSString?
    /// The code's range in its file (what its block shows), worked out when an item is chosen.
    let codeRange: @MainActor () -> NSRange

    func body(content: Content) -> some View {
        let file = symbol.fileURL ?? openFile
        content.contextMenu {
            Section {
                Button("Open", systemImage: "arrow.up.left.and.arrow.down.right") { onOpen(symbol) }
                if albumContext != nil, let onShowHistory {
                    Button("Show History", systemImage: "clock.arrow.circlepath") {
                        onShowHistory(file, symbol.kind == .file ? nil : symbol)
                    }
                }
            }
            Section { textItems }
            if let albumContext {
                AlbumMenuItems(items: [AlbumItem(symbol, openFile: openFile)], context: albumContext,
                               download: symbol.isDownloaded ? nil : symbol.fileURL)
            }
        } preview: {
            CodeMenuPreview(symbol: symbol, fileExtension: file.pathExtension)
        }
    }

    /// Like the page's text menu. A title's text is known at once (from the list); the code's
    /// is read from its file when an item is chosen.
    @ViewBuilder private var textItems: some View {
        switch part {
        case .title:
            let text = symbol.kind == .file ? symbol.name : CodeHeader.declaration(of: symbol)
            if symbol.kind == .file, let onCommentOnFile = textActions?.onCommentOnFile {
                Button("Comment", systemImage: "text.bubble") { onCommentOnFile(symbol.fileURL ?? openFile) }
            }
            if symbol.kind != .file, symbol.isDownloaded, let onComment = textActions?.onComment {
                Button("Comment", systemImage: "text.bubble") {
                    withFileText { fileText in
                        if let range = Self.declarationRange(of: symbol, in: fileText) {
                            onComment(range, symbol.fileURL, fileText)
                        }
                    }
                }
            }
            if let onSearch = textActions?.onSearch, let query = SymbolSearch.query(fromSelection: text) {
                Button("Search", systemImage: "magnifyingglass") { onSearch(query) }
            }
            if let onFind = textActions?.onFindOccurrences, let term = Occurrences.term(fromSelection: text) {
                Button("Occurrences", systemImage: "text.magnifyingglass") {
                    onFind(OccurrenceTerm(text: term, identifier: nil))
                }
            }
            Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = text }
            Button("Share", systemImage: "square.and.arrow.up") { TextSharer.share(text) { _ in } }
        case .code:
            if let onComment = textActions?.onComment {
                Button("Comment", systemImage: "text.bubble") {
                    withCode { range, fileText in onComment(range, symbol.fileURL, fileText) }
                }
            }
            if let onSearch = textActions?.onSearch {
                Button("Search", systemImage: "magnifyingglass") {
                    withCode { range, fileText in
                        // A long selection searches with its start, as on a page.
                        let head = NSRange(location: range.location, length: min(range.length, 500))
                        if let query = SymbolSearch.query(fromSelection: fileText.substring(with: head)) {
                            onSearch(query)
                        }
                    }
                }
            }
            Button("Copy", systemImage: "doc.on.doc") {
                withCode { range, fileText in UIPasteboard.general.string = fileText.substring(with: range) }
            }
            Button("Share", systemImage: "square.and.arrow.up") {
                withCode { range, fileText in TextSharer.share(fileText.substring(with: range)) { _ in } }
            }
        }
    }

    /// The code's range and its file's text, once read (at once for the open file's).
    private func withCode(_ body: @escaping @MainActor (NSRange, NSString) -> Void) {
        let range = codeRange()
        withFileText { fileText in
            guard range.length > 0, NSMaxRange(range) <= fileText.length else { return }
            body(range, fileText)
        }
    }

    private func withFileText(_ body: @escaping @MainActor (NSString) -> Void) {
        guard let file = symbol.fileURL, file != openFile else {
            if let ownText { body(ownText) }
            return
        }
        Task {
            if let text = await FileTextCache.shared.text(of: file) { body(text as NSString) }
        }
    }

    /// The declaration's line (the title's text) in its file, without the spaces around it.
    static func declarationRange(of symbol: CodeSymbol, in text: NSString) -> NSRange? {
        var line = 1
        var index = 0
        while line < symbol.line {
            let found = text.range(of: "\n", options: .literal, range: NSRange(location: index, length: text.length - index))
            guard found.location != NSNotFound else { return nil }
            index = NSMaxRange(found)
            line += 1
        }
        var end = text.range(of: "\n", options: .literal, range: NSRange(location: index, length: text.length - index)).location
        if end == NSNotFound { end = text.length }
        let blanks = CharacterSet.whitespacesAndNewlines
        while index < end, let scalar = UnicodeScalar(text.character(at: index)), blanks.contains(scalar) { index += 1 }
        while end > index, let scalar = UnicodeScalar(text.character(at: end - 1)), blanks.contains(scalar) { end -= 1 }
        return end > index ? NSRange(location: index, length: end - index) : nil
    }
}

/// The long-press preview of a symbol's code: its title and first lines.
private struct CodeMenuPreview: View {

    let symbol: CodeSymbol
    let fileExtension: String
    @Environment(\.codeTextStyle) private var codeTextStyle

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(symbol.name, systemImage: symbol.kind.systemImage)
                .font(.headline)
                .lineLimit(1)
            Text(SyntaxColoring.shared.attributed(TabExpansion.expand(symbol.preview), fileExtension: fileExtension,
                                                  theme: codeTextStyle.theme))
                .font(codeTextStyle.previewFont)
                .foregroundStyle(Color(uiColor: RawTextStyle.textColor))
                .lineLimit(SymbolIndexer.previewLineCount)
        }
        .padding(16)
        .frame(width: 320, alignment: .leading)
        .background(Color(uiColor: RawTextStyle.backgroundColor))
    }
}

/// A symbol's code, redrawn when its block is laid out: drawn from Core Text layouts made in
/// the background (`CodePieceLayout`), so scrolling a block in neither measures nor shapes text.
/// Long code is several pieces of `CodePieces.linesPerPiece` lines in a lazy stack.
private struct SymbolCodeText: View {
    let block: CodeBlock
    let peek: CodePeek
    /// Its file's blame, while the peek shows it.
    let blames: BlameStore
    let file: URL
    let layoutKey: CodeLayoutKey?
    /// The word to mark: an occurrences page's, or else the identifier highlighted on pages.
    @Environment(\.codeMark) private var codeMark
    @Environment(HighlightState.self) private var highlights: HighlightState?
    /// Around the code, or before it's laid out: opens the page at the top.
    let onTap: @MainActor () -> Void
    /// On the code: opens the page at the line tapped.
    let onTapAt: @MainActor (PageAnchor) -> Void
    @Environment(\.codeTextStyle) private var codeTextStyle

    init(block: CodeBlock, peek: CodePeek, blames: BlameStore, file: URL, layoutKey: CodeLayoutKey?,
         onTap: @escaping @MainActor () -> Void, onTapAt: @escaping @MainActor (PageAnchor) -> Void) {
        self.block = block
        self.peek = peek
        self.blames = blames
        self.file = file
        self.layoutKey = layoutKey
        self.onTap = onTap
        self.onTapAt = onTapAt
    }

    /// Nothing under the title: a one-line symbol (its declaration is all of it).
    private var isEmpty: Bool {
        if let layouts = block.layouts { layouts.isEmpty } else { block.placeholder.isEmpty }
    }

    var body: some View {
        code
            .font(codeTextStyle.swiftUIFont)
            .foregroundStyle(Color(uiColor: RawTextStyle.textColor))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, RawTextStyle.insets.left)
            .padding(.vertical, isEmpty ? 0 : 8)
            .background(Color(uiColor: RawTextStyle.backgroundColor))
            .contentShape(Rectangle())
            .onTapGesture { tapped(onTap) }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(block.symbol.spokenDescription)
            .accessibilityHint(Text("Opens its page"))
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { onTap() }
            // Laid out again for another width, font, colors or appearance.
            .task(id: layoutKey) {
                if let layoutKey { block.prepare(for: layoutKey, isVisible: true) }
            }
            // The title's number, just above the first line: it scrolls with the code (the title
            // stays pinned at the top), level with the title in its row.
            .overlay(alignment: .topLeading) {
                PeekLineNumber(peek: peek, line: block.symbol.line)
                    .alignmentGuide(.top) { $0[.bottom] + SymbolTitle.minHeight / 2 - $0.height / 2 }
            }
            // The blame, the first time it shows for this file.
            .task(id: peek.isBlameShown) {
                if peek.isBlameShown { await blames.load(file) }
            }
    }

    /// A tap while the blame stays open closes it (and opens nothing).
    private func tapped(_ action: @MainActor () -> Void) {
        if peek.isLocked { peek.close() } else { action() }
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
        } else if isEmpty {
            Color.clear.frame(height: 0)
        } else if let remembered = block.rememberedHeight, remembered.key == layoutKey {
            // Laid out before: as tall as it was, so it doesn't grow once it's laid out again.
            Text(verbatim: block.placeholder)
                .frame(height: remembered.height, alignment: .topLeading)
                .clipped()
        } else {
            Text(verbatim: block.placeholder)
        }
    }

    /// While peeking, slid right with its line numbers.
    private func piece(_ layout: CodePieceLayout) -> some View {
        CodePieceView(layout: layout, firstFileLine: block.firstLine, isPeeking: peek.isActive,
                      blame: peek.isBlameShown ? blames.blame(for: file) : nil,
                      mark: codeMark ?? highlights?.current?.name)
            .contentShape(Rectangle())
            // Where in the piece (for the line) and where on screen (for where it goes on the page).
            .gesture(
                SpatialTapGesture(coordinateSpace: .local)
                    .simultaneously(with: SpatialTapGesture(coordinateSpace: .global))
                    .onEnded { value in
                        guard let local = value.first?.location, let screen = value.second?.location,
                              let found = layout.line(atY: local.y)
                        else { return tapped(onTap) }
                        tapped { onTapAt(PageAnchor(line: found.line, screenY: screen.y - (local.y - found.top))) }
                    }
            )
    }
}

/// Which symbol is at the top, for coming back to it. The blocks vary a lot in height (a
/// one-line macro, a 300-line function), and `scrollPosition(id:)` keeps its symbol anchored
/// while the ones scrolling in are measured, which stalled scrolling each time a long one came
/// in. So the list is only watched: the first symbol on screen is reported.
private struct PositionTracking: ViewModifier {
    let position: Binding<Int?>

    func body(content: Content) -> some View {
        content.onScrollTargetVisibilityChange(idType: Int.self, threshold: 0.01) { ids in
            if let first = ids.first { position.wrappedValue = first }
        }
    }
}

private final class ScrollTracking {
    var tracker = BarCollapseTracker()
    var isUserScrolling = false
    /// Decelerating after a fling.
    var isCoasting = false
    /// The symbol at the top of the screen.
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

/// The blame's strip, left of the line numbers, while it shows: over the list (it doesn't slide
/// with it). Open, a tap on a line's blame shows its commit; for a project that isn't cloned,
/// it offers Clone. Observes the peek and the blame itself, so the list doesn't redraw.
private struct BlameStrip: View {
    let peek: CodePeek
    let blames: BlameStore
    let onTap: @MainActor (CGPoint) -> Void
    /// Clone for Blame: the file's info, where Clone is.
    let onClone: (@MainActor () -> Void)?

    var body: some View {
        if peek.isBlameShown {
            ZStack {
                if peek.isLocked {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture(coordinateSpace: .global) { onTap($0) }
                }
                if blames.needsClone, let onClone {
                    Button(action: onClone) {
                        Label("Clone for Blame", systemImage: "arrow.down.circle")
                            .font(.footnote)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            .frame(width: CodePeek.blameWidth)
            .frame(maxHeight: .infinity)
            .transition(.opacity)
        }
    }
}
