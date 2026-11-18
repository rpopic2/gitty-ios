import Foundation

/// A top-level definition in a source file: what Symbols mode shows as one card.
nonisolated struct CodeSymbol: Identifiable, Hashable, Sendable {
    enum Kind: String, Sendable, CaseIterable {
        case function, type, macro, global
        /// Members of types (C# and similar).
        case method, property, field, enumMember
        /// A whole file: its entry in the list comes before its symbols.
        case file

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

    /// "Line 12", or "File" for a file's own entry.
    var lineLabel: String {
        kind == .file ? String(localized: "File") : String(localized: "Line \(line)")
    }

    /// For VoiceOver: "Function draw, line 12", or "File main.c".
    var spokenDescription: String {
        kind == .file ? "\(kind.title) \(name)" : "\(kind.title) \(name), line \(line)"
    }

    /// The same symbol at another place in a combined list, from `file`.
    func moved(to id: Int, file: URL?) -> CodeSymbol {
        CodeSymbol(id: id, name: name, kind: kind, range: range, line: line, preview: preview, fileURL: file)
    }
}
