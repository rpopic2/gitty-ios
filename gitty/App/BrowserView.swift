import SwiftUI
import UIKit

/// The root: the file at the URL the reader entered, or the start page before any, with the
/// sidebar (Files, projects, Settings) to the right. The last opened URL and the open project are
/// remembered across launches. Links shared from Safari arrive as `gitty://open?url=…` (see the
/// gittyShare extension). A GitHub repository link adds a project and opens it.
struct BrowserView: View {
    @AppStorage("currentURL") private var currentURLString = ""
    /// The project chosen in the sidebar, shown in Project mode; "" for Files.
    @AppStorage("openProjectID") private var openProjectID = ""
    @SceneStorage("viewMode") private var mode: ViewMode = .code
    /// The file just opened (from Project, the bar or a link), which starts at its own entry in
    /// the Code level. The file shown at launch comes back where it was left instead.
    @State private var openedURL: URL?
    /// When the open file isn't in the project chosen in the sidebar: that project's file to open
    /// on moving from Project to Files, Symbols or Code, which list the open file's project.
    @State private var projectStartURL: URL?
    @State private var isEditingAddress = false
    /// A shared or pasted address that isn't a URL we can open: shown in the editor with the reason.
    @State private var rejectedAddress: String?
    @State private var sideBar = SideBarState()
    @State private var isShowingSettings = false
    /// The review that Comment adds to, kept until it's shared or deleted.
    @State private var review = ReviewDraft()
    /// The identifier highlighted on pages, kept across files until it's removed.
    @State private var highlights = HighlightState()
    /// The code font and size, chosen in the sidebar.
    @AppStorage(CodeTextStyle.fontKey) private var codeFont: CodeFont = .courier
    @AppStorage(CodeTextStyle.sizeKey) private var codeFontSize = Double(CodeTextStyle.defaultSize)
    @AppStorage(CodeTextStyle.themeKey) private var syntaxTheme: SyntaxTheme = .default

    private var currentURL: URL? {
        currentURLString.isEmpty ? nil : URL(string: currentURLString)
    }

    var body: some View {
        SideBarContainer(state: sideBar) {
            NavigationStack {
                if let url = currentURL {
                    CodeScreen(url: url, mode: modeBinding, projectID: openProjectID,
                               opensAtFile: url == openedURL,
                               isEditingAddress: $isEditingAddress, rejectedAddress: rejectedAddress,
                               onOpen: open, onPasteAndGo: pasteAndGo)
                        .id(url)  // a new URL gets a fresh screen and model
                } else {
                    StartScreen(projectID: openProjectID, isEditingAddress: $isEditingAddress,
                                rejectedAddress: rejectedAddress, onOpen: open, onPasteAndGo: pasteAndGo)
                }
            }
            // Like Mail's compose window: swiping it down sets the review aside, docked above the bar.
            .sheet(isPresented: $review.isComposing) { ReviewComposer(draft: review) }
        } sideBar: {
            SideBarView(
                selectedID: openProjectID,
                onSelect: showProject,
                onDelete: { id in if id == openProjectID { openProjectID = "" } },
                onSettings: {
                    sideBar.close()
                    isShowingSettings = true
                }
            )
        }
        .environment(sideBar)
        .environment(review)
        .environment(highlights)
        .environment(\.codeTextStyle, CodeTextStyle(font: codeFont, size: CGFloat(codeFontSize), theme: syntaxTheme))
        .sheet(isPresented: $isShowingSettings) { SettingsView() }
        .onOpenURL(perform: openShared)
        .task(id: [openProjectID, currentURLString]) {
            let current = currentURL
            projectStartURL = nil  // until it's known: the open file stays
            projectStartURL = await ProjectStartFile.find(projectID: openProjectID, current: current)
        }
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

    /// The level shown. Leaving Project for a symbol level switches to the chosen project's
    /// file first, if the open file is in another project (see `projectStartURL`).
    private var modeBinding: Binding<ViewMode> {
        Binding(get: { mode }, set: { level in
            if mode == .project, level.showsSymbols, let url = projectStartURL {
                openFile(url, at: level)
            } else {
                mode = level
            }
        })
    }

    /// Opening a file shows its code, from its own entry (or another level, from the selector).
    private func open(_ url: URL) {
        openFile(url, at: .code)
    }

    private func openFile(_ url: URL, at level: ViewMode) {
        isEditingAddress = false
        if let repository = RepoLink(url) {
            openProject(repository)
            return
        }
        RecentFilesStore.standard.add(url)
        Task { await OpenHistory.shared.recordOpen(url) }  // for recently opened order
        openedURL = url
        projectStartURL = nil
        mode = level
        currentURLString = url.absoluteString  // the same URL keeps its screen: no reload
    }

    /// A repository (or folder) link: add it to the projects and show its files.
    private func openProject(_ repository: RepoLink) {
        Task {
            let project = await ProjectStore.shared.add(repository)
            showProject(project.id)
        }
    }

    /// Makes a project (or Files, for "") the open one and shows it in the Project tab.
    private func showProject(_ id: String) {
        openProjectID = id
        mode = .project
        isEditingAddress = false
        sideBar.close()
    }
}

/// Before any file is open: the Project list with the address bar selected and the keyboard
/// up, like a new Safari tab.
private struct StartScreen: View {
    let projectID: String
    @Binding var isEditingAddress: Bool
    let rejectedAddress: String?
    let onOpen: @MainActor (URL) -> Void
    let onPasteAndGo: @MainActor () -> Void
    /// The project chosen in the sidebar, for the bar (`nil` for Files).
    @State private var project: ProjectInfo?

    init(projectID: String, isEditingAddress: Binding<Bool>, rejectedAddress: String?,
         onOpen: @escaping @MainActor (URL) -> Void, onPasteAndGo: @escaping @MainActor () -> Void) {
        self.projectID = projectID
        _isEditingAddress = isEditingAddress
        self.rejectedAddress = rejectedAddress
        self.onOpen = onOpen
        self.onPasteAndGo = onPasteAndGo
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            ProjectView(projectID: projectID, onOpen: onOpen)
            if isEditingAddress {
                AddressEditor(initialText: rejectedAddress ?? projectAddress,
                              showsInitialError: rejectedAddress != nil,
                              onOpen: onOpen, onCancel: { isEditingAddress = false })
                    .id(rejectedAddress)  // a new rejected share restarts the editor with it
            } else {
                BottomBarStack(
                    title: project?.title ?? "",  // empty: "Enter URL"
                    isCollapsed: false,
                    progressFraction: 0,
                    isProgressVisible: false,
                    mode: nil,
                    onExpand: {},
                    onEdit: { isEditingAddress = true },
                    copyText: project == nil ? nil : projectAddress,
                    onPasteAndGo: onPasteAndGo
                )
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .onAppear { isEditingAddress = projectID.isEmpty }  // a project to browse keeps the keyboard down
        .task(id: projectID) {
            project = projectID.isEmpty ? nil : await ProjectStore.shared.project(id: projectID)
        }
    }

    /// The project's address on github.com, or nothing (Files).
    private var projectAddress: String {
        project?.link.webURL?.absoluteString ?? ""
    }
}
