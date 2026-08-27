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

primitive NdSeq
  """
  A sequence of expressions: a body, a branch, an argument.
  """
  fun name(): String val => "NdSeq"

primitive NdJump
  """
  A `return`, `break`, `continue`, `error` or compile intrinsic.
  """
  fun name(): String val => "NdJump"

primitive NdAssign
  """
  An assignment.
  """
  fun name(): String val => "NdAssign"

primitive NdBinOp
  """
  Two operands and an infix operator between them.
  """
  fun name(): String val => "NdBinOp"

primitive NdUnaryOp
  """
  A prefix operator and its operand.
  """
  fun name(): String val => "NdUnaryOp"

primitive NdAsOp
  """
  An `as` and the type it names.
  """
  fun name(): String val => "NdAsOp"

primitive NdDot
  """
  A `.` and the member it names.
  """
  fun name(): String val => "NdDot"

primitive NdTilde
  """
  A `~` partial application and the method it names.
  """
  fun name(): String val => "NdTilde"

primitive NdChain
  """
  A `.>` chained call and the method it names.
  """
  fun name(): String val => "NdChain"

primitive NdQualify
  """
  Type arguments applied to a reference.
  """
  fun name(): String val => "NdQualify"

primitive NdCall
  """
  A call's argument list, applied to what precedes it.
  """
  fun name(): String val => "NdCall"

primitive NdArgs
  """
  The positional arguments of a call.
  """
  fun name(): String val => "NdArgs"

primitive NdNamedArgs
  """
  The `where` arguments of a call.
  """
  fun name(): String val => "NdNamedArgs"

primitive NdNamedArg
  """
  One `name = value` argument.
  """
  fun name(): String val => "NdNamedArg"

primitive NdRef
  """
  A reference to a name.
  """
  fun name(): String val => "NdRef"

primitive NdThis
  """
  The `this` reference.
  """
  fun name(): String val => "NdThis"

primitive NdLocation
  """
  The `__loc` literal.
  """
  fun name(): String val => "NdLocation"

primitive NdGrouped
  """
  A parenthesised expression.
  """
  fun name(): String val => "NdGrouped"

primitive NdTuple
  """
  Comma-separated expressions inside parentheses.
  """
  fun name(): String val => "NdTuple"

primitive NdArray
  """
  An array literal.
  """
  fun name(): String val => "NdArray"

primitive NdArrayType
  """
  The `as T:` element type of an array literal.
  """
  fun name(): String val => "NdArrayType"

primitive NdFFICall
  """
  An `@name(...)` call into C.
  """
  fun name(): String val => "NdFFICall"

primitive NdLocal
  """
  A `var`, `let` or `embed` declaration, or a match capture.
  """
  fun name(): String val => "NdLocal"

primitive NdIdSeq
  """
  The names a `for` or `with` binds.
  """
  fun name(): String val => "NdIdSeq"

primitive NdIf
  """
  An `if` or an `elseif`, with its condition and branches.
  """
  fun name(): String val => "NdIf"

primitive NdIfDef
  """
  An `ifdef`, with its condition and branches.
  """
  fun name(): String val => "NdIfDef"

primitive NdIfTypeSet
  """
  An `iftype` and the clauses it chooses between.
  """
  fun name(): String val => "NdIfTypeSet"

primitive NdIfType
  """
  One `T <: U then ...` clause of an `iftype`.
  """
  fun name(): String val => "NdIfType"

primitive NdElse
  """
  An `else` branch.
  """
  fun name(): String val => "NdElse"

primitive NdThen
  """
  The `then` branch of a `try`.
  """
  fun name(): String val => "NdThen"

primitive NdMatch
  """
  A `match`, its subject and its cases.
  """
  fun name(): String val => "NdMatch"

primitive NdCases
  """
  The cases of a `match`.
  """
  fun name(): String val => "NdCases"

primitive NdCase
  """
  One `| pattern => body` case.
  """
  fun name(): String val => "NdCase"

primitive NdGuard
  """
  The `if` guard of a match case.
  """
  fun name(): String val => "NdGuard"

primitive NdWhile
  """
  A `while` loop.
  """
  fun name(): String val => "NdWhile"

primitive NdRepeat
  """
  A `repeat` loop.
  """
  fun name(): String val => "NdRepeat"

primitive NdFor
  """
  A `for` loop.
  """
  fun name(): String val => "NdFor"

primitive NdWith
  """
  A `with` block.
  """
  fun name(): String val => "NdWith"

primitive NdWithElem
  """
  One `name = expression` of a `with`.
  """
  fun name(): String val => "NdWithElem"

primitive NdTry
  """
  A `try` block.
  """
  fun name(): String val => "NdTry"

primitive NdRecover
  """
  A `recover` block.
  """
  fun name(): String val => "NdRecover"

primitive NdConsume
  """
  A `consume` expression.
  """
  fun name(): String val => "NdConsume"

primitive NdObject
  """
  An object literal.
  """
  fun name(): String val => "NdObject"

primitive NdLambda
  """
  A lambda literal.
  """
  fun name(): String val => "NdLambda"

primitive NdBareLambda
  """
  A bare lambda literal.
  """
  fun name(): String val => "NdBareLambda"

primitive NdLambdaParams
  """
  The parameters of a lambda.
  """
  fun name(): String val => "NdLambdaParams"

primitive NdLambdaParam
  """
  One parameter of a lambda.
  """
  fun name(): String val => "NdLambdaParam"

primitive NdLambdaCaptures
  """
  The captures of a lambda.
  """
  fun name(): String val => "NdLambdaCaptures"

primitive NdLambdaCapture
  """
  One capture of a lambda.
  """
  fun name(): String val => "NdLambdaCapture"

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
  | NdSeq
  | NdJump
  | NdAssign
  | NdBinOp
  | NdUnaryOp
  | NdAsOp
  | NdDot
  | NdTilde
  | NdChain
  | NdQualify
  | NdCall
  | NdArgs
  | NdNamedArgs
  | NdNamedArg
  | NdRef
  | NdThis
  | NdLocation
  | NdGrouped
  | NdTuple
  | NdArray
  | NdArrayType
  | NdFFICall
  | NdLocal
  | NdIdSeq
  | NdIf
  | NdIfDef
  | NdIfTypeSet
  | NdIfType
  | NdElse
  | NdThen
  | NdMatch
  | NdCases
  | NdCase
  | NdGuard
  | NdWhile
  | NdRepeat
  | NdFor
  | NdWith
  | NdWithElem
  | NdTry
  | NdRecover
  | NdConsume
  | NdObject
  | NdLambda
  | NdBareLambda
  | NdLambdaParams
  | NdLambdaParam
  | NdLambdaCaptures
  | NdLambdaCapture
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
