import SwiftUI
import UIKit

/// Editing the address, like tapping Safari's address bar: a focused URL field at the bottom (above
/// the keyboard) and recently opened files above it. Covers the screen while it's open.
struct AddressEditor: View {
    /// What the field starts with: the current URL, selected, or nothing on the start page.
    let initialText: String
    /// Show right away why `initialText` can't be opened (a shared link that isn't a URL).
    var showsInitialError = false
    let onOpen: @MainActor (URL) -> Void
    let onCancel: @MainActor () -> Void

    @State private var text: String
    @State private var errorMessage: String?
    @State private var recents: [URL] = []

    init(initialText: String, showsInitialError: Bool = false,
         onOpen: @escaping @MainActor (URL) -> Void, onCancel: @escaping @MainActor () -> Void) {
        self.initialText = initialText
        self.showsInitialError = showsInitialError
        self.onOpen = onOpen
        self.onCancel = onCancel
        _text = State(initialValue: initialText)
    }

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
            if showsInitialError, case .invalid(let message) = AddressParser.parse(initialText) {
                errorMessage = message
            }
        }
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
        URLTextField(text: $text, onSubmit: submit)
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
        }
    }
}

/// The URL field: a UIKit text field, like Safari's. It takes focus and selects the whole URL
/// when it appears, has the system clear button, and keeps its own selection valid as the text
/// changes. (SwiftUI's `TextField(selection:)` with a preset selection crashed on delete, because
/// the selection still pointed into the old, longer text.)
private struct URLTextField: UIViewRepresentable {
    @Binding var text: String
    let onSubmit: @MainActor () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(text: $text, onSubmit: onSubmit) }

    func makeUIView(context: Context) -> UITextField {
        let field = UITextField()
        field.placeholder = String(localized: "Enter URL")
        field.text = text
        field.font = .preferredFont(forTextStyle: .body)
        field.adjustsFontForContentSizeCategory = true
        field.keyboardType = .URL
        field.textContentType = .URL
        field.autocapitalizationType = .none
        field.autocorrectionType = .no
        field.spellCheckingType = .no
        field.returnKeyType = .go
        field.clearButtonMode = .whileEditing
        field.delegate = context.coordinator
        field.addTarget(context.coordinator, action: #selector(Coordinator.textChanged(_:)), for: .editingChanged)
        // Fill the width it's given instead of sizing to its text.
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        // Once it's in a window: bring up the keyboard and select the whole URL, like Safari.
        Task { @MainActor in
            field.becomeFirstResponder()
            field.selectAll(nil)
        }
        return field
    }

    func updateUIView(_ field: UITextField, context: Context) {
        context.coordinator.text = $text
        context.coordinator.onSubmit = onSubmit
        if field.text != text { field.text = text }
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var text: Binding<String>
        var onSubmit: @MainActor () -> Void

        init(text: Binding<String>, onSubmit: @escaping @MainActor () -> Void) {
            self.text = text
            self.onSubmit = onSubmit
        }

        @objc func textChanged(_ field: UITextField) {
            text.wrappedValue = field.text ?? ""
        }

        /// Go: open the URL, or keep the keyboard up while the hint explains what's wrong.
        func textFieldShouldReturn(_ field: UITextField) -> Bool {
            onSubmit()
            return false
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
