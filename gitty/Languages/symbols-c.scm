; Top-level definitions in C, for Symbols mode.
;
; Uses the tags.scm conventions: the definition is captured as @definition.<kind> and its name
; as @name. @name.prefix is shown before the name (`struct point`). The indexer keeps only
; top-level matches, so these patterns may also match inside functions.

; Functions: definitions only. Prototypes are `declaration`s and never match here.
(function_definition
  declarator: [
    (function_declarator declarator: (identifier) @name)
    (pointer_declarator declarator: (function_declarator declarator: (identifier) @name))
    (pointer_declarator declarator: (pointer_declarator declarator: (function_declarator declarator: (identifier) @name)))
  ]) @definition.function

; Types. Inside a typedef, declarators are named like ordinary ones but end in a type_identifier.
(type_definition
  declarator: [
    (type_identifier) @name
    (primitive_type) @name
    (pointer_declarator declarator: (type_identifier) @name)
    (function_declarator declarator: (parenthesized_declarator (pointer_declarator declarator: (type_identifier) @name)))
  ]) @definition.type

(struct_specifier "struct" @name.prefix name: (type_identifier) @name body: (_)) @definition.type
(union_specifier "union" @name.prefix name: (type_identifier) @name body: (_)) @definition.type
(enum_specifier "enum" @name.prefix name: (type_identifier) @name body: (_)) @definition.type

; Macros
(preproc_def name: (identifier) @name) @definition.macro
(preproc_function_def name: (identifier) @name) @definition.macro

; Globals: not prototypes, and not `struct point { … } origin;` (that shows as the struct).
(declaration
  type: [
    (primitive_type)
    (type_identifier)
    (sized_type_specifier)
    (macro_type_specifier)
    (struct_specifier !body)
    (union_specifier !body)
    (enum_specifier !body)
  ]
  declarator: [
    (identifier) @name
    (pointer_declarator declarator: (identifier) @name)
    (array_declarator declarator: (identifier) @name)
    (pointer_declarator declarator: (array_declarator declarator: (identifier) @name))
    (pointer_declarator declarator: (pointer_declarator declarator: (identifier) @name))
    (function_declarator declarator: (parenthesized_declarator (pointer_declarator declarator: (identifier) @name)))
    (init_declarator declarator: [
      (identifier) @name
      (pointer_declarator declarator: (identifier) @name)
      (array_declarator declarator: (identifier) @name)
      (pointer_declarator declarator: (array_declarator declarator: (identifier) @name))
      (pointer_declarator declarator: (pointer_declarator declarator: (identifier) @name))
      (function_declarator declarator: (parenthesized_declarator (pointer_declarator declarator: (identifier) @name)))
    ])
  ]) @definition.variable
