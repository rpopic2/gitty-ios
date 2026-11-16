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
