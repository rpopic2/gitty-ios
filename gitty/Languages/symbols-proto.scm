; Messages, enums, services and their members in Protocol Buffers, for Symbols mode.
;
; Uses the tags.scm conventions: the definition is captured as @definition.<kind> and its name
; as @name. @name.prefix is shown before the name (`extend google.protobuf.FieldOptions`).
; Messages, groups, enums, services and `extend` blocks are containers (see
; SymbolLanguage.proto), so their members get cards too, named `Message.field`. A oneof only
; groups its fields: they're the message's. Packages, imports and options aren't captured.

; Types
(message (message_name (identifier) @name)) @definition.type
(group (message_name (identifier) @name)) @definition.type
(enum (enum_name (identifier) @name)) @definition.enum
(service (service_name (identifier) @name)) @definition.interface
(extend "extend" @name.prefix (full_ident) @name) @definition.type

; RPCs
(rpc (rpc_name (identifier) @name)) @definition.method

; Fields
(field (identifier) @name) @definition.field
(map_field (identifier) @name) @definition.field
(oneof_field (identifier) @name) @definition.field

; Enum values
(enum_field (identifier) @name) @definition.enum_member
