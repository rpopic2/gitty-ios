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
    /// In place of the style's placeholder.
    var placeholder: String? = nil
    /// Opening, the whole text is selected, so typing replaces it (Safari's address). `false`:
    /// the caret goes at its end (a search that's being typed, handed over from another field).
    var selectsAll = true

    // An explicit init (not the memberwise one) so passing in an existing `@MainActor` closure
    // doesn't warn about converting it to `@Sendable`.
    init(style: Style, text: Binding<String>, onSubmit: @escaping @MainActor () -> Void,
         onPasteAndGo: (@MainActor (String) -> Void)? = nil, placeholder: String? = nil, selectsAll: Bool = true) {
        self.style = style
        _text = text
        self.onSubmit = onSubmit
        self.onPasteAndGo = onPasteAndGo
        self.placeholder = placeholder
        self.selectsAll = selectsAll
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
        if let placeholder { field.placeholder = placeholder }
        field.delegate = context.coordinator
        field.addTarget(context.coordinator, action: #selector(Coordinator.textChanged(_:)), for: .editingChanged)
        // Fill the width it's given instead of sizing to its text.
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        // Once it's in a window: bring up the keyboard and select the whole text, like Safari, so
        // typing replaces it.
        let selectsAll = selectsAll
        Task { @MainActor in
            field.becomeFirstResponder()
            if selectsAll { field.selectAll(nil) }
        }
        return field
    }

    func updateUIView(_ field: UITextField, context: Context) {
        context.coordinator.text = $text
        context.coordinator.onSubmit = onSubmit
        context.coordinator.onPasteAndGo = onPasteAndGo
        if field.text != text { field.text = text }
        if let placeholder, field.placeholder != placeholder { field.placeholder = placeholder }
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
/// a swipe on the cards, in Symbols); the field's clear button clears it.
struct SymbolSearchEditor: View {
    @Binding var query: String
    /// Results are still coming in: a small spinner at the end of the field.
    let isSearching: Bool
    /// What it searches: "Search Symbols", or "Search Files" at the Files level.
    let placeholder: String
    let onClose: @MainActor () -> Void
    /// Return on the keyboard (`nil`: it closes, like a swipe down).
    let onSubmit: (@MainActor () -> Void)?
    /// A Cancel button beside the field, like Safari's (`nil`: none).
    let onCancel: (@MainActor () -> Void)?
    /// Opening, its text is selected (`false`: the caret at its end, for a search being typed).
    let selectsAll: Bool

    init(query: Binding<String>, isSearching: Bool = false, placeholder: String = String(localized: "Search Symbols"),
         onClose: @escaping @MainActor () -> Void, onSubmit: (@MainActor () -> Void)? = nil,
         onCancel: (@MainActor () -> Void)? = nil, selectsAll: Bool = true) {
        _query = query
        self.isSearching = isSearching
        self.placeholder = placeholder
        self.onClose = onClose
        self.onSubmit = onSubmit
        self.onCancel = onCancel
        self.selectsAll = selectsAll
    }

    var body: some View {
        HStack(spacing: 12) {
            field
            if let onCancel {
                Button("Cancel") { onCancel() }
            }
        }
        .padding(.horizontal, FileBarMetrics.fieldHorizontalMargin)
        .padding(.vertical, 8)
        .modifier(EditorBarBackground())
        // Swiping down on the search bar closes the search (the filter stays).
        .modifier(OnSwipeDown { onClose() })
        .accessibilityAction(.escape) { onClose() }
    }

    private var field: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            BarTextField(style: .search, text: $query, onSubmit: onSubmit ?? onClose, placeholder: placeholder,
                         selectsAll: selectsAll)
            if isSearching {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Searching")
            }
        }
        .padding(.horizontal, 14)
        .frame(height: FileBarMetrics.fieldHeight)
        .modifier(FieldBackground())
    }
}

/// Keeps the keyboard up while a search field gives way to another on a new page (the bar's to
/// the results page's): the old one leaves the window before the new one is focused, which
/// dropped the keyboard and brought it back up. A hidden field with the same keyboard holds it
/// in between; the new field takes it over.
@MainActor
enum KeyboardHandOff {
    private static let holder: UITextField = {
        let field = UITextField(frame: .zero)
        field.alpha = 0
        field.isAccessibilityElement = false
        field.keyboardType = .asciiCapable  // as `BarTextField`'s search
        field.returnKeyType = .search
        field.autocapitalizationType = .none
        field.autocorrectionType = .no
        field.spellCheckingType = .no
        return field
    }()

    /// Before the old field goes: the holder takes the keyboard (only if a field has it).
    static func hold() {
        guard let window = UIApplication.shared.connectedScenes
            .compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first
        else { return }
        if holder.superview !== window { window.addSubview(holder) }
        holder.becomeFirstResponder()
        // No field took it over: the keyboard goes, rather than staying up with nothing to type in.
        Task {
            try? await Task.sleep(for: .seconds(1))
            if holder.isFirstResponder { holder.resignFirstResponder() }
        }
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
struct FieldBackground: ViewModifier {
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
struct EditorBarBackground: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
        } else {
            content.background(.bar, ignoresSafeAreaEdges: .bottom)
        }
    }
}
