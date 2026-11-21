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
    /// `extra` goes first, `trailing` after the system's items (on the menu's next page).
    static func editMenu(from suggested: [UIMenuElement], adding extra: [UIMenuElement] = [],
                         trailing: [UIMenuElement] = []) -> UIMenu {
        UIMenu(children: extra + keptMenuElements(suggested) + trailing)
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

    /// "Occurrences" for a one-line selection: where it's used, as a whole word, in the
    /// project's files (`Occurrences`).
    @MainActor
    static func occurrencesItems(for range: NSRange, in textView: UITextView,
                                 onFind: (@MainActor (String, NSRange) -> Void)?) -> [UIMenuElement] {
        guard let onFind, range.length > 0, range.length <= 500, NSMaxRange(range) <= textView.textStorage.length,
              let term = Occurrences.term(fromSelection: textView.textStorage.mutableString.substring(with: range))
        else { return [] }
        let action = UIAction(title: String(localized: "Occurrences"),
                              image: UIImage(systemName: "text.magnifyingglass")) { _ in onFind(term, range) }
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

    /// Decodes and styles a document, with the chosen syntax colors. Safe to call off the main
    /// thread.
    static func render(_ document: StoredDocument) -> RenderedText {
        let string = RawTextDecoder.decode(document.data, contentType: document.metadata.contentType)
        let style = CodeTextStyle.current
        let font = style.uiFont
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: textColor,
            .paragraphStyle: paragraphStyle(for: font),
        ]
        let text = NSMutableAttributedString(string: string, attributes: attributes)
        style.theme.color(text, fileExtension: document.url.pathExtension)
        return RenderedText(attributedString: text)
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

/// The code font, its size and the syntax colors, as chosen in the sidebar (saved in
/// `UserDefaults`).
nonisolated struct CodeTextStyle: Equatable, Hashable, Sendable {
    var font: CodeFont
    var size: CGFloat
    var theme: SyntaxTheme = .default

    static let fontKey = "codeFont"
    static let sizeKey = "codeFontSize"
    static let themeKey = "syntaxTheme"
    static let defaultSize: CGFloat = 13
    static let sizes: ClosedRange<Double> = 9...24

    /// What's saved now (Courier 13 and GitHub colors until something is chosen).
    static var current: CodeTextStyle {
        let defaults = UserDefaults.standard
        let font = defaults.string(forKey: fontKey).flatMap(CodeFont.init(rawValue:)) ?? .courier
        let size = defaults.object(forKey: sizeKey) as? Double ?? Double(defaultSize)
        let theme = defaults.string(forKey: themeKey).flatMap(SyntaxTheme.init(rawValue:)) ?? .default
        return CodeTextStyle(font: font, size: CGFloat(min(max(size, sizes.lowerBound), sizes.upperBound)),
                             theme: theme)
    }

    var uiFont: UIFont {
        uiFont(size: size)
    }

    /// `uiFont`'s line height.
    var lineHeight: CGFloat {
        uiFont.lineHeight
    }

    /// The font at `size`, without ligatures or contextual alternates. JetBrains Mono's
    /// (`->` as an arrow and the like) are hundreds of OpenType substitutions that Core Text
    /// runs on every glyph each time text is laid out and again when it's drawn: in hang reports
    /// from scrolling the Code level, that shaping was almost all of the main thread's time.
    /// Code reads the same without them, every character as typed.
    func uiFont(size: CGFloat) -> UIFont {
        let key = FontCache.Key(font: font, size: size)
        if let known = FontCache.shared.font(for: key) { return known }
        let made = makeFont(size: size)
        FontCache.shared.keep(made, for: key)
        return made
    }

    private func makeFont(size: CGFloat) -> UIFont {
        guard let base = UIFont(name: font.postScriptName, size: size) else {
            return .monospacedSystemFont(ofSize: size, weight: .regular)
        }
        let plain = base.fontDescriptor.addingAttributes([
            .featureSettings: [
                [UIFontDescriptor.FeatureKey.type: kLigaturesType,
                 UIFontDescriptor.FeatureKey.selector: kCommonLigaturesOffSelector],
                [UIFontDescriptor.FeatureKey.type: kContextualAlternatesType,
                 UIFontDescriptor.FeatureKey.selector: kContextualAlternatesOffSelector],
            ],
        ])
        return UIFont(descriptor: plain, size: size)
    }

    /// Registers the bundled fonts (JetBrains Mono) for this app, at launch. Does nothing if
    /// they're already there (SwiftUI may make the app more than once; registering again only
    /// logs "already exists").
    static func registerBundledFonts() {
        guard UIFont(name: CodeFont.jetBrainsMono.postScriptName, size: 12) == nil else { return }
        let urls = (Bundle.main.urls(forResourcesWithExtension: "ttf", subdirectory: nil) ?? [])
            + (Bundle.main.urls(forResourcesWithExtension: "ttf", subdirectory: "Fonts") ?? [])
        for url in urls {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }
}

/// The code fonts made so far, by font and size: making one (finding the font, then turning its
/// features off) each time a title or block was drawn showed as hitches while scrolling. Used from
/// any thread (blocks are laid out in the background).
nonisolated final class FontCache: @unchecked Sendable {
    static let shared = FontCache()

    struct Key: Hashable {
        let font: CodeFont
        let size: CGFloat
    }

    private let lock = NSLock()
    private var fonts: [Key: UIFont] = [:]

    func font(for key: Key) -> UIFont? {
        lock.withLock { fonts[key] }
    }

    func keep(_ font: UIFont, for key: Key) {
        lock.withLock { fonts[key] = font }
    }
}
