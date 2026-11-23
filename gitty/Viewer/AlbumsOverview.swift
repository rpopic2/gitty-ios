import SwiftUI
import UniformTypeIdentifiers

/// The project's albums, like Safari's tab overview: swiped up from the Code level's bar (it
/// rises with the finger), the whole project first, then each album as a tile. Tap one to show
/// it; swipe one sideways to delete it; touch and hold for Rename and Delete, or hold and drag
/// to move it (the bar's sideways swipe goes in this order). + makes a new one. Drag the top
/// down (or the list, from its top), or tap Done, to go back.
struct AlbumsOverview: View {
    let projectID: String
    let projectTitle: String
    /// Under the whole project's name: its branch and how many files ("main · 1,204 files").
    let projectDetail: String
    let currentAlbumID: UUID?
    let onShowProject: @MainActor () -> Void
    let onOpen: @MainActor (UUID) -> Void
    let onDelete: @MainActor (Album) -> Void
    let onClose: @MainActor () -> Void
    /// The top dragged down: how far (the page follows), then where it was let go and where it
    /// was flung to.
    let onDragDown: @MainActor (CGFloat) -> Void
    let onDragDownEnded: @MainActor (_ distance: CGFloat, _ predicted: CGFloat) -> Void

    @Environment(AlbumNaming.self) private var albumNaming: AlbumNaming?
    /// The album being dragged to a new place.
    @State private var moving: UUID?
    /// The list is scrolled to its top (or pulled past it).
    @State private var isAtTop = true
    /// How far the list is pulled past its top: undone, so the tiles stay with the page.
    @State private var overscroll: CGFloat = 0
    /// Decided as a drag starts: down from the top pulls the page down, as its handle does.
    @State private var pullsPage: Bool?

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 14)]

    var body: some View {
        let albums = AlbumStore.shared.albums(inProject: projectID)
        VStack(spacing: 0) {
            // It fades in as the page rises (the bar, on top of it, fades out).
            AlbumsHeaderFade { header }
            ScrollView {
                LazyVGrid(columns: columns, spacing: 14) {
                    Button(action: onShowProject) {
                        AlbumTile(icon: "shippingbox", title: projectTitle, detail: projectDetail,
                                  detailIcon: nil, isCurrent: currentAlbumID == nil)
                    }
                    .buttonStyle(.plain)
                    ForEach(albums) { album in
                        tile(album)
                    }
                }
                .padding(16)
                .animation(.smooth(duration: 0.25), value: albums.map(\.id))
                // Pulled down from the top, the page moves instead of the tiles inside it.
                .offset(y: pullsPage == true ? -overscroll : 0)
            }
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y + $0.contentInsets.top } action: { _, y in
                isAtTop = y <= 1
                overscroll = max(0, -y)
            }
            .simultaneousGesture(
                DragGesture(minimumDistance: 8, coordinateSpace: .global)
                    .onChanged { value in
                        if pullsPage == nil { pullsPage = isAtTop && value.translation.height > 0 }
                        guard pullsPage == true else { return }
                        onDragDown(max(0, value.translation.height))
                    }
                    .onEnded { value in
                        defer { pullsPage = nil }
                        guard pullsPage == true else { return }
                        onDragDownEnded(max(0, value.translation.height), value.predictedEndTranslation.height)
                    }
            )
        }
        // The bar's own material: the page reads as the bar, pulled up.
        .background(.bar, ignoresSafeAreaEdges: .all)
    }

    /// Done, the title and +; dragging it down closes the page.
    private var header: some View {
        // The title in the middle of the page, whatever the buttons' widths.
        ZStack {
            Text("Albums")
                .font(.headline)
            HStack {
                Button("Done", action: onClose)
                Spacer()
                Button("New Album", systemImage: "plus") {
                    albumNaming?.begin(projectID: projectID, opensAlbum: true)
                }
                .labelStyle(.iconOnly)
                .font(.title3)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: FileBarMetrics.barHeight)  // where the bar was, as the page rose
        .overlay(alignment: .top) {
            Capsule()
                .fill(.tertiary)
                .frame(width: 36, height: 5)
                .padding(.top, 6)
        }
        .contentShape(Rectangle())
        .gesture(
            // In the screen's space: the page moves under the finger, so in its own the drag
            // would shake as it follows.
            DragGesture(minimumDistance: 8, coordinateSpace: .global)
                .onChanged { onDragDown(max(0, $0.translation.height)) }
                .onEnded { onDragDownEnded(max(0, $0.translation.height), $0.predictedEndTranslation.height) }
        )
    }

    private func tile(_ album: Album) -> some View {
        SwipeAwayTile(onSwipedAway: { onDelete(album) }) {
            Button { onOpen(album.id) } label: {
                AlbumTile(icon: "rectangle.stack", title: album.name, detail: Self.detail(of: album),
                          detailIcon: Self.detailIcon(of: album), isCurrent: album.id == currentAlbumID)
            }
            .buttonStyle(.plain)
        }
        .contextMenu {
            Button("Rename", systemImage: "pencil") { albumNaming?.beginRenaming(album) }
            Button("Delete", systemImage: "trash", role: .destructive) { onDelete(album) }
        }
        .onDrag {
            moving = album.id
            return NSItemProvider(object: album.id.uuidString as NSString)
        }
        .onDrop(of: [.text], delegate: AlbumDropDelegate(target: album.id, moving: $moving))
    }

    /// A diff album: what it compares (a comparison follows its branches; a commit's is fixed).
    /// Any other: how many items.
    private static func detail(of album: Album) -> String {
        guard let diff = album.diff else { return String(localized: "\(album.items.count) items") }
        switch diff.source {
        case .commit(let id):
            return String(localized: "Commit \(String(id.prefix(7)))")
        case .comparison(let base, let head, let mode):
            return GitComparison(base: base, head: head, mode: mode).title
        }
    }

    private static func detailIcon(of album: Album) -> String? {
        switch album.diff?.source {
        case .commit: "smallcircle.filled.circle"
        case .comparison: "arrow.triangle.branch"
        case nil: nil
        }
    }
}

/// The albums page's place: open or not, how far it's dragged (up from below while opening,
/// down while open), and its whole project tile's line, worked out as it opens.
@MainActor @Observable
final class AlbumsPageState {
    var isShowing = false
    var drag: CGFloat = 0
    /// On screen at all: from the first move up until it has settled closed.
    var isActive = false
    var projectDetail = ""
    /// Where the bar's top is (the page's, closed): set as it's laid out.
    var closedTop: CGFloat = 600

    /// Where the page's top is: the bar's as it's pulled up, the screen's top once open, or as
    /// far down as it's dragged from there.
    func pageTop(closedTop: CGFloat) -> CGFloat {
        isShowing ? drag : closedTop - drag
    }

    /// 0 closed (the bar where it is), 1 open.
    var progress: CGFloat {
        let fraction = min(1, max(0, drag / max(closedTop, 1)))
        return isShowing ? 1 - fraction : fraction
    }

    /// Swiping the bar up begins.
    func lift(_ distance: CGFloat) {
        if distance > 0 { isActive = true }
        drag = distance
    }

    /// Let go (or Done, or an album chosen): it settles open or closed.
    func settle(opens: Bool) {
        withAnimation(.smooth(duration: 0.3)) {
            isShowing = opens
            drag = 0
        } completion: {
            if !self.isShowing { self.isActive = false }
        }
    }
}

/// The albums page, hanging from the bar as it's pulled up: its top is where the bar's is, it
/// rises with the finger and settles open, or back down where the bar is.
struct AlbumsPageHost<Page: View>: View {
    let state: AlbumsPageState
    @ViewBuilder let page: () -> Page

    var body: some View {
        // Only the placement reads the drag: the page itself isn't made again as it moves.
        page()
            .environment(state)
            .modifier(AlbumsPagePlacement(state: state))
    }
}

private struct AlbumsPagePlacement: ViewModifier {
    let state: AlbumsPageState

    func body(content: Content) -> some View {
        GeometryReader { geometry in
            let top = geometry.size.height - FileBarMetrics.barHeight
            content
                .offset(y: state.pageTop(closedTop: top))
                .opacity(state.isActive ? 1 : 0)
                .allowsHitTesting(state.isShowing)
                .accessibilityHidden(!state.isShowing)
                .onAppear { state.closedTop = top }
                .onChange(of: top) { state.closedTop = top }
        }
    }
}

/// The bar itself, carried up on the albums page's top as it rises (fading as the page's header
/// comes in), and back down with it. The page's own header takes over once it's open.
struct AlbumsBarLift: ViewModifier {
    let state: AlbumsPageState

    func body(content: Content) -> some View {
        content
            .offset(y: state.isActive ? state.pageTop(closedTop: state.closedTop) - state.closedTop : 0)
            .opacity(state.isActive ? max(0, 1 - state.progress * 2.5) : 1)
            .allowsHitTesting(!state.isShowing)
    }
}

/// The page's header, fading in as it rises.
private struct AlbumsHeaderFade<Content: View>: View {
    @ViewBuilder let content: () -> Content
    @Environment(AlbumsPageState.self) private var state: AlbumsPageState?

    var body: some View {
        content()
            .opacity(min(1, max(0, ((state?.progress ?? 1) - 0.3) / 0.5)))
    }
}

/// An album's tile: its icon, name, and a line about it; the one shown is outlined.
private struct AlbumTile: View {
    let icon: String
    let title: String
    let detail: String
    let detailIcon: String?
    let isCurrent: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(.tint)
            Spacer(minLength: 0)
            Text(title)
                .font(.headline)
                .foregroundStyle(.primary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            HStack(spacing: 4) {
                if let detailIcon {
                    Image(systemName: detailIcon)
                }
                Text(detail)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 120, alignment: .leading)
        .background(Color(uiColor: .secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            if isCurrent {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(.tint, lineWidth: 3)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isCurrent ? [.isButton, .isSelected] : .isButton)
    }
}

/// Swipe a tile sideways to delete it, like closing a Safari tab: it follows the finger and
/// fades; let go far enough (or fling it) and it flies off. A vertical drag is left to the
/// scrolling.
private struct SwipeAwayTile<Content: View>: View {
    let onSwipedAway: @MainActor () -> Void
    @ViewBuilder let content: () -> Content

    @State private var offset: CGFloat = 0
    /// Decided on the first move: sideways deletes, anything else scrolls.
    @State private var isSideways: Bool?

    var body: some View {
        content()
            .offset(x: offset)
            .opacity(1 - min(abs(offset) / 260, 0.7))
            .simultaneousGesture(
                DragGesture(minimumDistance: 16)
                    .onChanged { value in
                        let dx = value.translation.width, dy = value.translation.height
                        if isSideways == nil { isSideways = abs(dx) > abs(dy) * 1.5 }
                        guard isSideways == true else { return }
                        offset = dx
                    }
                    .onEnded { value in
                        defer { isSideways = nil }
                        guard isSideways == true else { return }
                        let dx = value.translation.width
                        let flung = value.predictedEndTranslation.width
                        guard abs(dx) > 110 || (abs(flung) > 260 && (flung < 0) == (dx < 0)) else {
                            withAnimation(.spring(duration: 0.3)) { offset = 0 }
                            return
                        }
                        withAnimation(.smooth(duration: 0.2)) {
                            offset = dx < 0 ? -600 : 600
                        } completion: {
                            onSwipedAway()
                        }
                    }
            )
            .accessibilityAction(named: Text("Delete")) { onSwipedAway() }
    }
}

/// Dragging a tile over another moves it there, as it goes.
private struct AlbumDropDelegate: DropDelegate {
    let target: UUID
    @Binding var moving: UUID?

    func dropEntered(info: DropInfo) {
        guard let moving, moving != target else { return }
        withAnimation(.smooth(duration: 0.25)) { AlbumStore.shared.move(moving, to: target) }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        moving = nil
        return true
    }
}
