import SwiftUI

extension EnvironmentValues {
    /// The code font and size, set at the root from what's saved, so code views redraw when
    /// it changes (even inside views that skip other redraws).
    @Entry var codeTextStyle = CodeTextStyle.current
}

extension CodeTextStyle {
    /// For SwiftUI text: the same font, at a fixed size (code doesn't follow Dynamic Type).
    var swiftUIFont: Font {
        .custom(font.postScriptName, fixedSize: size)
    }

    /// The cards' smaller preview text.
    var previewFont: Font {
        .custom(font.postScriptName, fixedSize: max(9, size - 2))
    }
}
