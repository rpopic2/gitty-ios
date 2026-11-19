import SwiftUI

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
    /// Opened from the Code list: paging moves the list behind it.
    let isBase: Bool
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

    @ObservationIgnored private let model: CodeDocumentModel
    @ObservationIgnored private var task: Task<Void, Never>?

    init(id: UUID = UUID(), query: String, source: AnyHashable, model: CodeDocumentModel) {
        self.id = id
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

/// A search's results, stacked over the card it was made from: the same code blocks as the Code
/// level's, with the search in a capsule at the bottom (tap it to change the search). Tap a
/// result's code for its card, stacked on top. Swipe down to go back to the card.
struct StackResultsView<Results: View>: View {
    @Bindable var search: StackSearch
    /// Its place in the stack, shown before the search from 2 up.
    let stackDepth: Int
    /// The results shown: the ones not folded away on the page (pinch in to fold files), so
    /// the count is what's there.
    let shownCount: @MainActor ([CodeSymbol]) -> Int
    /// The list, for the results so far and their query.
    @ViewBuilder let list: (_ symbols: [CodeSymbol], _ query: String, _ onScrollDown: @escaping @MainActor (Bool) -> Void) -> Results

    @State private var isEditing = false
    /// Scrolling down hides the capsule; scrolling up shows it.
    @State private var isBarHidden = false

    var body: some View {
        ZStack(alignment: .bottom) {
            content
            bottom
                .animation(.smooth(duration: 0.25), value: isBarHidden)
        }
        .toolbar(.hidden, for: .navigationBar)
    }

    @ViewBuilder
    private var content: some View {
        if search.results.isEmpty && search.isPending {
            placeholder { ProgressView() }
        } else if search.results.isEmpty {
            placeholder { ContentUnavailableView.search(text: search.query) }
        } else {
            list(search.results, search.resultsQuery) { isBarHidden = $0 }
                .id(search.version)
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
                StackDepthLabel(depth: stackDepth)
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

    private func placeholder<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(uiColor: .systemGroupedBackground))
    }
}

/// A page's place in the stack, before what its caption names: "▣ 3 |". Swipe down to go
/// back one.
struct StackDepthLabel: View {
    let depth: Int

    var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: 2) {
                Image(systemName: "square.stack")
                Text(depth, format: .number)
                    .monospacedDigit()
            }
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Page \(depth) in the stack"))
            Divider().frame(height: 14)
        }
    }
}
