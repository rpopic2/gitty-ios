; Types and their members in Swift, for Symbols mode.
;
; Uses the tags.scm conventions: the definition is captured as @definition.<kind> and its name
; as @name. @name.prefix is shown before the name (`extension Circle`). Types, extensions and
; protocols are containers (see SymbolLanguage.swift), so their members get cards too, named
; `Type.member`. Members of an extension use the extended type's name: `Circle.hash`.

; Types: class, struct, enum, actor, protocol
(class_declaration declaration_kind: ["class" "struct" "enum" "actor"] name: (_) @name) @definition.type
(protocol_declaration name: (_) @name) @definition.type
(class_declaration declaration_kind: "extension" @name.prefix name: (_) @name) @definition.type

; Typealiases and associated types. (This grammar also labels the aliased type `name`, so anchor to
; the node right after the keyword.)
(typealias_declaration "typealias" . name: (_) @name) @definition.type
(associatedtype_declaration name: (_) @name) @definition.type

; Functions at the top level; methods, initializers, subscripts and operators in types. (This
; grammar also labels the return type `name`, so anchor to the node right after `func`.)
(source_file (function_declaration "func" . name: _ @name) @definition.function)
(class_body (function_declaration "func" . name: _ @name) @definition.method)
(enum_class_body (function_declaration "func" . name: _ @name) @definition.method)
(protocol_function_declaration "func" . name: _ @name) @definition.method
(init_declaration "init" @name) @definition.method
(deinit_declaration "deinit" @name) @definition.method
(subscript_declaration "subscript" @name) @definition.method

; Properties in types (stored, computed, protocol requirements), globals at the top level
(class_body (property_declaration name: (pattern (simple_identifier) @name)) @definition.property)
(enum_class_body (property_declaration name: (pattern (simple_identifier) @name)) @definition.property)
(protocol_property_declaration name: (pattern (simple_identifier) @name)) @definition.property
(source_file (property_declaration name: (pattern (simple_identifier) @name)) @definition.variable)

; Enum cases (`case a, b` is one card)
(enum_entry name: (simple_identifier) @name) @definition.enum_member
