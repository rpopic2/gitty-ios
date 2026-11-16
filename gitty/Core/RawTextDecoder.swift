import Foundation

/// Turns downloaded bytes into a string the way Safari would for a `text/plain` page
/// (WHATWG Encoding Standard), so text never shows up garbled.
///
/// Order: byte-order mark → `charset` from Content-Type → strict UTF-8 → windows-1252.
/// The text itself is never changed: line endings, tabs and control characters stay as they are.
nonisolated enum RawTextDecoder {
    static func decode(_ data: Data, contentType: String?) -> String {
        // 1. A byte-order mark wins over everything, as in the Encoding Standard.
        if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            return String(decoding: data.dropFirst(3), as: UTF8.self)
        }
        if data.starts(with: [0xFF, 0xFE]) {
            return decodeUTF16(data.dropFirst(2), bigEndian: false)
        }
        if data.starts(with: [0xFE, 0xFF]) {
            return decodeUTF16(data.dropFirst(2), bigEndian: true)
        }

        // 2. What the server declared.
        if let label = charset(from: contentType) {
            switch label {
            case "utf-8", "utf8", "unicode-1-1-utf-8", "unicode11utf8", "unicode20utf8", "x-unicode20utf8":
                // Invalid bytes become U+FFFD, like a browser.
                return String(decoding: data, as: UTF8.self)
            case "utf-16le", "utf-16", "ucs-2", "unicode", "csunicode", "iso-10646-ucs-2", "unicodefeff":
                return decodeUTF16(data[...], bigEndian: false)
            case "utf-16be", "unicodefffe":
                return decodeUTF16(data[...], bigEndian: true)
            case _ where windows1252Labels.contains(label):
                return decodeWindows1252(data)
            default:
                if let encoding = foundationEncoding(forLabel: label),
                   let string = String(data: data, encoding: encoding) {
                    return string
                }
            }
        }

        // 3. Undeclared: almost all code on the web is UTF-8.
        if let string = String(data: data, encoding: .utf8) {
            return string
        }

        // 4. WebKit's default encoding for Western locales. Never fails.
        return decodeWindows1252(data)
    }

    // MARK: - Content-Type

    static func charset(from contentType: String?) -> String? {
        guard let contentType else { return nil }
        for parameter in contentType.split(separator: ";").dropFirst() {
            let parts = parameter.split(separator: "=", maxSplits: 1)
            guard parts.count == 2,
                  parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "charset"
            else { continue }
            let value = parts[1]
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                .lowercased()
            return value.isEmpty ? nil : value
        }
        return nil
    }

    private static func foundationEncoding(forLabel label: String) -> String.Encoding? {
        let cfEncoding = CFStringConvertIANACharSetNameToEncoding(label as CFString)
        guard cfEncoding != kCFStringEncodingInvalidId else { return nil }
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cfEncoding))
    }

    // MARK: - Decoders

    private static func decodeUTF16(_ bytes: Data.SubSequence, bigEndian: Bool) -> String {
        var units: [UInt16] = []
        units.reserveCapacity(bytes.count / 2)
        var index = bytes.startIndex
        while index + 1 < bytes.endIndex {
            let first = UInt16(bytes[index])
            let second = UInt16(bytes[index + 1])
            units.append(bigEndian ? (first << 8 | second) : (second << 8 | first))
            index += 2
        }
        var string = String(decoding: units, as: UTF16.self)
        if index < bytes.endIndex { string.append("\u{FFFD}") }  // odd trailing byte
        return string
    }

    /// The Encoding Standard treats Latin-1 and ASCII labels as windows-1252.
    private static let windows1252Labels: Set<String> = [
        "windows-1252", "cp1252", "x-cp1252", "cp819", "ibm819", "l1", "latin1",
        "iso-8859-1", "iso8859-1", "iso88591", "iso_8859-1", "iso_8859-1:1987",
        "iso-ir-100", "csisolatin1", "us-ascii", "ascii", "ansi_x3.4-1968",
    ]

    /// 0x80–0x9F in windows-1252. Bytes undefined there map to the same code point, as browsers do.
    private static let windows1252High: [UInt16] = [
        0x20AC, 0x0081, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021,
        0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0x008D, 0x017D, 0x008F,
        0x0090, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014,
        0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0x009D, 0x017E, 0x0178,
    ]

    private static func decodeWindows1252(_ data: Data) -> String {
        var scalars = String.UnicodeScalarView()
        scalars.reserveCapacity(data.count)
        for byte in data {
            if (0x80...0x9F).contains(byte), let scalar = Unicode.Scalar(windows1252High[Int(byte - 0x80)]) {
                scalars.append(scalar)
            } else {
                scalars.append(Unicode.Scalar(byte))
            }
        }
        return String(scalars)
    }
}
