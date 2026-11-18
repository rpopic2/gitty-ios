import Foundation

/// Tabs as spaces up to the next tab stop, so text drawn without tab stops (SwiftUI `Text`)
/// lines up like the file does with Safari's 8-column tabs.
nonisolated enum TabExpansion {
    static func expand(_ text: String, tabWidth: Int = 8) -> String {
        guard text.utf8.contains(UInt8(ascii: "\t")) else { return text }
        // Unicode scalars, not Characters: much faster, and columns only matter for ASCII code.
        var result = String.UnicodeScalarView()
        result.reserveCapacity(text.utf8.count + 64)
        var column = 0
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\t":
                let spaces = tabWidth - column % tabWidth
                for _ in 0..<spaces { result.append(" ") }
                column += spaces
            case "\n", "\r":
                result.append(scalar)
                column = 0
            default:
                result.append(scalar)
                column += 1
            }
        }
        return String(result)
    }
}
