import SwiftUI
import UIKit

/// Editing the address, like tapping Safari's address bar: a focused URL field at the bottom, above
/// the keyboard, with Cancel and a hint when the text can't be opened. Recent and saved files are
/// in the Project view.
struct AddressEditor: View {
    /// What the field starts with: the current URL, selected, or nothing on the start page.
    let initialText: String
    /// Show right away why `initialText` can't be opened (a shared link that isn't a URL).
    var showsInitialError = false
    let onOpen: @MainActor (URL) -> Void
    let onCancel: @MainActor () -> Void

    @State private var text: String
    @State private var errorMessage: String?

    init(initialText: String, showsInitialError: Bool = false,
         onOpen: @escaping @MainActor (URL) -> Void, onCancel: @escaping @MainActor () -> Void) {
        self.initialText = initialText
        self.showsInitialError = showsInitialError
        self.onOpen = onOpen
        self.onCancel = onCancel
        _text = State(initialValue: initialText)
    }

    var body: some View {
        editorBar
            .onAppear {
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
        URLTextField(text: $text, onSubmit: submit, onPasteAndGo: pasteAndGo)
            .padding(.horizontal, 14)
            .frame(height: FileBarMetrics.fieldHeight)
            .modifier(FieldBackground())
    }

    /// The field's edit menu ▸ Paste and Go: put the copied address in the field and go.
    private func pasteAndGo(_ address: String) {
        text = address
        submit()
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
    let onPasteAndGo: @MainActor (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onSubmit: onSubmit, onPasteAndGo: onPasteAndGo)
    }

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
        context.coordinator.onPasteAndGo = onPasteAndGo
        if field.text != text { field.text = text }
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var text: Binding<String>
        var onSubmit: @MainActor () -> Void
        var onPasteAndGo: @MainActor (String) -> Void

        init(text: Binding<String>, onSubmit: @escaping @MainActor () -> Void,
             onPasteAndGo: @escaping @MainActor (String) -> Void) {
            self.text = text
            self.onSubmit = onSubmit
            self.onPasteAndGo = onPasteAndGo
        }

        /// Adds Paste and Go right after Paste, like Safari's address field.
        func textField(_ textField: UITextField, editMenuForCharactersIn range: NSRange,
                       suggestedActions: [UIMenuElement]) -> UIMenu? {
            guard Clipboard.hasAddress else { return nil }  // nil: the standard menu
            let pasteAndGo = UIAction(title: String(localized: "Paste and Go")) { [weak self] _ in
                guard let address = Clipboard.address() else { return }
                self?.onPasteAndGo(address)
            }
            let children = Self.inserting(pasteAndGo, afterPasteIn: suggestedActions)
                ?? [pasteAndGo] + suggestedActions  // no Paste item found: put it first
            return UIMenu(children: children)
        }

        /// `elements` with `action` right after the Paste command (searched in submenus too),
        /// or `nil` if there's no Paste.
        private static func inserting(_ action: UIAction, afterPasteIn elements: [UIMenuElement]) -> [UIMenuElement]? {
            let paste = #selector(UIResponderStandardEditActions.paste(_:))
            if let index = elements.firstIndex(where: { ($0 as? UICommand)?.action == paste }) {
                var result = elements
                result.insert(action, at: index + 1)
                return result
            }
            for (index, element) in elements.enumerated() {
                guard let menu = element as? UIMenu,
                      let children = inserting(action, afterPasteIn: menu.children)
                else { continue }
                var result = elements
                result[index] = menu.replacingChildren(children)
                return result
            }
            return nil
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
