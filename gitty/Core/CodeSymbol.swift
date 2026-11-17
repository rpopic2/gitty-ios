import Foundation

/// A top-level definition in a source file: what Symbols mode shows as one card.
nonisolated struct CodeSymbol: Identifiable, Hashable, Sendable {
    enum Kind: String, Sendable, CaseIterable {
        case function, type, macro, global
        /// Members of types (C# and similar).
        case method, property, field, enumMember

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
            }
        }
    }

    /// Position in file order. Stable for one version of the document.
    let id: Int
    let name: String
    let kind: Kind
    /// UTF-16 range in the document, including the comment directly above the definition.
    let range: NSRange
    /// 1-based line where the definition itself starts (after any leading comment).
    let line: Int
    /// The first few lines of the definition, for the card.
    let preview: String
}
