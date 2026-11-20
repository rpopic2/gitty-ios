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
    /// Occurrences of a word (a card's text menu).
    case occurrences(UUID)
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
    /// Where its other pages open (see `SymbolPager.pageAnchors`): an occurrence's line.
    var pageAnchors: [Int: PageAnchor] = [:]
}

/// What a results page shows (a search, or occurrences): its text, edited in the capsule (it
/// looks again as you type), and what it found so far.
@MainActor
protocol ResultsPageSearch: AnyObject, Observable {
    var query: String { get set }
    var results: [CodeSymbol] { get }
    /// The text `results` are for.
    var resultsQuery: String { get }
    /// Up with each set of results.
    var version: Int { get }
    /// Still looking.
    var isPending: Bool { get }
    /// The page opens with the field focused.
    var startsEditing: Bool { get }
    /// The capsule's icon and the field's placeholder.
    var symbolName: String { get }
    var placeholder: String { get }
    /// A line above the capsule (files left out, say).
    var note: String? { get }
}

/// A search, for a results page: the files whose name contains it (each with all its symbols),
/// then the symbols it matches (in the album, if one is shown). The Code list itself is never
/// filtered.
@MainActor @Observable
final class StackSearch: ResultsPageSearch {
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
    /// Up with each set of matches.
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

    var symbolName: String { "magnifyingglass" }
    var placeholder: String { String(localized: "Search Files and Symbols") }
    /// While the project's symbols are still being read, the search finds only those read.
    var note: String? {
        guard let progress = model.indexingProgress else { return nil }
        let left = (progress.total - progress.done).formatted()
        if progress.isPaused {
            return String(localized: "Symbols of \(left) files aren’t read yet (the project is very big): they’re read as their files show.")
        }
        return String(localized: "Still reading symbols: \(progress.done.formatted()) of \(progress.total.formatted()) files.")
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
            var listed: [CodeSymbol] = []
            var listedIDs: Set<Int> = []
            for await matches in stream {
                guard !Task.isCancelled, let self else { return }
                let shown = album.map { ids in matches.filter { ids.contains($0.id) } } ?? matches
                // Rows already showing keep their places; matches found since go after them, best
                // first (each batch is ranked again, so a better one would push the others down).
                for symbol in files + shown where listedIDs.insert(symbol.id).inserted {
                    listed.append(symbol)
                }
                self.results = listed
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

/// A results page (a search's, or occurrences'), stacked over what it was made from: the same
/// code blocks as the Code level's, with what it looks for in a capsule at the bottom (tap it to
/// change it; the results follow as you type). Tap a result's code for its card, stacked on top.
/// Swipe down to go back.
struct StackResultsView<Search: ResultsPageSearch, Results: View>: View {
    @Bindable var search: Search
    /// Its place in the stack, shown before the search from 2 up.
    let stackDepth: Int
    let stackActions: StackActions?
    /// The results shown: the ones not folded away on the page (pinch in to fold files), so
    /// the count is what's there.
    let shownCount: @MainActor ([CodeSymbol]) -> Int
    /// The list, for the results so far and their query.
    @ViewBuilder let list: (_ symbols: [CodeSymbol], _ query: String, _ bar: ResultsBar) -> Results

    @State private var isEditing: Bool
    /// Scrolling down hides the capsule; scrolling up shows it.
    @State private var isBarHidden = false
    @Environment(\.dismiss) private var dismiss

    init(search: Search, stackDepth: Int, stackActions: StackActions?,
         shownCount: @escaping @MainActor ([CodeSymbol]) -> Int,
         @ViewBuilder list: @escaping (_ symbols: [CodeSymbol], _ query: String,
                                       _ bar: ResultsBar) -> Results) {
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
            if !isEditing {
                capsule
                    .padding(.bottom, 8)
                    .offset(y: isBarHidden ? 120 : 0)
                    .opacity(isBarHidden ? 0 : 1)
                    .allowsHitTesting(!isBarHidden)
                    .animation(.smooth(duration: 0.25), value: isBarHidden)
            }
        }
        // The field sits right on the keyboard: UIKit's keyboard guide places it (SwiftUI's own
        // keyboard room, on a pushed page, left it floating above it or under it).
        .overlay {
            if isEditing {
                KeyboardDocked {
                    SymbolSearchEditor(query: $search.query, isSearching: search.isPending,
                                       placeholder: search.placeholder,
                                       onClose: { isEditing = false },
                                       // A search begun in the bar goes on being typed here.
                                       selectsAll: !search.startsEditing)
                }
                .ignoresSafeArea(.keyboard)
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        // Closing the field before typing anything: nothing to show, so back to where it was.
        .onChange(of: isEditing) {
            if !isEditing, isQueryEmpty { dismiss() }
        }
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
                list(symbols, query, ResultsBar(isHidden: { isBarHidden }, setHidden: { isBarHidden = $0 }))
            }
        }
    }

    private var capsule: some View {
        VStack(spacing: 6) {
            if let note = search.note {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            let label = HStack(spacing: 6) {
                if stackDepth > 1 {
                    StackDepthLabel(depth: stackDepth, actions: stackActions)
                }
                Image(systemName: search.symbolName)
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
            Group {
                if #available(iOS 26.0, *) {
                    label.glassEffect(.regular.interactive(), in: Capsule())
                } else {
                    label.background(.bar, in: Capsule())
                }
            }
            .padding(.horizontal, 24)
        }
    }
}

/// Content docked right on top of the keyboard (or at the bottom without one), with UIKit's
/// keyboard layout guide. The rest of it lets touches through.
struct KeyboardDocked<Content: View>: UIViewControllerRepresentable {
    @ViewBuilder let content: () -> Content

    func makeUIViewController(context: Context) -> KeyboardDockController<Content> {
        KeyboardDockController(rootView: content())
    }

    func updateUIViewController(_ controller: KeyboardDockController<Content>, context: Context) {
        controller.host.rootView = content()
    }
}

final class KeyboardDockController<Content: View>: UIViewController {
    let host: UIHostingController<Content>

    init(rootView: Content) {
        host = UIHostingController(rootView: rootView)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func loadView() {
        view = PassThroughView()
        view.backgroundColor = .clear
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        host.view.backgroundColor = .clear
        host.sizingOptions = [.intrinsicContentSize]
        host.safeAreaRegions = []  // the guide places it; no keyboard room inside too
        addChild(host)
        view.addSubview(host.view)
        host.didMove(toParent: self)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
        ])
    }

    /// Touches outside the docked content go to what's under it.
    private final class PassThroughView: UIView {
        override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
            let hit = super.hitTest(point, with: event)
            return hit === self ? nil : hit
        }
    }
}

/// The capsule under a results list, for the list's scrolling: scrolling down hides it, up shows
/// it. The list asks whether it's hidden now, so it knows to show it again.
struct ResultsBar {
    let isHidden: @MainActor () -> Bool
    let setHidden: @MainActor (Bool) -> Void

    /// For results with nothing to hide.
    static let none = ResultsBar(isHidden: { false }, setHidden: { _ in })
}

/// A search's results so far, as a list (`list`): a spinner until the first come, and No
/// Results if none do. Observes the search itself, so only this redraws as results come in.
/// The results, the same list while matches come in (a fresh one for each query).
struct SearchResultsContent<Search: ResultsPageSearch, Results: View>: View {
    let search: Search
    @ViewBuilder let list: (_ symbols: [CodeSymbol], _ query: String) -> Results

    var body: some View {
        if search.results.isEmpty && search.isPending {
            placeholder { ProgressView() }
        } else if search.results.isEmpty {
            placeholder { ContentUnavailableView.search(text: search.query) }
        } else {
            // A fresh list for each query, not for each batch of matches: rebuilt, every row's
            // code was laid out and colored again (it flashed) and its counts worked out again.
            list(search.results, search.resultsQuery)
                .id(search.resultsQuery)
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
