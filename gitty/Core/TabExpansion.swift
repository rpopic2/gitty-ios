import Foundation

/// Tabs as spaces up to the next tab stop, so text drawn without tab stops (SwiftUI `Text`)
/// lines up like the file does with Safari's 8-column tabs.
nonisolated enum TabExpansion {
    static func expand(_ text: String, tabWidth: Int = 8) -> String {
        guard text.contains("\t") else { return text }
        var result = ""
        result.reserveCapacity(text.utf8.count)
        var column = 0
        for character in text {
            switch character {
            case "\t":
                let spaces = tabWidth - column % tabWidth
                result.append(String(repeating: " ", count: spaces))
                column += spaces
            case "\n", "\r\n", "\r":
                result.append(character)
                column = 0
            default:
                result.append(character)
                column += 1
            }
        }
        return result
    }
}
