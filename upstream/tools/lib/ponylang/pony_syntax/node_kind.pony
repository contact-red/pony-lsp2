// Node kinds: the interior elements of a syntax tree.
//
// Deliberately not generated from ponyc's `abstract` table. ponyc reuses one
// id for both the `class` keyword and the class definition node; this tree
// keeps them apart, so an element's kind says on its own whether it is a
// leaf. The set is a property of the grammar written here and grows as rules
// are ported.
//
// ponyc's REORDER and INFIX_BUILD have no counterpart. They shape an AST for
// later passes; this tree is source-ordered, so an operator stays between its
// operands and a consumer interprets it. What ponyc expresses by rebuilding,
// a rule here expresses by wrapping -- see `Parser.wrap_from`.

primitive NdError
  """
  Input that no rule could interpret. Its children are the tokens skipped to
  reach a point where parsing could continue, so an error costs the text it
  covers and nothing else.
  """
  fun name(): String val => "NdError"

primitive NdModule
  """
  A whole source file.
  """
  fun name(): String val => "NdModule"

primitive NdUse
  """
  A `use` command.
  """
  fun name(): String val => "NdUse"

primitive NdUseName
  """
  The `name =` that may precede a `use` specifier.
  """
  fun name(): String val => "NdUseName"

primitive NdUseFFI
  """
  An FFI declaration: `@name[R](params)`.
  """
  fun name(): String val => "NdUseFFI"

primitive NdClassDef
  """
  A type, interface, trait, primitive, struct, class or actor.
  """
  fun name(): String val => "NdClassDef"

primitive NdAnnotations
  """
  A `\\annotation\\` list.
  """
  fun name(): String val => "NdAnnotations"

primitive NdProvides
  """
  The `is` clause of an entity.
  """
  fun name(): String val => "NdProvides"

primitive NdMembers
  """
  The fields and methods of an entity.
  """
  fun name(): String val => "NdMembers"

primitive NdField
  """
  A `var`, `let` or `embed` field.
  """
  fun name(): String val => "NdField"

primitive NdMethod
  """
  A `fun`, `be` or `new`.
  """
  fun name(): String val => "NdMethod"

primitive NdParams
  """
  A parenthesised parameter list.
  """
  fun name(): String val => "NdParams"

primitive NdParam
  """
  One parameter.
  """
  fun name(): String val => "NdParam"

primitive NdTypeParams
  """
  A `[...]` type parameter list on a declaration.
  """
  fun name(): String val => "NdTypeParams"

primitive NdTypeParam
  """
  One type parameter.
  """
  fun name(): String val => "NdTypeParam"

primitive NdTypeArgs
  """
  A `[...]` type argument list at a use site.
  """
  fun name(): String val => "NdTypeArgs"

primitive NdTypeList
  """
  The parameter types of a lambda type.
  """
  fun name(): String val => "NdTypeList"

primitive NdNominal
  """
  A named type, with its package, arguments and capability.
  """
  fun name(): String val => "NdNominal"

primitive NdThisType
  """
  The type `this`.
  """
  fun name(): String val => "NdThisType"

primitive NdGroupedType
  """
  A parenthesised type.
  """
  fun name(): String val => "NdGroupedType"

primitive NdTupleType
  """
  Comma-separated types inside a parenthesised type.
  """
  fun name(): String val => "NdTupleType"

primitive NdLambdaType
  """
  A `{...}` lambda type.
  """
  fun name(): String val => "NdLambdaType"

primitive NdBareLambdaType
  """
  An `@{...}` bare lambda type.
  """
  fun name(): String val => "NdBareLambdaType"

primitive NdInfixType
  """
  Types joined by `|` or `&`.

  Flat and source-ordered: the operands and the operators are siblings.
  ponyc builds a left-leaning tree here instead, which is a shape for its
  later passes rather than a fact about the source.
  """
  fun name(): String val => "NdInfixType"

primitive NdViewpoint
  """
  A `->` viewpoint type.
  """
  fun name(): String val => "NdViewpoint"

primitive NdValueFormalArg
  """
  A literal or constant expression used as a type argument.
  """
  fun name(): String val => "NdValueFormalArg"

primitive NdConstExpr
  """
  A `#`-prefixed constant expression.
  """
  fun name(): String val => "NdConstExpr"

primitive NdDefaultArg
  """
  The `= value` of a parameter.
  """
  fun name(): String val => "NdDefaultArg"

primitive NdBlock
  """
  A balanced region inside a body: a region Pony closes with `end`, or a
  bracketed group.

  The body skeleton emits these as it goes, so a body has real nesting
  before the expression rules exist to give it meaning. Folding and
  expanding a selection both need the structure rather than the meaning,
  which is why they work now.
  """
  fun name(): String val => "NdBlock"

primitive NdGroup
  """
  A bracketed group inside a body: `(...)`, `[...]`, `{...}`.

  Kept apart from `NdBlock` because the two are folded differently -- a
  region a reader thinks of as a block is worth collapsing, and the
  arguments of a call spread over three lines are not.
  """
  fun name(): String val => "NdGroup"

primitive NdBody
  """
  An expression or a method body, taken as a balanced region rather than
  parsed.

  A placeholder for the expression rules. Its extent is right, which is what
  folding, selection and an outline need; what is inside it is a flat run of
  tokens and nested blocks. The rules that replace it change nothing above
  this point.
  """
  fun name(): String val => "NdBody"

type NodeKind is
  ( NdError
  | NdModule
  | NdUse
  | NdUseName
  | NdUseFFI
  | NdClassDef
  | NdAnnotations
  | NdProvides
  | NdMembers
  | NdField
  | NdMethod
  | NdParams
  | NdParam
  | NdTypeParams
  | NdTypeParam
  | NdTypeArgs
  | NdTypeList
  | NdNominal
  | NdThisType
  | NdGroupedType
  | NdTupleType
  | NdLambdaType
  | NdBareLambdaType
  | NdInfixType
  | NdViewpoint
  | NdValueFormalArg
  | NdConstExpr
  | NdDefaultArg
  | NdBody
  | NdBlock
  | NdGroup
  )
  """
  Every kind of interior node. Grows as grammar rules are ported.
  """

type SyntaxKind is (TokenKind | NodeKind)
  """
  What an element of the tree is. A leaf carries a `TokenKind` and an
  interior element a `NodeKind`, so the two never need telling apart by
  anything but the kind itself.
  """
