import Foundation
import SwiftTreeSitter
import TreeSitterC
import TreeSitterCSharp
import TreeSitterProto
import TreeSitterSwift

/// What Symbols mode and syntax highlighting need to know about one language. Adding a language
/// means adding its tree-sitter grammar package, a `symbols-<name>.scm` query and its
/// `highlights-<name>.scm` in `gitty/Languages/`, and an entry in `all`.
nonisolated struct SymbolLanguage: Sendable {
    let name: String
    let fileExtensions: Set<String>
    let language: Language
    /// Definitions found inside these nodes aren't top-level (function bodies, struct fields,
    /// parameters), so they're dropped.
    let bodyNodeTypes: Set<String>
    /// Definitions that keep their members as symbols too (C# classes). Members are named
    /// `Container.Member`. Any other definition swallows what's inside it.
    let containerNodeTypes: Set<String>
    /// Runs on the text before parsing. The result must have the same UTF-16 length.
    let prepare: @Sendable (NSString) -> String
    /// The compiled symbols query (`symbols-<name>.scm`, tags.scm conventions).
    let query: Query
    /// The grammar's own highlights query (`highlights-<name>.scm`), for syntax highlighting.
    let highlightsQuery: Query

    init(
        name: String,
        fileExtensions: Set<String>,
        language: Language,
        queryResource: String,
        highlightsResource: String,
        bodyNodeTypes: Set<String>,
        containerNodeTypes: Set<String> = [],
        prepare: @escaping @Sendable (NSString) -> String = { $0 as String }
    ) {
        self.name = name
        self.fileExtensions = fileExtensions
        self.language = language
        self.bodyNodeTypes = bodyNodeTypes
        self.containerNodeTypes = containerNodeTypes
        self.prepare = prepare
        query = Self.load(queryResource, for: language)
        highlightsQuery = Self.load(highlightsResource, for: language)
    }

    /// A missing or broken query file is a bug in the app, not something to recover from.
    private static func load(_ resource: String, for language: Language) -> Query {
        guard let url = Bundle.main.url(forResource: resource, withExtension: "scm") else {
            fatalError("\(resource).scm is missing from the app bundle")
        }
        do {
            return try Query(language: language, url: url)
        } catch {
            fatalError("\(resource).scm doesn't compile: \(error)")
        }
    }

    static let c = SymbolLanguage(
        name: "C",
        fileExtensions: ["c", "h"],
        language: Language(tree_sitter_c()),
        queryResource: "symbols-c",
        highlightsResource: "highlights-c",
        bodyNodeTypes: ["compound_statement", "field_declaration_list", "parameter_list"],
        prepare: CMacroBlanking.blankingTopLevelMacroCalls(in:)
    )

    static let cSharp = SymbolLanguage(
        name: "C#",
        fileExtensions: ["cs", "csx"],
        language: Language(tree_sitter_c_sharp()),
        queryResource: "symbols-c-sharp",
        highlightsResource: "highlights-c-sharp",
        bodyNodeTypes: ["block", "arrow_expression_clause", "accessor_list",
                        "parameter_list", "bracketed_parameter_list"],
        containerNodeTypes: ["class_declaration", "struct_declaration", "interface_declaration",
                             "record_declaration", "enum_declaration"]
    )

    static let swift = SymbolLanguage(
        name: "Swift",
        fileExtensions: ["swift"],
        language: Language(tree_sitter_swift()),
        queryResource: "symbols-swift",
        highlightsResource: "highlights-swift",
        bodyNodeTypes: ["function_body", "computed_property", "lambda_literal", "willset_didset_block"],
        // `extension` is a class_declaration in this grammar.
        containerNodeTypes: ["class_declaration", "protocol_declaration"]
    )

    static let proto = SymbolLanguage(
        name: "Protocol Buffers",
        fileExtensions: ["proto"],
        language: Language(tree_sitter_proto()),
        queryResource: "symbols-proto",
        highlightsResource: "highlights-proto",
        // Nothing inside these defines anything (an rpc's options, a field's).
        bodyNodeTypes: ["field_options", "enum_value_option"],
        // Their members get cards too: `Person.name`, `People.Get`, `Status.STATUS_OK`. A oneof
        // isn't one: its fields are the message's.
        containerNodeTypes: ["message", "group", "enum", "service", "extend"]
    )

    static let all: [SymbolLanguage] = [.c, .cSharp, .swift, .proto]

    /// Every file extension that has symbols (for the project tree's code icon).
    static let symbolFileExtensions: Set<String> = Set(all.flatMap(\.fileExtensions))

    static func extensionHasSymbols(_ fileExtension: String) -> Bool {
        symbolFileExtensions.contains(fileExtension.lowercased())
    }

    static func forExtension(_ fileExtension: String) -> SymbolLanguage? {
        let ext = fileExtension.lowercased()
        return all.first { $0.fileExtensions.contains(ext) }
    }
}
