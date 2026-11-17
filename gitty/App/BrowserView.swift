import SwiftUI
import UIKit

/// The root: the file at the URL the reader entered, or the start page before any.
/// The last opened URL is remembered across launches. Links shared from Safari arrive as
/// `gitty://open?url=…` (see the gittyShare extension). A GitHub repository link opens as a
/// project, whose folders are pushed onto this navigation stack.
struct BrowserView: View {
    @AppStorage("currentURL") private var currentURLString = ""
    @SceneStorage("viewMode") private var mode: ViewMode = .file
    @State private var isEditingAddress = false
    /// Project folders on screen (Files-app style).
    @State private var projectPath: [ProjectRoute] = []
    /// A shared or pasted address that isn't a URL we can open: shown in the editor with the reason.
    @State private var rejectedAddress: String?

    private var currentURL: URL? {
        currentURLString.isEmpty ? nil : URL(string: currentURLString)
    }

    var body: some View {
        NavigationStack(path: $projectPath) {
            Group {
                if let url = currentURL {
                    CodeScreen(url: url, isEditingAddress: $isEditingAddress,
                               rejectedAddress: rejectedAddress, onOpen: open, onPasteAndGo: pasteAndGo)
                        .id(url)  // a new URL gets a fresh screen and model
                } else {
                    StartScreen(isEditingAddress: $isEditingAddress,
                                rejectedAddress: rejectedAddress, onOpen: open, onPasteAndGo: pasteAndGo)
                }
            }
            .navigationDestination(for: ProjectRoute.self) { route in
                ProjectFolderView(route: route) { url in
                    mode = .file  // opening a project file shows it
                    open(url)
                }
            }
        }
        .onOpenURL(perform: openShared)
        .onChange(of: isEditingAddress) { _, isEditing in
            if !isEditing { rejectedAddress = nil }
        }
    }

    private func openShared(_ link: URL) {
        guard let address = AddressParser.sharedAddress(in: link) else { return }
        openAddress(address)
    }

    /// Long-press on the bar ▸ Paste and Go.
    private func pasteAndGo() {
        guard let address = Clipboard.address() else { return }
        openAddress(address)
    }

    /// Same as typing the address into the bar and tapping Go.
    private func openAddress(_ address: String) {
        switch AddressParser.parse(address) {
        case .url(let url):
            open(url)
        case .invalid:
            rejectedAddress = address
            isEditingAddress = true
        }
    }

    private func open(_ url: URL) {
        isEditingAddress = false
        if let repository = RepoLink(url) {
            openProject(repository)
            return
        }
        RecentFilesStore.standard.add(url)
        projectPath.removeAll()  // back from any project folder to the file
        currentURLString = url.absoluteString  // the same URL keeps its screen: no reload
    }

    /// A repository (or folder) link: add it to Projects and show its files.
    private func openProject(_ repository: RepoLink) {
        Task {
            let project = await ProjectStore.shared.add(repository)
            projectPath = [ProjectRoute(projectID: project.id, folder: nil)]
        }
    }
}

/// Before any file is open: the Project list (recent and saved files) with the address bar
/// selected and the keyboard up, like a new Safari tab.
private struct StartScreen: View {
    @Binding var isEditingAddress: Bool
    let rejectedAddress: String?
    let onOpen: @MainActor (URL) -> Void
    let onPasteAndGo: @MainActor () -> Void

    var body: some View {
        ZStack(alignment: .bottom) {
            ProjectView(onOpen: onOpen)
            if isEditingAddress {
                AddressEditor(initialText: rejectedAddress ?? "", showsInitialError: rejectedAddress != nil,
                              onOpen: onOpen, onCancel: { isEditingAddress = false })
                    .id(rejectedAddress)  // a new rejected share restarts the editor with it
            } else {
                BottomBarStack(
                    title: "",
                    isCollapsed: false,
                    progressFraction: 0,
                    isProgressVisible: false,
                    mode: nil,
                    onExpand: {},
                    onEdit: { isEditingAddress = true },
                    onPasteAndGo: onPasteAndGo
                )
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .onAppear { isEditingAddress = true }
    }
}
