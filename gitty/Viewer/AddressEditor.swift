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
        .modifier(OnSwipeDown())  // hides the keyboard; the address stays open for editing
    }

    private var field: some View {
        BarTextField(style: .url, text: $text, onSubmit: submit, onPasteAndGo: pasteAndGo)
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

/// The bar's text field (address or symbol search): a UIKit text field, like Safari's. It takes focus and selects the whole text
/// when it appears, has the system clear button, and keeps its own selection valid as the text
/// changes. (SwiftUI's `TextField(selection:)` with a preset selection crashed on delete, because
/// the selection still pointed into the old, longer text.)
private struct BarTextField: UIViewRepresentable {
    enum Style {
        /// The address: URL keyboard, Go, Paste and Go in the edit menu.
        case url
        /// Symbol search: normal keyboard, Search.
        case search
    }

    let style: Style
    @Binding var text: String
    let onSubmit: @MainActor () -> Void
    /// Adds Paste and Go to the edit menu when set.
    let onPasteAndGo: (@MainActor (String) -> Void)?

    // An explicit init (not the memberwise one) so passing in an existing `@MainActor` closure
    // doesn't warn about converting it to `@Sendable`.
    init(style: Style, text: Binding<String>, onSubmit: @escaping @MainActor () -> Void,
         onPasteAndGo: (@MainActor (String) -> Void)? = nil) {
        self.style = style
        _text = text
        self.onSubmit = onSubmit
        self.onPasteAndGo = onPasteAndGo
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onSubmit: onSubmit, onPasteAndGo: onPasteAndGo)
    }

    func makeUIView(context: Context) -> UITextField {
        let field = UITextField()
        field.text = text
        field.font = .preferredFont(forTextStyle: .body)
        field.adjustsFontForContentSizeCategory = true
        field.autocapitalizationType = .none
        field.autocorrectionType = .no
        field.spellCheckingType = .no
        field.clearButtonMode = .whileEditing
        switch style {
        case .url:
            field.placeholder = String(localized: "Enter URL")
            field.keyboardType = .URL
            field.textContentType = .URL
            field.returnKeyType = .go
        case .search:
            field.placeholder = String(localized: "Search Symbols")
            field.keyboardType = .asciiCapable  // symbol names
            field.returnKeyType = .search
        }
        field.delegate = context.coordinator
        field.addTarget(context.coordinator, action: #selector(Coordinator.textChanged(_:)), for: .editingChanged)
        // Fill the width it's given instead of sizing to its text.
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        // Once it's in a window: bring up the keyboard and select the whole text, like Safari, so
        // typing replaces it.
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
        var onPasteAndGo: (@MainActor (String) -> Void)?

        init(text: Binding<String>, onSubmit: @escaping @MainActor () -> Void,
             onPasteAndGo: (@MainActor (String) -> Void)?) {
            self.text = text
            self.onSubmit = onSubmit
            self.onPasteAndGo = onPasteAndGo
        }

        /// Adds Paste and Go right after Paste, like Safari's address field.
        func textField(_ textField: UITextField, editMenuForCharactersIn range: NSRange,
                       suggestedActions: [UIMenuElement]) -> UIMenu? {
            guard onPasteAndGo != nil, Clipboard.hasAddress else { return nil }  // nil: the standard menu
            let pasteAndGo = UIAction(title: String(localized: "Paste and Go")) { [weak self] _ in
                guard let address = Clipboard.address() else { return }
                self?.onPasteAndGo?(address)
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

/// Searching symbols: the bar becomes a search field above the keyboard, and the list filters as
/// you type. The keyboard's Search key or a swipe down closes it and keeps the filter (so does
/// scrolling the cards, in Symbols); the field's clear button clears it.
struct SymbolSearchEditor: View {
    @Binding var query: String
    let onClose: @MainActor () -> Void

    init(query: Binding<String>, onClose: @escaping @MainActor () -> Void) {
        _query = query
        self.onClose = onClose
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            BarTextField(style: .search, text: $query, onSubmit: onClose)
        }
        .padding(.horizontal, 14)
        .frame(height: FileBarMetrics.fieldHeight)
        .modifier(FieldBackground())
        .padding(.horizontal, FileBarMetrics.fieldHorizontalMargin)
        .padding(.vertical, 8)
        .modifier(EditorBarBackground())
        // Swiping down on the search bar closes the search (the filter stays).
        .modifier(OnSwipeDown { onClose() })
        .accessibilityAction(.escape) { onClose() }
    }
}

/// A downward swipe on the bar: hides the keyboard, then runs `action` (if any). The address
/// editor only hides the keyboard (the field stays open); the symbol search closes.
/// The lists above the bars hide the keyboard as soon as they scroll.
private struct OnSwipeDown: ViewModifier {
    var action: (@MainActor () -> Void)?

    init(_ action: (@MainActor () -> Void)? = nil) {
        self.action = action
    }

    func body(content: Content) -> some View {
        content.simultaneousGesture(
            DragGesture(minimumDistance: 12).onEnded { drag in
                let down = drag.translation.height
                guard down > 20, down > abs(drag.translation.width) else { return }
                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                                to: nil, from: nil, for: nil)
                action?()
            }
        )
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
