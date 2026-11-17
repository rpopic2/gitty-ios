import UIKit

/// Reading an address from the clipboard, for Paste and Go.
@MainActor
enum Clipboard {
    /// Whether there's something to paste. Checking doesn't show the paste permission prompt.
    static var hasAddress: Bool {
        UIPasteboard.general.hasURLs || UIPasteboard.general.hasStrings
    }

    /// The copied URL, or copied text. iOS may ask once whether gitty may paste.
    static func address() -> String? {
        UIPasteboard.general.url?.absoluteString ?? UIPasteboard.general.string
    }
}
