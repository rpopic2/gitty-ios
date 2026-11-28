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
/// how many cards it has (or how many stacks there are). Hold it (or tap it) and the stacks fan
/// out, the latest nearest; choose one to open it (`HoldFan`).
struct SetAsideChips: View {
    let stacks: [SetAsideStack]
    /// Fanned out (the screen blurs behind it).
    @Binding var isOpen: Bool
    let onOpen: @MainActor (SetAsideStack) -> Void
    let onDrop: @MainActor (SetAsideStack) -> Void

    /// A chip's height.
    static var chipHeight: CGFloat { FanChip.height }

    var body: some View {
        let latestFirst: [SetAsideStack] = stacks.reversed()
        let items: [FanItem] = latestFirst.map {
            FanItem(id: $0.id.uuidString, title: $0.title, symbolImage: $0.symbolImage, count: $0.cardCount)
        }
        if let latest = stacks.last {
            HoldFan(items: items, isOpen: $isOpen, onChoose: { item in
                if let stack = stacks.first(where: { $0.id.uuidString == item.id }) { onOpen(stack) }
            }) {
                mainChip(latest)
            }
            .transition(.scale(scale: 0.8).combined(with: .opacity))
            .animation(.smooth(duration: 0.25), value: stacks.map(\.id))
            .accessibilityElement(children: .combine)
            .accessibilityActions {
                ForEach(latestFirst) { stack in
                    Button(String(localized: "Remove \(stack.title)")) { onDrop(stack) }
                }
            }
        }
    }

    /// The latest stack, or how many there are.
    private func mainChip(_ latest: SetAsideStack) -> some View {
        let several: Bool = stacks.count > 1
        let title: String = several ? String(localized: "\(stacks.count) Stacks") : latest.title
        let image: String = isOpen ? "chevron.down" : (several ? "square.stack.3d.up" : latest.symbolImage)
        return FanChip(title: title, symbolImage: image, count: several ? nil : latest.cardCount)
            .frame(maxWidth: 220)
    }
}
