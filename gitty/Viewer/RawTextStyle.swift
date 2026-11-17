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
/// Adjust these after comparing screenshots with Safari on a device.
nonisolated enum RawTextStyle {
    static let fontName = "Courier"
    static let fontSize: CGFloat = 13
    static let tabWidthInSpaces: CGFloat = 8
    static let insets = UIEdgeInsets(top: 13, left: 8, bottom: 13, right: 8)

    static var font: UIFont {
        UIFont(name: fontName, size: fontSize) ?? .monospacedSystemFont(ofSize: fontSize, weight: .regular)
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

    /// The menu shown for selected text: only Copy, Select All and Share.
    /// Call it from `textView(_:editMenuForTextIn:suggestedActions:)`.
    @MainActor
    static func editMenu(from suggested: [UIMenuElement]) -> UIMenu {
        UIMenu(children: keptMenuElements(suggested))
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
            return nil
        }
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
