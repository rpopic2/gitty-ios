import SwiftUI
import UIKit

/// Naming a new album (or renaming one), in an alert over the whole app: it's asked for from
/// menus anywhere, the pager's text menu included.
@MainActor @Observable
final class AlbumNaming {
    var isPresented = false
    var name = ""
    /// The album being renamed; `nil` for a new one.
    private(set) var renamingID: UUID?
    private(set) var projectID = ""
    /// What goes into the new album.
    private(set) var items: [AlbumItem] = []
    /// Show the new album once it's made (made from the sidebar).
    private(set) var opensAlbum = false

    var title: LocalizedStringKey { renamingID == nil ? "New Album" : "Rename Album" }

    func begin(projectID: String, items: [AlbumItem] = [], opensAlbum: Bool = false) {
        renamingID = nil
        self.projectID = projectID
        self.items = items
        self.opensAlbum = opensAlbum
        name = ""
        isPresented = true
    }

    func beginRenaming(_ album: Album) {
        renamingID = album.id
        projectID = album.projectID
        items = []
        opensAlbum = false
        name = album.name
        isPresented = true
    }

    /// Save: renames, or makes the album. Returns a new album that should be shown.
    func commit(in store: AlbumStore = .shared) -> Album? {
        defer {
            items = []
            renamingID = nil
        }
        if let renamingID {
            store.rename(renamingID, to: name)
            return nil
        }
        guard !projectID.isEmpty else { return nil }
        let album = store.create(named: name, projectID: projectID, items: items)
        return opensAlbum ? album : nil
    }
}

/// The alert `AlbumNaming` asks with.
struct AlbumNamingAlert: ViewModifier {
    @Bindable var naming: AlbumNaming
    let onCreated: @MainActor (Album) -> Void

    func body(content: Content) -> some View {
        content.alert(naming.title, isPresented: $naming.isPresented) {
            TextField("Title", text: $naming.name)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                if let album = naming.commit() { onCreated(album) }
            }
        } message: {
            if naming.renamingID == nil { Text("Enter a name for this album.") }
        }
    }
}

/// What the menus of a list need for albums: the project the list is of, and the album it
/// shows (if it shows one).
nonisolated struct AlbumMenuContext: Equatable, Sendable {
    let projectID: String
    let shownAlbumID: UUID?
}

/// "Add to Album" (with a checkmark at the albums that have it already: choosing one of those
/// takes it out), and in an album, "Remove from Album". For a long-press menu.
struct AlbumMenuItems: View {
    let items: [AlbumItem]
    let context: AlbumMenuContext
    /// A file to download first, so its symbols can be listed (from Project, where files may
    /// not be saved yet).
    var download: URL? = nil
    /// After any choice (the selection ends).
    var onDone: (@MainActor () -> Void)? = nil

    @Environment(AlbumNaming.self) private var naming: AlbumNaming?

    private var store: AlbumStore { .shared }

    var body: some View {
        if let album = store.album(id: context.shownAlbumID) {
            removeButton(album)
        }
        Menu {
            Button("New Album…", systemImage: "plus") {
                startDownload()
                naming?.begin(projectID: context.projectID, items: items)
                onDone?()
            }
            Section {
                ForEach(store.albums(inProject: context.projectID)) { album in
                    let hasAll = !items.isEmpty && items.allSatisfy { album.contains($0) }
                    Button {
                        if hasAll {
                            store.remove(items, from: album.id)
                        } else {
                            startDownload()
                            store.add(items, to: album.id)
                        }
                        onDone?()
                    } label: {
                        if hasAll { Label(album.name, systemImage: "checkmark") } else { Text(album.name) }
                    }
                }
            }
        } label: {
            Label("Add to Album", systemImage: "rectangle.stack.badge.plus")
        }
        .disabled(items.isEmpty)
    }

    /// Takes it out of the album on screen; a symbol that's there through its whole file takes
    /// the file out (the button says so).
    @ViewBuilder
    private func removeButton(_ album: Album) -> some View {
        let direct = items.filter { album.contains($0) }
        if !direct.isEmpty {
            Button("Remove from Album", systemImage: "minus.circle", role: .destructive) {
                store.remove(direct, from: album.id)
                onDone?()
            }
        } else if items.count == 1, let file = items.first?.file, album.containsFile(file) {
            Button("Remove \(file.displayFileName) from Album", systemImage: "minus.circle", role: .destructive) {
                store.remove([.file(file)], from: album.id)
                onDone?()
            }
        }
    }

    private func startDownload() {
        guard let download else { return }
        Task {
            if await DocumentStore.shared.cached(download) == nil,
               (try? await DocumentStore.shared.fetch(download)) != nil {
                AlbumStore.shared.fileDownloaded()
            }
        }
    }
}

/// The text menu's "Add to Album" on a page, for the selected lines (UIKit's edit menu).
enum AlbumTextMenu {
    @MainActor
    static func menu(for item: AlbumItem, projectID: String, store: AlbumStore = .shared,
                     naming: AlbumNaming?) -> UIMenu {
        let new = UIAction(title: String(localized: "New Album…"), image: UIImage(systemName: "plus")) { _ in
            naming?.begin(projectID: projectID, items: [item])
        }
        let albums = store.albums(inProject: projectID).map { album in
            let has = album.contains(item)
            return UIAction(title: album.name, state: has ? .on : .off) { _ in
                if has { store.remove([item], from: album.id) } else { store.add([item], to: album.id) }
            }
        }
        return UIMenu(title: String(localized: "Add to Album"), image: UIImage(systemName: "rectangle.stack.badge.plus"),
                      children: [new] + (albums.isEmpty ? [] : [UIMenu(options: .displayInline, children: albums)]))
    }
}

// MARK: - Selecting

/// Select at the Symbols level, like Photos': tap cards to choose them, then Add to Album.
/// Observed in small pieces (each card's mark, the bar), so a tap redraws little.
@MainActor @Observable
final class SymbolSelection {
    private(set) var isActive = false
    private(set) var ids: Set<Int> = []

    func begin(with id: Int? = nil) {
        ids = id.map { [$0] } ?? []
        isActive = true
    }

    func toggle(_ id: Int) {
        if ids.contains(id) { ids.remove(id) } else { ids.insert(id) }
    }

    func end() {
        guard isActive else { return }
        isActive = false
        ids = []
    }
}

/// A card's check while selecting.
struct SelectionMark: View {
    let selection: SymbolSelection
    let id: Int

    var body: some View {
        if selection.isActive {
            let isSelected = selection.ids.contains(id)
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.title2)
                .symbolRenderingMode(.palette)
                .foregroundStyle(isSelected ? Color.white : Color.secondary,
                                 isSelected ? Color.accentColor : Color.clear)
                .background(Circle().fill(.background).padding(2))
                .padding(10)
                .accessibilityHidden(true)
        }
    }
}

/// Instead of the bar while selecting: Cancel, how many, and what to do with them.
struct AlbumSelectionBar: View {
    let selection: SymbolSelection
    /// The chosen entries as album items.
    let items: @MainActor (Set<Int>) -> [AlbumItem]
    let context: AlbumMenuContext

    var body: some View {
        let chosen = items(selection.ids)
        HStack(spacing: 12) {
            Button("Cancel") { selection.end() }
            Spacer(minLength: 8)
            Text(selection.ids.isEmpty ? "Select Items" : "\(selection.ids.count) Selected")
                .font(.headline)
                .monospacedDigit()
            Spacer(minLength: 8)
            Menu {
                AlbumMenuItems(items: chosen, context: context, onDone: { selection.end() })
            } label: {
                Label("Album", systemImage: "rectangle.stack.badge.plus")
                    .labelStyle(.iconOnly)
                    .font(.title3)
            }
            .disabled(chosen.isEmpty)
            .accessibilityLabel("Album")
        }
        .padding(.horizontal, 20)
        .frame(height: FileBarMetrics.fieldHeight)
        .modifier(FieldBackground())
        .padding(.horizontal, FileBarMetrics.fieldHorizontalMargin)
        .padding(.vertical, 8)
        .modifier(EditorBarBackground())
    }
}
