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
/// on this device. A place's stack left open (its album left from a card) opens again on coming
/// back to it.
@MainActor @Observable
final class SetAsideStore {
    static let shared = SetAsideStore()

    private struct Saved: Codable {
        var stacks: [String: [SetAsideStack]] = [:]
        var leftOpen: [String: UUID] = [:]
    }

    private(set) var stacks: [String: [SetAsideStack]]
    private var leftOpen: [String: UUID]
    @ObservationIgnored private let defaults: UserDefaults
    private static let key = "setAsideStacks"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let saved = defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode(Saved.self, from: $0) }
        stacks = saved?.stacks ?? [:]
        leftOpen = saved?.leftOpen ?? [:]
    }

    func stacks(at place: String) -> [SetAsideStack] {
        stacks[place] ?? []
    }

    /// - Parameter isLeftOpen: its place was left from it: it opens again on coming back.
    func add(_ stack: SetAsideStack, at place: String, isLeftOpen: Bool) {
        stacks[place, default: []].append(stack)
        if isLeftOpen { leftOpen[place] = stack.id } else if leftOpen[place] != nil { leftOpen[place] = nil }
        save()
    }

    func remove(_ id: UUID, at place: String) {
        stacks[place]?.removeAll { $0.id == id }
        if stacks[place]?.isEmpty == true { stacks[place] = nil }
        if leftOpen[place] == id { leftOpen[place] = nil }
        save()
    }

    /// The stack this place was left from, if it's still there (no longer marked as left open).
    func takeLeftOpen(at place: String) -> SetAsideStack? {
        guard let id = leftOpen.removeValue(forKey: place) else { return nil }
        save()
        return stacks[place]?.first { $0.id == id }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(Saved(stacks: stacks, leftOpen: leftOpen)) else { return }
        defaults.set(data, forKey: Self.key)
    }
}

// MARK: - The chip

/// The stacks set aside in the album shown, in a chip over the bar: the latest's top page and
/// how many cards it has (or how many stacks). Tap it to open the stack, or with several, to
/// fan them out upwards, one chip each, the latest nearest; tap one to open it, or the chip
/// under them to fold them again. Swipe up on them to fan them out too, and down to fold them.
/// Swipe a chip sideways to throw that stack away.
struct SetAsideChips: View {
    let stacks: [SetAsideStack]
    let onOpen: @MainActor (SetAsideStack) -> Void
    let onDrop: @MainActor (SetAsideStack) -> Void

    @State private var isFannedOut = false
    /// A chip's height.
    static let chipHeight: CGFloat = 36

    // In parts: as one expression, it was too much for the type checker.
    var body: some View {
        let stackCount: Int = stacks.count
        let ids: [UUID] = stacks.map(\.id)
        return VStack(spacing: 8) {
            if isFannedOut, stackCount > 1 {
                fannedOut
            }
            if let latest = stacks.last {
                mainChip(latest)
            }
        }
        .animation(.smooth(duration: 0.25), value: ids)
        // Down to one (or none): nothing to fan out.
        .onChange(of: stackCount) { _, new in
            if new < 2 { isFannedOut = false }
        }
    }

    /// The stacks, one chip each: the oldest at the top, the latest just over the main chip.
    private var fannedOut: some View {
        ForEach(stacks) { stack in
            chip(for: stack)
                .frame(maxWidth: 260)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private func chip(for stack: SetAsideStack) -> SetAsideChip {
        SetAsideChip(title: stack.title, symbolImage: stack.symbolImage, count: stack.cardCount,
                     onTap: { open(stack) }, onDrop: { onDrop(stack) }, onSwipe: { up in fan(up) })
    }

    /// The latest stack's chip, or, with several, how many there are (tap or swipe up to fan them
    /// out).
    private func mainChip(_ latest: SetAsideStack) -> some View {
        let several: Bool = stacks.count > 1
        var chip = SetAsideChip(title: latest.title, symbolImage: latest.symbolImage, count: latest.cardCount,
                                onTap: { open(latest) }, onDrop: { onDrop(latest) })
        if several {
            let all = stacks
            let title = String(localized: "\(all.count) Stacks")
            chip = SetAsideChip(title: title, symbolImage: isFannedOut ? "chevron.down" : "square.stack.3d.up",
                                count: nil,
                                onTap: { toggleFan() },
                                // Swiping the folded chip away throws them all away.
                                onDrop: { for stack in all { onDrop(stack) } },
                                onSwipe: { up in fan(up) })
        }
        return chip
            .frame(maxWidth: 220)
            .transition(.scale(scale: 0.8).combined(with: .opacity))
    }

    private func toggleFan() {
        withAnimation(.smooth(duration: 0.25)) { isFannedOut.toggle() }
    }

    private func open(_ stack: SetAsideStack) {
        isFannedOut = false
        onOpen(stack)
    }

    /// Swiped up: fanned out; down: folded.
    private func fan(_ up: Bool) {
        guard stacks.count > 1, up != isFannedOut else { return }
        withAnimation(.smooth(duration: 0.25)) { isFannedOut = up }
    }
}

/// One chip: a stack's icon, its top page's name and its cards. Tap it; swipe it sideways to
/// throw it away (it follows the finger, and goes once far enough).
private struct SetAsideChip: View {
    let title: String
    let symbolImage: String
    /// Its cards (`nil`: several stacks under one chip).
    let count: Int?
    let onTap: @MainActor () -> Void
    let onDrop: @MainActor () -> Void
    /// Swiped up (`true`) or down, for the chips to fan out or fold (`nil`: nothing to do).
    var onSwipe: (@MainActor (_ up: Bool) -> Void)? = nil

    @State private var dragX: CGFloat = 0
    /// Far enough to throw away, with a tap of haptics as it gets there.
    private static let dropDistance: CGFloat = 90

    var body: some View {
        let label = HStack(spacing: 6) {
            Image(systemName: symbolImage)
                .foregroundStyle(.tint)
            Text(title)
                .lineLimit(1)
                .truncationMode(.middle)
            if let count {
                HStack(spacing: 2) {
                    Image(systemName: "square.stack")
                    Text(count, format: .number)
                        .monospacedDigit()
                }
                .foregroundStyle(.secondary)
            }
        }
        .font(.subheadline)
        .padding(.horizontal, 14)
        .frame(height: SetAsideChips.chipHeight)
        .contentShape(Capsule())

        Group {
            if #available(iOS 26.0, *) {
                label.glassEffect(.regular.interactive(), in: Capsule())
            } else {
                label.background(.bar, in: Capsule())
            }
        }
        .onTapGesture { onTap() }
        .offset(x: dragX)
        .opacity(1 - min(1, abs(dragX) / (Self.dropDistance * 2)))
        .sensoryFeedback(.impact(weight: .light), trigger: abs(dragX) > Self.dropDistance) { old, new in new && !old }
        .gesture(
            DragGesture(minimumDistance: 10)
                .onChanged { value in
                    // Sideways follows the finger (to throw it away); up and down don't move it.
                    let t = value.translation
                    dragX = abs(t.width) > abs(t.height) ? t.width : 0
                }
                .onEnded { value in
                    let t = value.translation
                    if abs(t.height) > abs(t.width) {
                        withAnimation(.spring(duration: 0.3)) { dragX = 0 }
                        let flung = value.predictedEndTranslation.height
                        if abs(t.height) > 20 || abs(flung) > 60 { onSwipe?(t.height < 0) }
                        return
                    }
                    let dx = t.width, flung = value.predictedEndTranslation.width
                    if abs(dx) > Self.dropDistance || abs(flung) > Self.dropDistance * 2.5 {
                        withAnimation(.smooth(duration: 0.2)) { dragX = dx < 0 ? -500 : 500 } completion: {
                            onDrop()
                            dragX = 0
                        }
                    } else {
                        withAnimation(.spring(duration: 0.3)) { dragX = 0 }
                    }
                }
        )
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(Text("Opens the stack set aside"))
        .accessibilityAction(named: Text("Remove")) { onDrop() }
    }
}

// MARK: - A caption's swipes

/// A page's caption (a card's, or a results page's capsule): swipe it up or down to set the stack
/// aside, or sideways to set it aside and go to the album beside, as the bar's swipe does. It
/// follows the finger a little, with a tap of haptics once far enough.
struct StackCaptionSwipes: ViewModifier {
    let actions: StackActions?

    @State private var drag: CGSize = .zero
    /// Up or down (down is where the stack goes, into the chip over the bar).
    private static let upDistance: CGFloat = 50
    private static let sideDistance: CGFloat = 80

    func body(content: Content) -> some View {
        if let actions, actions.setAside != nil || actions.switchAlbum != nil {
            content
                .offset(x: drag.width, y: drag.height)
                .sensoryFeedback(.impact(weight: .light), trigger: isPastThreshold) { old, new in new && !old }
                // UIKit's, so the card's own swipes (down to close it, sideways to page) wait for it
                // when the swipe starts on the caption. As a SwiftUI gesture, the swipe down closed
                // the card instead, and this one was cancelled.
                .background {
                    CaptionPan(
                        onChange: { t in
                            // One way at a time: the way it went first, dampened.
                            if abs(t.width) > abs(t.height) {
                                drag = CGSize(width: t.width / (1 + abs(t.width) / 160), height: 0)
                            } else {
                                drag = CGSize(width: 0, height: t.height / (1 + abs(t.height) / 120))
                            }
                        },
                        onEnd: { t, flung in
                            withAnimation(.spring(duration: 0.3)) { drag = .zero }
                            if abs(t.width) > abs(t.height) {
                                let goes = abs(t.width) > Self.sideDistance || abs(flung.width) > Self.sideDistance * 2.5
                                // Finger to the left: the album after (as the bar's swipe).
                                if goes { _ = actions.switchAlbum?(t.width < 0) }
                            } else if abs(t.height) > Self.upDistance || abs(flung.height) > Self.upDistance * 3 {
                                actions.setAside?()
                            }
                        }
                    )
                }
        } else {
            content
        }
    }

    private var isPastThreshold: Bool {
        // In the dampened offset, about where the finger's thresholds are.
        abs(drag.height) > Self.upDistance * 0.7 || abs(drag.width) > Self.sideDistance * 0.65
    }
}

/// A drag that starts on the view (the caption), recognised on the window: the other drags there
/// (the card closing with a swipe down, the pager's paging, the sidebar's) wait for it to fail,
/// so it wins whichever way it goes. Taps and holds aren't held up: they don't wait for it.
private struct CaptionPan: UIViewRepresentable {
    /// How far the finger has moved.
    let onChange: @MainActor (CGSize) -> Void
    /// Where it was let go, and where it was going (a fling).
    let onEnd: @MainActor (_ translation: CGSize, _ predicted: CGSize) -> Void

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
        var onChange: (@MainActor (CGSize) -> Void)?
        var onEnd: (@MainActor (CGSize, CGSize) -> Void)?

        override init() {
            super.init()
            pan.addTarget(self, action: #selector(panned(_:)))
            pan.delegate = self
            pan.cancelsTouchesInView = true  // once it's a drag, the caption's tap doesn't fire
        }

        @objc private func panned(_ recognizer: UIPanGestureRecognizer) {
            guard let view = recognizer.view else { return }
            let point = recognizer.translation(in: view)
            let translation = CGSize(width: point.x, height: point.y)
            switch recognizer.state {
            case .changed:
                onChange?(translation)
            case .ended:
                let velocity = recognizer.velocity(in: view)
                // Roughly where a fling would have taken it.
                onEnd?(translation, CGSize(width: point.x + velocity.x * 0.2, height: point.y + velocity.y * 0.2))
            case .cancelled, .failed:
                onEnd?(.zero, .zero)
            default:
                break
            }
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
            if other is UIPanGestureRecognizer { return true }
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
