import SwiftUI
import UIKit

/// Editing the address, like tapping Safari's address bar: a focused URL field at the bottom (above
/// the keyboard) and recently opened files above it. Covers the screen while it's open.
struct AddressEditor: View {
    /// What the field starts with: the current URL, selected, or nothing on the start page.
    let initialText: String
    let onOpen: @MainActor (URL) -> Void
    let onCancel: @MainActor () -> Void

    @State private var text = ""
    @State private var selection: TextSelection?
    @State private var errorMessage: String?
    @State private var recents: [URL] = []
    @FocusState private var isFocused: Bool

    private var store: RecentFilesStore { .standard }

    /// All recents until the reader starts typing, then the ones that contain the text.
    private var shownRecents: [URL] {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, query != initialText else { return recents }
        return recents.filter { $0.absoluteString.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(spacing: 0) {
            RecentFilesList(urls: shownRecents, onOpen: onOpen) { url in
                store.remove(url)
                recents = store.urls()
            }
            editorBar
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .onAppear {
            recents = store.urls()
            text = initialText
            selection = TextSelection(range: text.startIndex..<text.endIndex)  // like Safari
        }
        .task { isFocused = true }  // after the first layout, so the keyboard comes up reliably
        .onChange(of: text) { errorMessage = nil }
    }

    private var editorBar: some View {
        VStack(spacing: 6) {
            if let errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .transition(.opacity)
            }
            HStack(spacing: 12) {
                field
                Button("Cancel") { onCancel() }
            }
        }
        .padding(.horizontal, FileBarMetrics.fieldHorizontalMargin)
        .padding(.vertical, 8)
        .modifier(EditorBarBackground())
    }

    private var field: some View {
        HStack(spacing: 6) {
            TextField("Enter URL", text: $text, selection: $selection)
                .focused($isFocused)
                .keyboardType(.URL)
                .textContentType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.go)
                .onSubmit(submit)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear")
            }
        }
        .padding(.horizontal, 14)
        .frame(height: FileBarMetrics.fieldHeight)
        .modifier(FieldBackground())
    }

    private func submit() {
        switch AddressParser.parse(text) {
        case .url(let url):
            onOpen(url)
        case .invalid(let message):
            withAnimation(.easeOut(duration: 0.15)) { errorMessage = message }
            isFocused = true
        }
    }
}

/// Recently opened files: name and location. Tap to open, swipe to remove.
private struct RecentFilesList: View {
    let urls: [URL]
    let onOpen: @MainActor (URL) -> Void
    let onRemove: @MainActor (URL) -> Void

    var body: some View {
        List {
            if !urls.isEmpty {
                Section("Recent Files") {
                    ForEach(urls, id: \.self) { url in
                        Button { onOpen(url) } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(url.displayFileName)
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                Text(url.displayLocation)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                        .swipeActions {
                            Button(role: .destructive) { onRemove(url) } label: {
                                Label("Remove", systemImage: "trash")
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .scrollDismissesKeyboard(.interactively)
    }
}

/// The field's shape, matching the bar: a glass capsule on iOS 26+, a rounded field on iOS 18.
private struct FieldBackground: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular.interactive(), in: Capsule())
        } else {
            content.background(
                Color(uiColor: .tertiarySystemFill),
                in: RoundedRectangle(cornerRadius: FileBarMetrics.fieldCornerRadius, style: .continuous)
            )
        }
    }
}

/// iOS 18 draws the toolbar material behind the bar. iOS 26's glass field floats on its own.
private struct EditorBarBackground: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
        } else {
            content.background(.bar, ignoresSafeAreaEdges: .bottom)
        }
    }
}
