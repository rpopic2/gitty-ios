import Foundation

/// A top-level definition in a source file: what Symbols mode shows as one card.
nonisolated struct CodeSymbol: Identifiable, Hashable, Sendable {
    enum Kind: String, Sendable, CaseIterable {
        case function, type, macro, global
        /// Members of types (C# and similar).
        case method, property, field, enumMember
        /// A whole file: its entry in the list comes before its symbols.
        case file
        /// Some lines of a file, kept in an album (see `AlbumContents`).
        case lines

        var title: String {
            switch self {
            case .function: "Function"
            case .type: "Type"
            case .macro: "Macro"
            case .global: "Global"
            case .method: "Method"
            case .property: "Property"
            case .field: "Field"
            case .enumMember: "Enum Case"
            case .file: "File"
            case .lines: "Lines"
            }
        }

        var systemImage: String {
            switch self {
            case .function: "function"
            case .type: "cube"
            case .macro: "number"
            case .global: "globe"
            case .method: "m.square"
            case .property: "p.square"
            case .field: "f.square"
            case .enumMember: "e.square"
            case .file: "doc.text"
            case .lines: "text.alignleft"
            }
        }
    }

    /// In the Code level's list: from its file and its place in the file (`stableID`), so the
    /// list getting more of the project's files doesn't change it. Other lists (an album, an
    /// occurrences page) number theirs. Not kept across launches.
    let id: Int
    let name: String
    let kind: Kind
    /// UTF-16 range in the document, including the comment directly above the definition.
    let range: NSRange
    /// 1-based line where the definition itself starts (after any leading comment).
    let line: Int
    /// The first few lines of the definition, for the card.
    let preview: String
    /// The file it's in, when that isn't the open file (Symbols shows the whole project).
    var fileURL: URL? = nil
    /// Lines' last line (`lines` only).
    var endLine: Int? = nil
    /// A file's entry for a file of the project that isn't downloaded (from its file list): just
    /// a title, which downloads it.
    var isDownloaded = true
    /// A file's entry whose symbols aren't known yet (being read in the background, or when it
    /// shows): just its title for now.
    var isIndexed = true

    /// "Line 12", "Lines 12–30", or "File" for a file's own entry.
    var lineLabel: String {
        switch kind {
        case .file: String(localized: "File")
        case .lines: Self.linesLabel(line, endLine ?? line)
        default: String(localized: "Line \(line)")
        }
    }

    /// For VoiceOver: "Function draw, line 12", or "File main.c".
    var spokenDescription: String {
        switch kind {
        case .file: "\(kind.title) \(name)"
        case .lines: "\(lineLabel): \(name)"
        default: "\(kind.title) \(name), line \(line)"
        }
    }

    static func linesLabel(_ start: Int, _ end: Int) -> String {
        start == end ? String(localized: "Line \(start)") : String(localized: "Lines \(start)–\(end)")
    }

    /// A symbol's id in the Code level's list: its file's address and its place in the file
    /// (0 for the file's entry, then its symbols in order), hashed. Not negative (the list's
    /// folder headers are). The same in every version of the list while the file doesn't change.
    static func stableID(fileHash: UInt64, index: Int) -> Int {
        var value = fileHash ^ (UInt64(truncatingIfNeeded: index) &* 0x9E37_79B9_7F4A_7C15)
        // splitmix64's finish: every bit of both counts.
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        value ^= value >> 31
        return Int(truncatingIfNeeded: value >> 1)
    }

    /// The file part of `stableID`: FNV-1a of its address (the same on every launch, unlike
    /// `Hasher`).
    static func fileHash(_ address: String) -> UInt64 {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in address.utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01B3
        }
        return hash
    }

    /// The same symbol at another place in a combined list, from `file`.
    func moved(to id: Int, file: URL?) -> CodeSymbol {
        CodeSymbol(id: id, name: name, kind: kind, range: range, line: line, preview: preview, fileURL: file,
                   endLine: endLine, isDownloaded: isDownloaded, isIndexed: isIndexed)
    }
}
