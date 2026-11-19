import SwiftUI
import UIKit

/// Syntax highlighting colors, chosen in the sidebar (Code Font ▸ Colors). `none` is plain raw
/// text, as Safari shows it. Each theme has light and dark colors; backgrounds stay the app's.
nonisolated enum SyntaxTheme: String, CaseIterable, Sendable {
    case none, github, xcode, subtle, solarized

    static let `default` = SyntaxTheme.github

    var title: String {
        switch self {
        case .none: String(localized: "None")
        case .github: "GitHub"
        case .xcode: "Xcode"
        case .subtle: String(localized: "Subtle")
        case .solarized: "Solarized"
        }
    }

    /// The color for a category; `nil` leaves it the text color.
    func color(for category: SyntaxCategory) -> UIColor? {
        Self.colors[self]?[category]
    }

    /// Each theme's colors, made once (each adapts to light and dark mode).
    nonisolated(unsafe) private static let colors: [SyntaxTheme: [SyntaxCategory: UIColor]] = Dictionary(
        uniqueKeysWithValues: allCases.map { theme in
            (theme, theme.palette.mapValues { pair in
                let (light, dark) = pair
                return UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light) }
            })
        }
    )

    /// Light and dark, as 0xRRGGBB.
    private var palette: [SyntaxCategory: (UInt32, UInt32)] {
        switch self {
        case .none:
            return [:]
        case .github:  // github.com's code colors (Primer)
            return [.keyword: (0xCF222E, 0xFF7B72), .preprocessor: (0xCF222E, 0xFF7B72),
                    .string: (0x0A3069, 0xA5D6FF), .comment: (0x6E7781, 0x8B949E),
                    .number: (0x0550AE, 0x79C0FF), .constant: (0x0550AE, 0x79C0FF),
                    .property: (0x0550AE, 0x79C0FF), .attribute: (0x0550AE, 0x79C0FF),
                    .type: (0x953800, 0xFFA657), .function: (0x8250DF, 0xD2A8FF)]
        case .xcode:  // Xcode's Default (Light) and Default (Dark)
            return [.keyword: (0x9B2393, 0xFC5FA3), .string: (0xC41A16, 0xFC6A5D),
                    .comment: (0x5D6C79, 0x6C7986), .number: (0x1C00CF, 0xD0BF69),
                    .preprocessor: (0x643820, 0xFD8F3F), .attribute: (0x815F03, 0xBF8555),
                    .type: (0x3900A0, 0xD0A8FF), .function: (0x326D74, 0x67B7A4),
                    .property: (0x326D74, 0x67B7A4), .constant: (0x326D74, 0x67B7A4)]
        case .subtle:  // mostly plain: comments recede, literals and keywords tinted
            return [.comment: (0x8A8A8E, 0x8D8D93), .string: (0x7A5C2E, 0xC9A86A),
                    .number: (0x7A5C2E, 0xC9A86A), .keyword: (0x4B4B9A, 0xA9A9E8),
                    .preprocessor: (0x4B4B9A, 0xA9A9E8)]
        case .solarized:  // Ethan Schoonover's accents; comments in base1 / base01
            return [.keyword: (0x859900, 0x859900), .string: (0x2AA198, 0x2AA198),
                    .comment: (0x93A1A1, 0x586E75), .number: (0xD33682, 0xD33682),
                    .constant: (0x6C71C4, 0x6C71C4), .type: (0xB58900, 0xB58900),
                    .function: (0x268BD2, 0x268BD2), .property: (0x268BD2, 0x268BD2),
                    .preprocessor: (0xCB4B16, 0xCB4B16), .attribute: (0xCB4B16, 0xCB4B16)]
        }
    }

    /// Colors `text` (already styled with the font) where the grammar finds code. Unchanged
    /// for `none` and file types without a grammar. Off the main thread for anything big.
    func color(_ text: NSMutableAttributedString, fileExtension: String) {
        guard self != .none,
              let runs = SyntaxHighlighter.runs(in: text.string, fileExtension: fileExtension)
        else { return }
        for run in runs {
            guard let category = run.category, let color = color(for: category) else { continue }
            text.addAttribute(.foregroundColor, value: color, range: run.range)
        }
    }

    /// `text` for SwiftUI as pieces of `CodePieces.linesPerPiece` lines (the newline between
    /// two pieces left out), colored like `attributed`. The text is parsed once, whole.
    func pieces(_ text: String, fileExtension: String) -> [AttributedString] {
        let utf16 = text as NSString
        let ranges = CodePieces.ranges(in: utf16)
        let runs = self == .none ? nil : SyntaxHighlighter.runs(in: text, fileExtension: fileExtension)
        guard let runs, runs.contains(where: { $0.category != nil }) else {
            return ranges.map { AttributedString(utf16.substring(with: $0)) }
        }
        var next = 0
        return ranges.map { range in
            var piece = AttributedString()
            // Runs are in order: start from the first that reaches this piece.
            while next < runs.count, NSMaxRange(runs[next].range) <= range.location { next += 1 }
            var index = next
            while index < runs.count, runs[index].range.location < NSMaxRange(range) {
                let run = runs[index]
                let part = NSIntersectionRange(run.range, range)
                if part.length > 0 {
                    var text = AttributedString(utf16.substring(with: part))
                    if let category = run.category, let color = color(for: category) {
                        text.swiftUI.foregroundColor = Color(uiColor: color)
                    }
                    piece.append(text)
                }
                index += 1
            }
            return piece
        }
    }

    /// `text` for SwiftUI `Text`, colored (plain for `none` and file types without a grammar).
    func attributed(_ text: String, fileExtension: String) -> AttributedString {
        var result = AttributedString(text)
        guard self != .none, let runs = SyntaxHighlighter.runs(in: text, fileExtension: fileExtension),
              runs.contains(where: { $0.category != nil })
        else { return result }
        result = AttributedString()
        let utf16 = text as NSString
        for run in runs {
            var piece = AttributedString(utf16.substring(with: run.range))
            if let category = run.category, let color = color(for: category) {
                piece.swiftUI.foregroundColor = Color(uiColor: color)
            }
            result.append(piece)
        }
        return result
    }
}

private extension UIColor {
    nonisolated convenience init(hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

/// Small colored snippets for SwiftUI (card previews, the Files level's lines, the sidebar's
/// preview), made on the main thread as they're drawn and kept, so scrolling back costs nothing.
@MainActor
final class SyntaxColoring {
    static let shared = SyntaxColoring()

    private let cache = NSCache<NSString, Box>()

    private final class Box {
        let value: AttributedString
        init(_ value: AttributedString) { self.value = value }
    }

    init() {
        cache.countLimit = 2_000
    }

    func attributed(_ text: String, fileExtension: String, theme: SyntaxTheme) -> AttributedString {
        guard theme != .none, SymbolLanguage.forExtension(fileExtension) != nil else { return AttributedString(text) }
        let key = "\(theme.rawValue)|\(fileExtension.lowercased())|\(text)" as NSString
        if let cached = cache.object(forKey: key) { return cached.value }
        let value = theme.attributed(text, fileExtension: fileExtension)
        cache.setObject(Box(value), forKey: key)
        return value
    }
}
