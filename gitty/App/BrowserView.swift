import SwiftUI
import UIKit

/// The root: the file at the URL the reader entered, or the start page before any.
/// The last opened URL is remembered across launches.
struct BrowserView: View {
    @AppStorage("currentURL") private var currentURLString = ""
    @State private var isEditingAddress = false

    private var currentURL: URL? {
        currentURLString.isEmpty ? nil : URL(string: currentURLString)
    }

    var body: some View {
        if let url = currentURL {
            CodeScreen(url: url, isEditingAddress: $isEditingAddress, onOpen: open)
                .id(url)  // a new URL gets a fresh screen and model
        } else {
            StartScreen(isEditingAddress: $isEditingAddress, onOpen: open)
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
    let onOpen: @MainActor (URL) -> Void

    var body: some View {
        ZStack(alignment: .bottom) {
            Color(uiColor: .systemBackground)
                .ignoresSafeArea()
            if isEditingAddress {
                AddressEditor(initialText: "", onOpen: onOpen, onCancel: { isEditingAddress = false })
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
