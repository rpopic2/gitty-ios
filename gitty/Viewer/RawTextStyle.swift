import CoreText
import Foundation
import UIKit

/// Styled text ready to hand to the text view. `NSAttributedString` is immutable, so this
/// can safely cross from the background thread that builds it to the main thread.
nonisolated struct RenderedText: @unchecked Sendable {
    let attributedString: NSAttributedString
}

/// Safari's raw `text/plain` style, taken from WebKit's source:
/// - `SettingsBaseCocoa.mm`: monospace font is Courier. `DefaultFixedFontSize` is 13.
/// - `TextDocumentParser.cpp`: `<pre style="word-wrap: break-word; white-space: pre-wrap">`,
///   plus `color-scheme: light dark`.
/// - Default CSS: body margin 8, `<pre>` margin 1em (13) top/bottom. The vertical margins
///   collapse into each other, giving 13 top/bottom and 8 left/right. `tab-size` is 8.
///
/// Adjust these after comparing screenshots with Safari on a device. The font and its size are
/// the reader's choice (`CodeTextStyle`, in the sidebar); Safari's Courier 13 by default.
nonisolated enum RawTextStyle {
    static var fontName: String { CodeTextStyle.current.font.postScriptName }
    static var fontSize: CGFloat { CodeTextStyle.current.size }
    static let tabWidthInSpaces: CGFloat = 8
    static let insets = UIEdgeInsets(top: 13, left: 8, bottom: 13, right: 8)

    static var font: UIFont {
        CodeTextStyle.current.uiFont
    }

    /// WebKit's `CanvasText` / `Canvas` in light and dark mode.
    static var textColor: UIColor { .label }
    static var backgroundColor: UIColor { .systemBackground }

    static func paragraphStyle(for font: UIFont) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        // Wraps at word boundaries and breaks a word that is longer than the line, like `break-word`.
        style.lineBreakMode = .byWordWrapping
        // No UIKit-specific line-breaking rules (push-out, Hangul word priority), to match WebKit.
        style.lineBreakStrategy = []
        style.hyphenationFactor = 0
        style.tabStops = []
        let spaceWidth = (" " as NSString).size(withAttributes: [.font: font]).width
        style.defaultTabInterval = spaceWidth * tabWidthInSpaces
        return style
    }

    /// Sets up a read-only `UITextView` for raw text: TextKit 1 with contiguous layout, so every
    /// line's height is exact and nothing is re-estimated while scrolling.
    /// Create the view with `usingTextLayoutManager: false`.
    @MainActor
    static func configure(_ textView: UITextView) {
        textView.isEditable = false
        textView.isSelectable = true
        textView.dataDetectorTypes = []
        textView.adjustsFontForContentSizeCategory = false
        textView.backgroundColor = backgroundColor
        textView.textContainerInset = insets
        textView.textContainer.lineFragmentPadding = 0
        textView.layoutManager.allowsNonContiguousLayout = false
        textView.alwaysBounceVertical = true
        textView.showsHorizontalScrollIndicator = false
        textView.contentInsetAdjustmentBehavior = .automatic
        // Read-only code: no Apple Intelligence rewriting, and no Writing Tools item in the menu.
        textView.writingToolsBehavior = .none
        if #available(iOS 26.0, *) {
            // Soft blur under the status bar, like Safari 26.
            textView.topEdgeEffect.style = .soft
        }
    }

    /// The menu shown for selected text: only Copy, Select All, Share and Search Web.
    /// Call it from `textView(_:editMenuForTextIn:suggestedActions:)`.
    @MainActor
    static func editMenu(from suggested: [UIMenuElement], adding extra: [UIMenuElement] = []) -> UIMenu {
        UIMenu(children: extra + keptMenuElements(suggested))
    }

    /// "Comment" for any selection: adds a comment on it to the review.
    @MainActor
    static func commentItems(for range: NSRange, onComment: (@MainActor (NSRange) -> Void)?) -> [UIMenuElement] {
        guard let onComment, range.length > 0 else { return [] }
        let action = UIAction(title: String(localized: "Comment"),
                              image: UIImage(systemName: "text.bubble")) { _ in onComment(range) }
        return [action]
    }

    /// "Search" for any selection: searches symbols for it. Empty only when there's nothing to
    /// search with (`searchTerm` decides: no symbols for this file, or only spaces selected).
    @MainActor
    static func searchItems(
        for range: NSRange, in textView: UITextView,
        searchTerm: (@MainActor (String) -> String?)?, onSearch: (@MainActor (String) -> Void)?
    ) -> [UIMenuElement] {
        guard let searchTerm, let onSearch, range.length > 0,
              NSMaxRange(range) <= textView.textStorage.length
        else { return [] }
        // A long selection searches with its start; a query is never that long.
        let head = NSRange(location: range.location, length: min(range.length, 500))
        guard let term = searchTerm(textView.textStorage.attributedSubstring(from: head).string)
        else { return [] }
        let action = UIAction(title: String(localized: "Search"),
                              image: UIImage(systemName: "magnifyingglass")) { _ in onSearch(term) }
        return [action]
    }

    @MainActor
    private static func keptMenuElements(_ elements: [UIMenuElement]) -> [UIMenuElement] {
        let keptActions: Set<Selector> = [
            #selector(UIResponderStandardEditActions.copy(_:)),
            #selector(UIResponderStandardEditActions.selectAll(_:)),
            NSSelectorFromString("_share:"),  // Share is a private command on some iOS versions
        ]
        return elements.compactMap { element -> UIMenuElement? in
            if let menu = element as? UIMenu {
                if menu.identifier == .share { return menu }
                let children = keptMenuElements(menu.children)
                return children.isEmpty ? nil : menu.replacingChildren(children)
            }
            if let command = element as? UICommand, keptActions.contains(command.action) {
                return command
            }
            return isSearchWeb(element) ? element : nil
        }
    }

    /// Search Web is a private item, so it's matched by name: a command like `_searchWeb:`, or an
    /// action whose identifier contains "searchWeb", depending on the iOS version.
    @MainActor
    private static func isSearchWeb(_ element: UIMenuElement) -> Bool {
        let name: String
        if let command = element as? UICommand {
            name = NSStringFromSelector(command.action)
        } else if let action = element as? UIAction {
            name = action.identifier.rawValue
        } else {
            return false
        }
        return name.range(of: "searchweb", options: .caseInsensitive) != nil
    }

    /// Decodes and styles a document. Safe to call off the main thread.
    static func render(_ document: StoredDocument) -> RenderedText {
        let string = RawTextDecoder.decode(document.data, contentType: document.metadata.contentType)
        let font = self.font
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: textColor,
            .paragraphStyle: paragraphStyle(for: font),
        ]
        return RenderedText(attributedString: NSAttributedString(string: string, attributes: attributes))
    }
}

/// The font for code, chosen in the sidebar: Safari's Courier, or JetBrains Mono (bundled).
nonisolated enum CodeFont: String, CaseIterable, Sendable {
    case courier
    case jetBrainsMono

    var title: String {
        switch self {
        case .courier: "Courier"
        case .jetBrainsMono: "JetBrains Mono"
        }
    }

    var postScriptName: String {
        switch self {
        case .courier: "Courier"
        case .jetBrainsMono: "JetBrainsMono-Regular"
        }
    }
}

/// The code font and its size, as chosen in the sidebar (saved in `UserDefaults`).
nonisolated struct CodeTextStyle: Equatable, Hashable, Sendable {
    var font: CodeFont
    var size: CGFloat

    static let fontKey = "codeFont"
    static let sizeKey = "codeFontSize"
    static let defaultSize: CGFloat = 13
    static let sizes: ClosedRange<Double> = 9...24

    /// What's saved now (Courier 13 until something is chosen).
    static var current: CodeTextStyle {
        let defaults = UserDefaults.standard
        let font = defaults.string(forKey: fontKey).flatMap(CodeFont.init(rawValue:)) ?? .courier
        let size = defaults.object(forKey: sizeKey) as? Double ?? Double(defaultSize)
        return CodeTextStyle(font: font, size: CGFloat(min(max(size, sizes.lowerBound), sizes.upperBound)))
    }

    var uiFont: UIFont {
        UIFont(name: font.postScriptName, size: size) ?? .monospacedSystemFont(ofSize: size, weight: .regular)
    }

    /// Registers the bundled fonts (JetBrains Mono) for this app. Call once at launch.
    static func registerBundledFonts() {
        let urls = (Bundle.main.urls(forResourcesWithExtension: "ttf", subdirectory: nil) ?? [])
            + (Bundle.main.urls(forResourcesWithExtension: "ttf", subdirectory: "Fonts") ?? [])
        for url in urls {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }
}
