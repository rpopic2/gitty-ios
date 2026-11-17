; Types and their members in C#, for Symbols mode.
;
; Uses the tags.scm conventions: the definition is captured as @definition.<kind> and its name
; as @name. @name.prefix is shown before the name (`~Circle`, `operator +`). Types are
; containers (see SymbolLanguage.cSharp), so their members get cards too, named `Type.Member`.
; Namespaces aren't captured: they only group.

; Types
(class_declaration name: (identifier) @name) @definition.type
(struct_declaration name: (identifier) @name) @definition.type
(interface_declaration name: (identifier) @name) @definition.type
(record_declaration name: (identifier) @name) @definition.type
(enum_declaration name: (identifier) @name) @definition.type
(delegate_declaration name: (identifier) @name) @definition.type

; Methods, constructors, destructors and operators
(method_declaration name: (identifier) @name) @definition.method
(constructor_declaration name: (identifier) @name) @definition.method
(destructor_declaration "~" @name.prefix name: (identifier) @name) @definition.method
(operator_declaration "operator" @name.prefix operator: _ @name) @definition.method
(conversion_operator_declaration "operator" @name.prefix type: (_) @name) @definition.method

; Properties and indexers
(property_declaration name: (identifier) @name) @definition.property
(indexer_declaration "this" @name) @definition.property

; Explicit interface implementations keep the interface in the name: `ICollection<T>.IsReadOnly`.
; (These match the same nodes as the patterns above and only add the prefix.)
(method_declaration (explicit_interface_specifier) @name.prefix name: (identifier) @name) @definition.method
(property_declaration (explicit_interface_specifier) @name.prefix name: (identifier) @name) @definition.property
(indexer_declaration (explicit_interface_specifier) @name.prefix "this" @name) @definition.property

; Fields, constants and event fields
(field_declaration (variable_declaration (variable_declarator name: (identifier) @name))) @definition.field
(event_field_declaration (variable_declaration (variable_declarator name: (identifier) @name))) @definition.field

; Enum members
(enum_member_declaration name: (identifier) @name) @definition.enum_member
