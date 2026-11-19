import SwiftUI
import UIKit

/// The cards (pagers) and the search results pushed over the Code level, in the order they
/// were opened: tapping a symbol in the list opens a card, searching (in the bar, or Search on
/// a card) pushes the results, and a result pushes another card on top.
/// Nothing is ever taken out from under the page on screen (that cost the card above its
/// swipe-down): every results page stays, but only the latest keeps its results. An older one
/// keeps its query and searches again when you come back to it.
enum CardRoute: Hashable {
    case card(UUID)
    case results(UUID)
}

/// A results page in the stack: what it searches for, and what it zooms out of (the card it
/// was searched from, or the Code level).
struct StackedResults {
    var query: String
    let source: AnyHashable
    /// Its place in the stack, as a card's.
    let depth: Int
}

/// What a card in the stack pages through, and where it opened.
struct StackedCard {
    let symbols: [CodeSymbol]
    let initialID: Int
    let anchor: PageAnchor?
    /// What it zooms out of, and back into when it's swiped down.
    let zoomSource: AnyHashable
    /// Its place in the stack: 1 for the card opened from the list, then up by one for each
    /// page on top (results pages too). Nothing under a page is ever taken out, so it stays.
    let depth: Int
}

/// A search, for a results page: the files whose name contains it (each with all its symbols),
/// then the symbols it matches (in the album, if one is shown). The Code list itself is never
/// filtered.
@MainActor @Observable
final class StackSearch {
    /// Its results page's (`CardRoute.results`).
    let id: UUID
    /// What its results page zooms out of.
    let source: AnyHashable
    /// Edited on the results page: the search runs again.
    var query: String {
        didSet { if query != oldValue { start() } }
    }
    private(set) var results: [CodeSymbol] = []
    /// The query `results` are for.
    private(set) var resultsQuery = ""
    /// Up with each set of matches: the results list is a fresh list for each (see
    /// `CodeDocumentModel.resultsVersion`).
    private(set) var version = 0
    private(set) var isSearching = false
    /// What's collapsed on its page: its own, starting with nothing, so every result shows
    /// (the Code level's folded files hid theirs, under a count that included them).
    @ObservationIgnored let collapsed = CollapsedCodeStore.temporary()
    /// Its page opens with the search field focused (a search from the bar, which starts empty
    /// and shows results as you type).
    @ObservationIgnored let startsEditing: Bool

    @ObservationIgnored private let model: CodeDocumentModel
    @ObservationIgnored private var task: Task<Void, Never>?

    init(id: UUID = UUID(), query: String, source: AnyHashable, startsEditing: Bool = false,
         model: CodeDocumentModel) {
        self.id = id
        self.startsEditing = startsEditing
        self.query = query
        self.source = source
        self.model = model
        start()
    }

    /// Nothing found yet, but the search hasn't finished.
    var isPending: Bool {
        isSearching || resultsQuery != query
    }

    private func start() {
        task?.cancel()
        task = nil
        let query = query
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            results = []
            resultsQuery = query
            version += 1
            isSearching = false
            return
        }
        isSearching = true
        let model = model
        task = Task { [weak self] in
            // The symbols may still be getting ready (a search right after opening a file).
            guard let stream = await model.searchStream(query), !Task.isCancelled else {
                self?.isSearching = false
                return
            }
            let all = model.listSymbols
            let album: Set<Int>? = model.activeAlbum == nil ? nil : Set(model.albumSymbols.map(\.id))
            let files = await Task.detached(priority: .userInitiated) {
                FileNameSearch.symbols(inFilesNamed: query, in: all, maxRank: 5)
            }.value
            for await matches in stream {
                guard !Task.isCancelled, let self else { return }
                let shown = album.map { ids in matches.filter { ids.contains($0.id) } } ?? matches
                var ids = Set(files.map(\.id))
                self.results = files + shown.filter { ids.insert($0.id).inserted }
                self.resultsQuery = query
                self.version += 1
            }
            guard !Task.isCancelled, let self else { return }
            if self.results.isEmpty, self.resultsQuery != query {  // nothing came at all
                self.resultsQuery = query
                self.version += 1
            }
            self.isSearching = false
        }
    }
}

/// A search's results, stacked over the card it was made from (or the Code level): the same code
/// blocks as the Code level's, with the search in a capsule at the bottom (tap it to change the
/// search; the results follow as you type). Tap a result's code for its card, stacked on top.
/// Swipe down to go back.
struct StackResultsView<Results: View>: View {
    @Bindable var search: StackSearch
    /// Its place in the stack, shown before the search from 2 up.
    let stackDepth: Int
    let stackActions: StackActions?
    /// The results shown: the ones not folded away on the page (pinch in to fold files), so
    /// the count is what's there.
    let shownCount: @MainActor ([CodeSymbol]) -> Int
    /// The list, for the results so far and their query.
    @ViewBuilder let list: (_ symbols: [CodeSymbol], _ query: String, _ onScrollDown: @escaping @MainActor (Bool) -> Void) -> Results

    @State private var isEditing: Bool
    /// Scrolling down hides the capsule; scrolling up shows it.
    @State private var isBarHidden = false
    /// The keyboard's top in the window (`nil`: hidden), and the page's bottom (above the home
    /// indicator), for `keyboardOverlap`.
    @State private var keyboardTop: CGFloat?
    @State private var pageBottom: CGFloat = 0
    @Environment(\.dismiss) private var dismiss

    init(search: StackSearch, stackDepth: Int, stackActions: StackActions?,
         shownCount: @escaping @MainActor ([CodeSymbol]) -> Int,
         @ViewBuilder list: @escaping (_ symbols: [CodeSymbol], _ query: String,
                                       _ onScrollDown: @escaping @MainActor (Bool) -> Void) -> Results) {
        self.search = search
        self.stackDepth = stackDepth
        self.stackActions = stackActions
        self.shownCount = shownCount
        self.list = list
        _isEditing = State(initialValue: search.startsEditing)
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            content
            bottom
                .animation(.smooth(duration: 0.25), value: isBarHidden)
                .padding(.bottom, keyboardOverlap)
        }
        // On a pushed page, SwiftUI made room for the keyboard twice (the field floated far
        // above it): the room is worked out here instead, from where the keyboard is.
        .ignoresSafeArea(.keyboard)
        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).maxY } action: { pageBottom = $0 }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) {
            keyboardMoved($0, hiding: false)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) {
            keyboardMoved($0, hiding: true)
        }
        .toolbar(.hidden, for: .navigationBar)
        // Closing the field before typing anything: nothing to show, so back to where it was.
        .onChange(of: isEditing) {
            if !isEditing, isQueryEmpty { dismiss() }
        }
    }

    /// How much of the page the keyboard covers: the field sits right on top of it.
    private var keyboardOverlap: CGFloat {
        guard let keyboardTop else { return 0 }
        return max(0, pageBottom - keyboardTop)
    }

    /// The keyboard's new top (in the window), as it moves, with its own timing.
    private func keyboardMoved(_ notification: Notification, hiding: Bool) {
        let info = notification.userInfo
        let frame = (info?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue
        let duration = (info?[UIResponder.keyboardAnimationDurationUserInfoKey] as? NSNumber)?.doubleValue ?? 0.25
        let top: CGFloat? = hiding ? nil : frame.map(\.minY)
        guard top != keyboardTop else { return }
        withAnimation(.smooth(duration: max(duration, 0.1))) { keyboardTop = top }
    }

    private var isQueryEmpty: Bool {
        search.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @ViewBuilder
    private var content: some View {
        if isQueryEmpty {
            Color(uiColor: .systemGroupedBackground)  // waiting for the first letters
        } else {
            SearchResultsContent(search: search) { symbols, query in
                list(symbols, query) { isBarHidden = $0 }
            }
        }
    }

    @ViewBuilder
    private var bottom: some View {
        if isEditing {
            SymbolSearchEditor(query: $search.query, isSearching: search.isPending,
                               placeholder: String(localized: "Search Files and Symbols"),
                               onClose: { isEditing = false })
        } else {
            capsule
                .padding(.bottom, 8)
                .offset(y: isBarHidden ? 120 : 0)
                .opacity(isBarHidden ? 0 : 1)
                .allowsHitTesting(!isBarHidden)
        }
    }

    private var capsule: some View {
        let label = HStack(spacing: 6) {
            if stackDepth > 1 {
                StackDepthLabel(depth: stackDepth, actions: stackActions)
            }
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.tint)
            Text(search.query)
                .lineLimit(1)
                .truncationMode(.middle)
            if search.isPending {
                ProgressView().controlSize(.small)
            } else {
                Text(verbatim: "· \(shownCount(search.results))")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .font(.subheadline)
        .padding(.horizontal, 16)
        .frame(height: 36)
        .contentShape(Capsule())
        .onTapGesture { isEditing = true }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(Text("Changes the search"))
        return Group {
            if #available(iOS 26.0, *) {
                label.glassEffect(.regular.interactive(), in: Capsule())
            } else {
                label.background(.bar, in: Capsule())
            }
        }
        .padding(.horizontal, 24)
    }
}

/// A search's results so far, as a list (`list`): a spinner until the first come, and No
/// Results if none do. Observes the search itself, so only this redraws as results come in.
/// A fresh list for each set (see `StackSearch.version`).
struct SearchResultsContent<Results: View>: View {
    let search: StackSearch
    @ViewBuilder let list: (_ symbols: [CodeSymbol], _ query: String) -> Results

    var body: some View {
        if search.results.isEmpty && search.isPending {
            placeholder { ProgressView() }
        } else if search.results.isEmpty {
            placeholder { ContentUnavailableView.search(text: search.query) }
        } else {
            list(search.results, search.resultsQuery)
                .id(search.version)
        }
    }

    private func placeholder<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(uiColor: .systemGroupedBackground))
    }
}

/// The symbol on screen in each card of the stack (paging changes it), for the stack's list and
/// its album. Only the stack icons read it, so a page turn redraws just them.
@MainActor @Observable
final class CardPlaces {
    var current: [UUID: Int] = [:]
}

/// What a page's stack icon does: tap it for the stack's symbols, touch and hold it to add them
/// to an album.
struct StackActions {
    let show: @MainActor () -> Void
    /// The stack's symbols, as album items (read when the menu shows).
    let albumItems: @MainActor () -> [AlbumItem]
    let albumContext: AlbumMenuContext?
}

/// A page's place in the stack, before what its caption names: "▣ 3 |". Tap it for the
/// stack's symbols; touch and hold it to add them to an album. Swipe down to go back one.
struct StackDepthLabel: View {
    let depth: Int
    let actions: StackActions?

    var body: some View {
        HStack(spacing: 6) {
            if let actions {
                if let context = actions.albumContext {
                    Menu {
                        AlbumMenuItems(items: actions.albumItems(), context: context)
                    } label: {
                        count
                    } primaryAction: {
                        actions.show()
                    }
                    .menuIndicator(.hidden)
                    .accessibilityHint(Text("Shows the stack’s symbols. Touch and hold to add them to an album."))
                } else {
                    Button(action: actions.show) { count }
                        .buttonStyle(.plain)
                        .accessibilityHint(Text("Shows the stack’s symbols"))
                }
            } else {
                count
            }
            Divider().frame(height: 14)
        }
    }

    private var count: some View {
        HStack(spacing: 2) {
            Image(systemName: "square.stack")
            Text(depth, format: .number)
                .monospacedDigit()
        }
        .foregroundStyle(.secondary)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Page \(depth) in the stack"))
    }
}

/// The stack's symbols (each card's, as it is now, the bottom card's first), in a sheet: the
/// same code blocks as the Code level. Tap one to go back to its card. The button at the top
/// adds them all to an album.
struct StackSheet<List: View>: View {
    let actions: StackActions
    @ViewBuilder let list: () -> List
    @Environment(\.dismiss) private var dismiss
    @Environment(AlbumNaming.self) private var naming: AlbumNaming?

    var body: some View {
        NavigationStack {
            list()
                .navigationTitle("Stack")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    if let context = actions.albumContext {
                        ToolbarItem(placement: .topBarLeading) {
                            Menu {
                                AlbumMenuItems(items: actions.albumItems(), context: context, isInline: true)
                            } label: {
                                Label("Add to Album", systemImage: "rectangle.stack.badge.plus")
                            }
                        }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
        // New Album… asks for the name over this sheet, not the app: its alert can't show while
        // the sheet is up, and trying closed the sheet.
        .modifier(OptionalAlbumNamingAlert(naming: naming))
        .onAppear { naming?.host = Self.namingHost }
        .onDisappear { if naming?.host == Self.namingHost { naming?.host = nil } }
    }

    static var namingHost: String { "stackSheet" }
}

private struct OptionalAlbumNamingAlert: ViewModifier {
    let naming: AlbumNaming?

    func body(content: Content) -> some View {
        if let naming {
            content.modifier(AlbumNamingAlert(naming: naming, host: "stackSheet", onCreated: { _ in }))
        } else {
            content
        }
    }
}
