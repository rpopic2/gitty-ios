import Foundation

/// Whether a download is a web page, so the viewer can offer to open it in the browser.
nonisolated enum WebPageDetector {
    static func isWebPage(contentType: String?, data: Data) -> Bool {
        if let contentType {
            // Trust the server. raw.githubusercontent serves .html *source* as text/plain, and a
            // browser would show that as text too, so it doesn't count.
            let mime = contentType.split(separator: ";").first?
                .trimmingCharacters(in: .whitespaces).lowercased() ?? ""
            return mime == "text/html" || mime == "application/xhtml+xml"
        }
        // No type: look at how it starts.
        let head = RawTextDecoder.decode(data.prefix(512), contentType: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return head.hasPrefix("<!doctype html") || head.hasPrefix("<html")
    }
}
