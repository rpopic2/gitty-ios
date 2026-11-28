import SwiftUI
import UIKit

// MARK: - Kept

/// A page of a stack set aside, as it's kept across launches: enough to make it again. (While
/// the app runs, the pages themselves are kept, as they were; see `CodeScreen`.)
nonisolated struct SetAsidePage: Codable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable { case card, search, occurrences }

    var kind: Kind
    /// A card's: the symbol it was on.
    var item: AlbumItem?
    /// A search's or Occurrences' text.
    var query: String?
}

/// A card stack set aside (swiped up from a card's caption, or left for another album), to come
/// back to from the chip over the bar.
nonisolated struct SetAsideStack: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var pages: [SetAsidePage]
    /// The top page's: the chip names it.
    var title: String
    var symbolImage: String
    /// How many cards (search and Occurrences pages don't count, as in the stack's icon).
    var cardCount: Int
}

/// The stacks set aside, for each place (an album, or a project as a whole), oldest first, kept
/// on this device.
@MainActor @Observable
final class SetAsideStore {
    static let shared = SetAsideStore()

    private struct Saved: Codable {
        var stacks: [String: [SetAsideStack]] = [:]
    }

    private(set) var stacks: [String: [SetAsideStack]]
    @ObservationIgnored private let defaults: UserDefaults
    private static let key = "setAsideStacks"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let saved = defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode(Saved.self, from: $0) }
        stacks = saved?.stacks ?? [:]
    }

    func stacks(at place: String) -> [SetAsideStack] {
        stacks[place] ?? []
    }

    func add(_ stack: SetAsideStack, at place: String) {
        stacks[place, default: []].append(stack)
        save()
    }

    func remove(_ id: UUID, at place: String) {
        stacks[place]?.removeAll { $0.id == id }
        if stacks[place]?.isEmpty == true { stacks[place] = nil }
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(Saved(stacks: stacks)) else { return }
        defaults.set(data, forKey: Self.key)
    }
}

// MARK: - The chip

/// The stacks set aside in the album shown, in a chip over the bar: the latest's top page and
/// how many cards it has (or how many stacks there are). Tap or hold it for iOS's menu: the
/// stacks, the latest first (choose one to open it), and Remove, with each of them and Remove
/// All.
struct SetAsideChips: View {
    let stacks: [SetAsideStack]
    let onOpen: @MainActor (SetAsideStack) -> Void
    let onDrop: @MainActor (SetAsideStack) -> Void

    /// A chip's height.
    static let chipHeight: CGFloat = 36

    private var latestFirst: [SetAsideStack] { stacks.reversed() }

    var body: some View {
        if let latest = stacks.last {
            Menu {
                ForEach(latestFirst) { stack in
                    Button { onOpen(stack) } label: {
                        Label(Self.rowTitle(stack), systemImage: stack.symbolImage)
                    }
                }
                Menu {
                    ForEach(latestFirst) { stack in
                        Button(role: .destructive) { onDrop(stack) } label: {
                            Label(stack.title, systemImage: stack.symbolImage)
                        }
                    }
                    if stacks.count > 1 {
                        Divider()
                        Button("Remove All", role: .destructive) { stacks.forEach(onDrop) }
                    }
                } label: {
                    Label("Remove", systemImage: "trash")
                }
            } label: {
                chip(latest)
            }
            .menuIndicator(.hidden)
            .buttonStyle(.plain)
            .frame(maxWidth: 220)
            .transition(.scale(scale: 0.8).combined(with: .opacity))
            .accessibilityHint(Text("Shows the stacks set aside"))
        }
    }

    /// "parse · 3 cards"
    private static func rowTitle(_ stack: SetAsideStack) -> String {
        stack.cardCount == 1 ? String(localized: "\(stack.title) · 1 card")
            : String(localized: "\(stack.title) · \(stack.cardCount) cards")
    }

    /// The latest stack, or how many there are.
    private func chip(_ latest: SetAsideStack) -> SetAsideChip {
        let several: Bool = stacks.count > 1
        return SetAsideChip(title: several ? String(localized: "\(stacks.count) Stacks") : latest.title,
                            symbolImage: several ? "square.stack.3d.up" : latest.symbolImage,
                            cards: several ? nil : latest.cardCount)
    }
}

/// The chip: a stack's icon, its top page's name and its cards.
private struct SetAsideChip: View {
    let title: String
    let symbolImage: String
    /// Its cards (`nil`: several stacks under one chip).
    let cards: Int?

    var body: some View {
        let label = HStack(spacing: 6) {
            Image(systemName: symbolImage)
                .foregroundStyle(.tint)
            Text(title)
                .lineLimit(1)
                .truncationMode(.middle)
            if let cards {
                HStack(spacing: 2) {
                    Image(systemName: "square.stack")
                    Text(cards, format: .number)
                        .monospacedDigit()
                }
                .foregroundStyle(.secondary)
            }
        }
        .font(.subheadline)
        .padding(.horizontal, 14)
        .frame(height: SetAsideChips.chipHeight)
        .contentShape(Capsule())

        if #available(iOS 26.0, *) {
            label.glassEffect(.regular.interactive(), in: Capsule())
        } else {
            label.background(.bar, in: Capsule())
        }
    }
}

// MARK: - A caption's swipes

/// A page's caption (a card's, or a results page's capsule): swipe it up or down to set the stack
/// aside. It follows the finger a little, with a tap of haptics once far enough. Sideways is the
/// card's (paging).
struct StackCaptionSwipes: ViewModifier {
    let actions: StackActions?

    @State private var drag: CGFloat = 0
    /// Up or down (down is where the stack goes, into the chip over the bar).
    private static let distance: CGFloat = 50

    func body(content: Content) -> some View {
        if let setAside = actions?.setAside {
            content
                .offset(y: drag)
                .sensoryFeedback(.impact(weight: .light), trigger: isPastThreshold) { old, new in new && !old }
                // UIKit's, so the card's own swipes (down to close it, sideways to page) wait for it
                // when the swipe starts on the caption. As a SwiftUI gesture, the swipe down closed
                // the card instead, and this one was cancelled.
                .background {
                    CaptionPan(
                        // Dampened.
                        onChange: { y in drag = y / (1 + abs(y) / 120) },
                        onEnd: { y, flung in
                            withAnimation(.spring(duration: 0.3)) { drag = 0 }
                            if abs(y) > Self.distance || abs(flung) > Self.distance * 3 { setAside() }
                        }
                    )
                }
        } else {
            content
        }
    }

    private var isPastThreshold: Bool {
        // In the dampened offset, about where the finger's threshold is.
        abs(drag) > Self.distance * 0.7
    }
}

/// An up or down drag that starts on the view (the caption), recognised on the window: the other
/// drags there (the card closing with a swipe down, the pager's paging, the sidebar's) wait for it
/// to fail, so it wins. Taps and holds aren't held up: they don't wait for it.
private struct CaptionPan: UIViewRepresentable {
    /// How far down the finger has moved (up: below 0).
    let onChange: @MainActor (CGFloat) -> Void
    /// Where it was let go, and where it was going (a fling).
    let onEnd: @MainActor (_ translation: CGFloat, _ predicted: CGFloat) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> InstallerView {
        let view = InstallerView()
        view.isUserInteractionEnabled = false  // touches go to the caption; the drag is the window's
        view.recognizer = context.coordinator.pan
        context.coordinator.area = view
        return view
    }

    func updateUIView(_ view: InstallerView, context: Context) {
        context.coordinator.onChange = onChange
        context.coordinator.onEnd = onEnd
    }

    final class InstallerView: UIView {
        var recognizer: UIGestureRecognizer?

        override func willMove(toWindow newWindow: UIWindow?) {
            super.willMove(toWindow: newWindow)
            guard let recognizer else { return }
            recognizer.view?.removeGestureRecognizer(recognizer)
            newWindow?.addGestureRecognizer(recognizer)
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        let pan = UIPanGestureRecognizer()
        weak var area: UIView?
        var onChange: (@MainActor (CGFloat) -> Void)?
        var onEnd: (@MainActor (CGFloat, CGFloat) -> Void)?

        override init() {
            super.init()
            pan.addTarget(self, action: #selector(panned(_:)))
            pan.delegate = self
            pan.cancelsTouchesInView = true  // once it's a drag, the caption's tap doesn't fire
        }

        @objc private func panned(_ recognizer: UIPanGestureRecognizer) {
            guard let view = recognizer.view else { return }
            let y = recognizer.translation(in: view).y
            switch recognizer.state {
            case .changed:
                onChange?(y)
            case .ended:
                // Roughly where a fling would have taken it.
                onEnd?(y, y + recognizer.velocity(in: view).y * 0.2)
            case .cancelled, .failed:
                onEnd?(0, 0)
            default:
                break
            }
        }

        /// Up or down only: sideways is the card's.
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            let velocity = pan.velocity(in: pan.view)
            return abs(velocity.y) > abs(velocity.x)
        }

        /// Only touches that start on the caption, while it's on screen.
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard let area, area.window != nil, !area.isHidden, area.alpha > 0.01 else { return false }
            return area.bounds.contains(touch.location(in: area))
        }

        /// The other drags wait for it: pans (paging, the sidebar), and the card's zoom closing
        /// (whatever UIKit calls its recognizer). Taps and holds don't, so the caption's tap and
        /// menu work as before.
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
            guard other !== pan else { return false }
            // Not a trackpad's two-finger swipes (no touches): this never sees those.
            if other is UIPanGestureRecognizer { return !other.allowedTouchTypes.isEmpty }
            let name = String(describing: type(of: other))
            return ["Zoom", "Transition", "Dismiss"].contains { name.contains($0) }
        }
    }
}

extension View {
    /// See `StackCaptionSwipes`.
    func stackCaptionSwipes(_ actions: StackActions?) -> some View {
        modifier(StackCaptionSwipes(actions: actions))
    }
}
