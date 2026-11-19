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

    /// Position in the list: file order, the open file first, then the project's other files.
    /// Stable for one version of the list.
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

    /// The same symbol at another place in a combined list, from `file`.
    func moved(to id: Int, file: URL?) -> CodeSymbol {
        CodeSymbol(id: id, name: name, kind: kind, range: range, line: line, preview: preview, fileURL: file,
                   endLine: endLine, isDownloaded: isDownloaded)
    }
}
