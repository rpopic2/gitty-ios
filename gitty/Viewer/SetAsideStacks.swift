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
/// fan them out into a row, one chip each; tap one to open it. Swipe a chip up to throw that
/// stack away.
struct SetAsideChips: View {
    let stacks: [SetAsideStack]
    let onOpen: @MainActor (SetAsideStack) -> Void
    let onDrop: @MainActor (SetAsideStack) -> Void

    @State private var isFannedOut = false

    var body: some View {
        Group {
            if isFannedOut, stacks.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        // The latest first, nearest where the chip was.
                        ForEach(Array(stacks.reversed())) { stack in
                            SetAsideChip(title: stack.title, symbolImage: stack.symbolImage,
                                         count: stack.cardCount,
                                         onTap: { open(stack) }, onDrop: { onDrop(stack) })
                                .transition(.scale(scale: 0.6).combined(with: .opacity))
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)  // room to swipe one up
                }
                .scrollClipDisabled()
                .transition(.opacity)
            } else if let latest = stacks.last {
                SetAsideChip(title: stacks.count > 1 ? String(localized: "\(stacks.count) Stacks") : latest.title,
                             symbolImage: stacks.count > 1 ? "square.stack.3d.up" : latest.symbolImage,
                             count: stacks.count > 1 ? nil : latest.cardCount,
                             onTap: {
                                 if stacks.count > 1 {
                                     withAnimation(.smooth(duration: 0.25)) { isFannedOut = true }
                                 } else {
                                     open(latest)
                                 }
                             },
                             // Several: swiping the folded chip away throws them all away.
                             onDrop: { for stack in stacks { onDrop(stack) } })
                    .frame(maxWidth: 220)
                    .transition(.scale(scale: 0.8).combined(with: .opacity))
            }
        }
        .animation(.smooth(duration: 0.25), value: stacks.map(\.id))
        // Down to one (or none): nothing to fan out.
        .onChange(of: stacks.count) { if stacks.count < 2 { isFannedOut = false } }
    }

    private func open(_ stack: SetAsideStack) {
        isFannedOut = false
        onOpen(stack)
    }
}

/// One chip: a stack's icon, its top page's name and its cards. Tap it; swipe it up to throw it
/// away (it follows the finger, and goes once far enough).
private struct SetAsideChip: View {
    let title: String
    let symbolImage: String
    /// Its cards (`nil`: several stacks under one chip).
    let count: Int?
    let onTap: @MainActor () -> Void
    let onDrop: @MainActor () -> Void

    @State private var dragY: CGFloat = 0
    /// Far enough up to throw away, with a tap of haptics as it gets there.
    private static let dropDistance: CGFloat = 50

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
        .frame(height: 36)
        .contentShape(Capsule())

        Group {
            if #available(iOS 26.0, *) {
                label.glassEffect(.regular.interactive(), in: Capsule())
            } else {
                label.background(.bar, in: Capsule())
            }
        }
        .onTapGesture { onTap() }
        .offset(y: dragY)
        .opacity(1 - min(1, max(0, -dragY) / (Self.dropDistance * 2)))
        .sensoryFeedback(.impact(weight: .light), trigger: dragY < -Self.dropDistance) { old, new in new && !old }
        .gesture(
            DragGesture(minimumDistance: 10)
                .onChanged { value in
                    let dy = value.translation.height
                    // Up freely; down only a little.
                    dragY = dy < 0 ? dy : dy / (1 + dy / 20)
                }
                .onEnded { value in
                    let drops = value.translation.height < -Self.dropDistance
                        || value.predictedEndTranslation.height < -Self.dropDistance * 3
                    if drops {
                        withAnimation(.smooth(duration: 0.2)) { dragY = -120 } completion: {
                            onDrop()
                            dragY = 0
                        }
                    } else {
                        withAnimation(.spring(duration: 0.3)) { dragY = 0 }
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

/// A page's caption (a card's, or a results page's capsule): swipe it up to set the stack
/// aside, or sideways to set it aside and go to the album beside, as the bar's swipe does. It
/// follows the finger a little, with a tap of haptics once far enough.
struct StackCaptionSwipes: ViewModifier {
    let actions: StackActions?

    @State private var drag: CGSize = .zero
    private static let upDistance: CGFloat = 50
    private static let sideDistance: CGFloat = 80

    func body(content: Content) -> some View {
        if let actions, actions.setAside != nil || actions.switchAlbum != nil {
            content
                .offset(x: drag.width, y: min(0, drag.height))
                .sensoryFeedback(.impact(weight: .light), trigger: isPastThreshold) { old, new in new && !old }
                .simultaneousGesture(
                    DragGesture(minimumDistance: 12)
                        .onChanged { value in
                            let t = value.translation
                            // One way at a time: the way it went first, dampened.
                            if abs(t.width) > abs(t.height) {
                                drag = CGSize(width: t.width / (1 + abs(t.width) / 160), height: 0)
                            } else {
                                drag = CGSize(width: 0, height: t.height < 0 ? t.height / (1 + abs(t.height) / 120) : 0)
                            }
                        }
                        .onEnded { value in
                            let t = value.translation, flung = value.predictedEndTranslation
                            withAnimation(.spring(duration: 0.3)) { drag = .zero }
                            if abs(t.width) > abs(t.height) {
                                let goes = abs(t.width) > Self.sideDistance || abs(flung.width) > Self.sideDistance * 2.5
                                // Finger to the left: the album after (as the bar's swipe).
                                if goes { _ = actions.switchAlbum?(t.width < 0) }
                            } else if t.height < -Self.upDistance || flung.height < -Self.upDistance * 3 {
                                actions.setAside?()
                            }
                        }
                )
        } else {
            content
        }
    }

    private var isPastThreshold: Bool {
        // In the dampened offset, about where the finger's thresholds are.
        drag.height < -Self.upDistance * 0.7 || abs(drag.width) > Self.sideDistance * 0.65
    }
}

extension View {
    /// See `StackCaptionSwipes`.
    func stackCaptionSwipes(_ actions: StackActions?) -> some View {
        modifier(StackCaptionSwipes(actions: actions))
    }
}
