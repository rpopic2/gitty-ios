import SwiftUI

/// One of a fan's chips: a stack set aside, or an action.
struct FanItem: Identifiable {
    let id: String
    let title: String
    let symbolImage: String
    /// Cards, after the title (a stack's).
    var count: Int? = nil
    var isDestructive = false
    /// Chosen.
    let action: @MainActor () -> Void
}

/// A capsule (`base`) whose chips fan out upwards, like a menu in iOS: hold it (or slide up) and
/// they come out over a blur (`isOpen`, which the screen shows), the nearest first; slide to one
/// (it's highlighted) and let go to choose it. Let go back on the capsule and they stay out, as a
/// menu does; anywhere else, they fold. A tap brings them out too, or folds them. The set-aside
/// stacks' chip and every stack page's capsule (`StackCaption`) work this way.
struct HoldFan<Base: View>: View {
    /// Nearest the capsule first.
    let items: [FanItem]
    @Binding var isOpen: Bool
    @ViewBuilder let base: () -> Base

    @State private var highlighted: String?
    /// The finger on it now (`nil`: none).
    @State private var touch: Touch?
    @State private var holdTask: Task<Void, Never>?
    /// The capsule's frame on screen: the finger's place is measured from it, so the chips
    /// coming out never move it.
    @State private var baseFrame: CGRect = .zero
    /// While the finger is down with them out, they all lean a little its way, as a menu's
    /// preview does.
    @State private var lean: CGSize = .zero
    /// How much of the finger's move they follow.
    private static var leaning: CGFloat { 0.06 }

    private struct Touch {
        /// Fanned out when the finger came down.
        let wasOpen: Bool
        /// It's moved: not a tap.
        var hasMoved = false
        /// Held long enough to fan them out: not a tap.
        var isHeld = false
    }

    /// From one chip to the next.
    private static var step: CGFloat { FanChip.height + 8 }

    var body: some View {
        base()
            // Fanned out, it's lifted, as a held item is under a menu.
            .scaleEffect(isOpen ? 1.08 : 1)
            .shadow(color: .black.opacity(isOpen ? 0.25 : 0), radius: isOpen ? 12 : 0, y: isOpen ? 4 : 0)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { baseFrame = $0 }
            .gesture(press)
            // The chips, above it; while they're out, they (and the capsule) take the touches.
            .overlay(alignment: .bottom) {
                ZStack(alignment: .bottom) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { place, item in
                        chip(item, place: place)
                    }
                }
                .frame(width: max(baseFrame.width, 260), height: fanHeight, alignment: .bottom)
                .contentShape(Rectangle())
                .gesture(press)
                .allowsHitTesting(isOpen)
                .accessibilityHidden(true)
            }
            .offset(lean)
            .animation(.smooth(duration: 0.25), value: isOpen)
            .sensoryFeedback(.selection, trigger: highlighted) { _, new in new != nil }
            // Coming out, as a menu does under a hold. Rigid: sharper than the heaviest soft one.
            .sensoryFeedback(.impact(flexibility: .rigid, intensity: 1), trigger: isOpen) { old, new in new && !old }
            .onChange(of: items.isEmpty) { _, empty in if empty { isOpen = false } }
            .accessibilityActions {
                ForEach(items) { item in
                    Button(item.title) { choose(item) }
                }
            }
    }

    private var fanHeight: CGFloat {
        baseFrame.height + 8 + CGFloat(items.count) * Self.step
    }

    /// Item `place`'s chip: that many steps over the capsule when out (behind it, folded).
    private func chip(_ item: FanItem, place: Int) -> some View {
        let y: CGFloat = isOpen ? -(baseFrame.height + 8 + CGFloat(place) * Self.step) : 0
        return FanChip(title: item.title, symbolImage: item.symbolImage, count: item.count,
                       isDestructive: item.isDestructive, isHighlighted: item.id == highlighted)
            .frame(maxWidth: 260)
            .offset(y: y)
            .opacity(isOpen ? 1 : 0)
    }

    /// One touch does it all. Held (or slid up): out they come. Moving: the chip under the finger
    /// is highlighted, and they lean a little its way. Let go on one, it's chosen; back on the
    /// capsule, they stay out; anywhere else, they fold. A tap brings them out, or, while they're
    /// out, folds them.
    private var press: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
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
                lean = CGSize(width: t.width * Self.leaning, height: t.height * Self.leaning)
                let found = item(at: value.location)
                if found?.id != highlighted { highlighted = found?.id }
            }
            .onEnded { value in
                holdTask?.cancel()
                let ended = touch ?? Touch(wasOpen: isOpen)
                touch = nil
                defer {
                    highlighted = nil
                    withAnimation(.spring(duration: 0.3)) { lean = .zero }
                }
                let isTap = !ended.hasMoved && !ended.isHeld
                if let found = item(at: value.location) {
                    choose(found)
                } else if ended.wasOpen || !baseFrame.insetBy(dx: -8, dy: -8).contains(value.location) {
                    isOpen = false  // let go off them, or a tap on the capsule while they're out
                } else if isTap {
                    isOpen = true
                }
                // Otherwise, let go back on the capsule after bringing them out: they stay out.
            }
    }

    /// The chip fanned out at a point on screen. Each one's band starts a little under it: the
    /// capsule keeps its whole height (a finger on its top half isn't on the chip above).
    private func item(at point: CGPoint) -> FanItem? {
        guard isOpen else { return nil }
        let aboveBase = baseFrame.maxY - point.y - baseFrame.height - 4
        guard aboveBase >= 0 else { return nil }
        let place = Int((aboveBase / Self.step).rounded(.down))
        return items.indices.contains(place) ? items[place] : nil
    }

    private func choose(_ item: FanItem) {
        isOpen = false
        item.action()
    }
}

/// A chip: an icon, a title, and a count after it.
struct FanChip: View {
    let title: String
    let symbolImage: String
    var count: Int? = nil
    var isDestructive = false
    /// Under the finger: letting go chooses it.
    var isHighlighted = false

    static let height: CGFloat = 36

    var body: some View {
        let label = HStack(spacing: 6) {
            Image(systemName: symbolImage)
                .foregroundStyle(isDestructive ? AnyShapeStyle(.red) : AnyShapeStyle(.tint))
            Text(title)
                .foregroundStyle(isDestructive ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
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
        .frame(height: Self.height)
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
