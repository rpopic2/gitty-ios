import SwiftUI
import UIKit

/// The root: the file at the URL the reader entered, or the start page before any.
/// The last opened URL is remembered across launches. Links shared from Safari arrive as
/// `gitty://open?url=…` (see the gittyShare extension).
struct BrowserView: View {
    @AppStorage("currentURL") private var currentURLString = ""
    @State private var isEditingAddress = false
    /// A shared address that isn't a URL we can open: shown in the editor so the reader sees why.
    @State private var rejectedSharedAddress: String?

    private var currentURL: URL? {
        currentURLString.isEmpty ? nil : URL(string: currentURLString)
    }

    var body: some View {
        Group {
            if let url = currentURL {
                CodeScreen(url: url, isEditingAddress: $isEditingAddress,
                           rejectedAddress: rejectedSharedAddress, onOpen: open)
                    .id(url)  // a new URL gets a fresh screen and model
            } else {
                StartScreen(isEditingAddress: $isEditingAddress,
                            rejectedAddress: rejectedSharedAddress, onOpen: open)
            }
        }
        .onOpenURL(perform: openShared)
        .onChange(of: isEditingAddress) { _, isEditing in
            if !isEditing { rejectedSharedAddress = nil }
        }
    }

    /// Same as typing the address into the bar.
    private func openShared(_ link: URL) {
        guard let address = AddressParser.sharedAddress(in: link) else { return }
        switch AddressParser.parse(address) {
        case .url(let url):
            open(url)
        case .invalid:
            rejectedSharedAddress = address
            isEditingAddress = true
        }
    }

    private func open(_ url: URL) {
        RecentFilesStore.standard.add(url)
        isEditingAddress = false
        currentURLString = url.absoluteString  // the same URL keeps its screen: no reload
    }
}

/// Before any file is open: an empty page with the address bar ready, like a new Safari tab.
private struct StartScreen: View {
    @Binding var isEditingAddress: Bool
    let rejectedAddress: String?
    let onOpen: @MainActor (URL) -> Void

    var body: some View {
        ZStack(alignment: .bottom) {
            Color(uiColor: .systemBackground)
                .ignoresSafeArea()
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
                    onEdit: { isEditingAddress = true }
                )
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .onAppear { isEditingAddress = true }
    }
}
