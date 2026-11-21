import SwiftUI

extension EnvironmentValues {
    /// The code font and size, set at the root from what's saved, so code views redraw when
    /// it changes (even inside views that skip other redraws).
    @Entry var codeTextStyle = CodeTextStyle.current
    /// A word the Code level's blocks mark wherever it is, as a whole word with its exact case
    /// (an occurrences page's). Without one, they mark the highlighted identifier.
    @Entry var codeMark: String? = nil
}

extension CodeTextStyle {
    /// For SwiftUI text: the same font as pages (no ligatures, see `uiFont`), at a fixed size
    /// (code doesn't follow Dynamic Type).
    /// Made once per font and size (`FontCache` keeps the font), and the same `Font` each time,
    /// so a redrawn title's text compares equal and isn't laid out again.
    @MainActor
    var swiftUIFont: Font {
        Self.font(uiFont)
    }

    /// The cards' smaller preview text.
    @MainActor
    var previewFont: Font {
        Self.font(uiFont(size: max(9, size - 2)))
    }

    @MainActor private static var fonts: [ObjectIdentifier: Font] = [:]

    @MainActor private static func font(_ uiFont: UIFont) -> Font {
        let id = ObjectIdentifier(uiFont)
        if let known = fonts[id] { return known }
        let font = Font(uiFont)
        fonts[id] = font
        return font
    }
}
