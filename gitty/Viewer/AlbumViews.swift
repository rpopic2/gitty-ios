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
    /// The sheet that asks instead of the app (`AlbumNamingAlert.host`), while it's up: the
    /// app's alert can't show over a sheet, and trying closed the sheet.
    var host: String?

    var title: LocalizedStringKey { renamingID == nil ? "New Album" : "Rename Album" }

    /// A diff album just made (Make Album, in a commit's or a comparison's files), named
    /// after them: the app shows it at the Code level (then sets this back to `nil`).
    private(set) var madeDiffAlbum: Album?
    /// Goes up with each one made: the project's sheets the diff was shown in close.
    private(set) var madeDiffAlbumCount = 0

    func makeDiffAlbum(named name: String, projectID: String, diff: AlbumDiff) {
        madeDiffAlbum = AlbumStore.shared.create(named: name, projectID: projectID, diff: diff)
        madeDiffAlbumCount += 1
    }

    func didShowDiffAlbum() {
        madeDiffAlbum = nil
    }

    /// New Album: made at once, "New Album" (numbered when that's taken), with `items` in it,
    /// without asking for a name (rename it on the albums page). `opensAlbum`: shown at the
    /// Code level then (`albumToShow`).
    @discardableResult
    func begin(projectID: String, items: [AlbumItem] = [], opensAlbum: Bool = false) -> Album? {
        guard !projectID.isEmpty else { return nil }
        let album = AlbumStore.shared.createUntitled(projectID: projectID, items: items)
        if opensAlbum { albumToShow = album }
        return album
    }

    /// A new album to show at the Code level (the app shows it, then sets this back to `nil`).
    private(set) var albumToShow: Album?

    func didShowAlbum() {
        albumToShow = nil
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
    /// Which alert this is: the app's (`nil`), or a sheet's (`AlbumNaming.host`). Only the one
    /// that matches shows.
    var host: String? = nil
    let onCreated: @MainActor (Album) -> Void

    private var isPresented: Binding<Bool> {
        Binding(get: { naming.isPresented && naming.host == host },
                set: { naming.isPresented = $0 })
    }

    func body(content: Content) -> some View {
        content.alert(naming.title, isPresented: isPresented) {
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
    /// The albums right in the menu, not under "Add to Album" (a menu of its own, such as an
    /// Add to Album button's).
    var isInline = false
    /// After adding to an album (or making one): which.
    var onAdd: (@MainActor (UUID) -> Void)? = nil

    @Environment(AlbumNaming.self) private var naming: AlbumNaming?

    private var store: AlbumStore { .shared }

    var body: some View {
        if let album = store.album(id: context.shownAlbumID) {
            removeButton(album)
        }
        if isInline {
            albumChoices
        } else {
            Menu {
                albumChoices
            } label: {
                Label("Add to Album", systemImage: "rectangle.stack.badge.plus")
            }
            .disabled(items.isEmpty)
        }
    }

    @ViewBuilder
    private var albumChoices: some View {
        Button("New Album", systemImage: "plus") {
            startDownload()
            let album = naming?.begin(projectID: context.projectID, items: items)
            onDone?()
            if let album { onAdd?(album.id) }
        }
        .disabled(items.isEmpty)
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
                    if !hasAll { onAdd?(album.id) }
                } label: {
                    if hasAll { Label(album.name, systemImage: "checkmark") } else { Text(album.name) }
                }
                .disabled(items.isEmpty)
            }
        }
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
        let new = UIAction(title: String(localized: "New Album"), image: UIImage(systemName: "plus")) { _ in
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
