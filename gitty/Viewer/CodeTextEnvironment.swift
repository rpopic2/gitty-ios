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
    var swiftUIFont: Font {
        Font(uiFont)
    }

    /// The cards' smaller preview text.
    var previewFont: Font {
        Font(uiFont(size: max(9, size - 2)))
    }
}
