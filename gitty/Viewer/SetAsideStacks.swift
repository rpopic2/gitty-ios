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
/// how many cards it has (or how many stacks there are). Like a menu in iOS: hold it and the
/// stacks fan out upwards, one chip each, the latest nearest (the screen blurs behind them,
/// `isOpen`); slide to one (it's highlighted) and let go to open it. A tap leaves them out, to
/// tap one; letting go anywhere else folds them, as a tap on the bottom chip or the blur does.
struct SetAsideChips: View {
    let stacks: [SetAsideStack]
    /// Fanned out (the screen blurs behind it).
    @Binding var isOpen: Bool
    let onOpen: @MainActor (SetAsideStack) -> Void
    let onDrop: @MainActor (SetAsideStack) -> Void

    /// The stack under the finger.
    @State private var highlighted: UUID?
    /// The finger on it now (`nil`: none).
    @State private var touch: Touch?
    @State private var holdTask: Task<Void, Never>?

    private struct Touch {
        /// Fanned out when the finger came down.
        let wasOpen: Bool
        /// It's moved: not a tap.
        var hasMoved = false
        /// Held long enough to fan them out: not a tap.
        var isHeld = false
    }

    /// A chip's height.
    static let chipHeight: CGFloat = 36
    /// From one chip to the next, fanned out.
    private static let step: CGFloat = chipHeight + 8

    private var latestFirst: [SetAsideStack] { stacks.reversed() }

    /// Always as tall as the chips fanned out, so a finger's place in it doesn't move as they
    /// come out (growing with them, it swept the finger through every chip). Folded, only the
    /// bottom chip takes touches (`ChipsShape`).
    private var height: CGFloat {
        Self.chipHeight + CGFloat(stacks.count) * Self.step
    }

    // In parts, with types spelled out: as one expression, it was too much for the type checker.
    var body: some View {
        let ids: [UUID] = stacks.map(\.id)
        let isEmpty: Bool = stacks.isEmpty
        return ZStack(alignment: .bottom) {
            ForEach(Array(latestFirst.enumerated()), id: \.element.id) { place, stack in
                fannedChip(stack, place: place)
            }
            if let latest = stacks.last {
                mainChip(latest)
            }
        }
        .frame(height: height, alignment: .bottom)
        .contentShape(ChipsShape(bottomHeight: isOpen ? nil : Self.chipHeight))
        .gesture(press)
        .animation(.smooth(duration: 0.25), value: isOpen)
        .animation(.smooth(duration: 0.25), value: ids)
        .sensoryFeedback(.selection, trigger: highlighted) { _, new in new != nil }
        // Coming out, as a menu does under a hold.
        // Rigid: a sharper tap than the heaviest soft one.
        .sensoryFeedback(.impact(flexibility: .rigid, intensity: 1), trigger: isOpen) { old, new in new && !old }
        .onChange(of: isEmpty) { _, empty in if empty { isOpen = false } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(accessibilityTitle))
        .accessibilityActions {
            ForEach(latestFirst) { stack in
                Button(String(localized: "Open \(stack.title)")) { open(stack) }
                Button(String(localized: "Remove \(stack.title)")) { onDrop(stack) }
            }
        }
    }

    private var accessibilityTitle: String {
        let total: Int = stacks.count
        return total == 1 ? String(localized: "1 stack set aside") : String(localized: "\(total) stacks set aside")
    }

    /// A stack's chip, `place` steps above the bottom one when fanned out (behind it, folded).
    private func fannedChip(_ stack: SetAsideStack, place: Int) -> some View {
        let isHighlighted: Bool = stack.id == highlighted
        let y: CGFloat = isOpen ? -CGFloat(place + 1) * Self.step : 0
        return SetAsideChip(title: stack.title, symbolImage: stack.symbolImage, cards: stack.cardCount,
                            isHighlighted: isHighlighted)
            .frame(maxWidth: 260)
            .offset(y: y)
            .opacity(isOpen ? 1 : 0)
    }

    /// The bottom chip: the latest stack, or how many there are.
    private func mainChip(_ latest: SetAsideStack) -> some View {
        let several: Bool = stacks.count > 1
        let title: String = several ? String(localized: "\(stacks.count) Stacks") : latest.title
        let image: String = isOpen ? "chevron.down" : (several ? "square.stack.3d.up" : latest.symbolImage)
        let cards: Int? = several ? nil : latest.cardCount
        // Fanned out, it's lifted, as a held item is under a menu.
        return SetAsideChip(title: title, symbolImage: image, cards: cards, isHighlighted: false)
            .frame(maxWidth: 220)
            .scaleEffect(isOpen ? 1.08 : 1)
            .shadow(color: .black.opacity(isOpen ? 0.25 : 0), radius: isOpen ? 12 : 0, y: isOpen ? 4 : 0)
            .transition(.scale(scale: 0.8).combined(with: .opacity))
    }

    /// One touch does it all. Held (or slid up): out they come. Moving: the chip under the finger
    /// is highlighted. Let go on one, it opens; let go anywhere
    /// else (the bottom chip too), they fold. A tap leaves them out, or, while they're out,
    /// folds them.
    private var press: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if touch == nil {
                    touch = Touch(wasOpen: isOpen)
                    holdTask = Task {
                        try? await Task.sleep(for: .milliseconds(300))
                        guard !Task.isCancelled, touch?.hasMoved == false else { return }
                        touch?.isHeld = true
                        isOpen = true
                    }
                }
                let t = value.translation
                if abs(t.width) > 6 || abs(t.height) > 6 { touch?.hasMoved = true }
                if !isOpen, t.height < -12 { isOpen = true }  // slid up: no need to wait for the hold
                guard isOpen else { return }
                let found = stack(at: value.location)
                if found?.id != highlighted { highlighted = found?.id }
            }
            .onEnded { value in
                holdTask?.cancel()
                let ended = touch ?? Touch(wasOpen: isOpen)
                touch = nil
                defer { highlighted = nil }
                if let found = stack(at: value.location) {
                    open(found)
                } else {
                    // Out after a tap; folded after a hold or a slide (let go on the bottom chip,
                    // or off them), or a tap while they were out.
                    isOpen = !ended.hasMoved && !ended.isHeld && !ended.wasOpen
                }
            }
    }

    /// The fanned-out chip at a point (in this view, the bottom chip at its bottom).
    private func stack(at point: CGPoint) -> SetAsideStack? {
        guard isOpen else { return nil }
        // Chip `place` is centered `place + 1` steps above the bottom chip's middle.
        // Each chip's band starts a little below its middle: the bottom chip keeps its whole
        // height and a bit over it (a finger on its top half isn't on the chip above).
        let aboveMiddle: CGFloat = (height - Self.chipHeight / 2) - point.y
        let place = Int(((aboveMiddle - Self.chipHeight) / Self.step).rounded(.down))
        return latestFirst.indices.contains(place) ? latestFirst[place] : nil
    }

    private func open(_ stack: SetAsideStack) {
        isOpen = false
        onOpen(stack)
    }
}

/// Where the chips take touches: all of their area fanned out, or the bottom chip alone.
private struct ChipsShape: Shape {
    /// `nil`: all of it.
    let bottomHeight: CGFloat?

    func path(in rect: CGRect) -> Path {
        guard let bottomHeight else { return Path(rect) }
        return Path(CGRect(x: rect.minX, y: rect.maxY - bottomHeight, width: rect.width, height: bottomHeight))
    }
}

/// One chip: a stack's icon, its top page's name and its cards.
private struct SetAsideChip: View {
    let title: String
    let symbolImage: String
    /// Its cards (`nil`: several stacks under one chip).
    let cards: Int?
    /// Under the finger: letting go opens it.
    let isHighlighted: Bool

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
        .background(isHighlighted ? Color.accentColor.opacity(0.18) : .clear, in: Capsule())

        Group {
            if #available(iOS 26.0, *) {
                label.glassEffect(.regular, in: Capsule())
            } else {
                label.background(.bar, in: Capsule())
            }
        }
        .scaleEffect(isHighlighted ? 1.06 : 1)
        .animation(.smooth(duration: 0.15), value: isHighlighted)
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
