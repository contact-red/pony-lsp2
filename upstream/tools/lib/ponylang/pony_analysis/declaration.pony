primitive DeclTypeAlias
  """
  A `type` alias.
  """
  fun name(): String val => "type"

primitive DeclInterface
  """
  An `interface`.
  """
  fun name(): String val => "interface"

primitive DeclTrait
  """
  A `trait`.
  """
  fun name(): String val => "trait"

primitive DeclPrimitive
  """
  A `primitive`.
  """
  fun name(): String val => "primitive"

primitive DeclStruct
  """
  A `struct`.
  """
  fun name(): String val => "struct"

primitive DeclClass
  """
  A `class`.
  """
  fun name(): String val => "class"

primitive DeclActor
  """
  An `actor`.
  """
  fun name(): String val => "actor"

primitive DeclField
  """
  A `var`, `let` or `embed` field.
  """
  fun name(): String val => "field"

primitive DeclFunction
  """
  A `fun`.
  """
  fun name(): String val => "fun"

primitive DeclBehaviour
  """
  A `be`.
  """
  fun name(): String val => "be"

primitive DeclConstructor
  """
  A `new`.
  """
  fun name(): String val => "new"

type DeclarationKind is
  ( DeclTypeAlias
  | DeclInterface
  | DeclTrait
  | DeclPrimitive
  | DeclStruct
  | DeclClass
  | DeclActor
  | DeclField
  | DeclFunction
  | DeclBehaviour
  | DeclConstructor
  )
  """
  What a declaration declares. Named for the Pony keyword rather than for a
  protocol's symbol categories, which are the server's to choose.
  """

class val Declaration
  """
  One declaration: what it is, what it is called, and where.

  `span` covers the whole declaration and `name_span` only its identifier.
  Both are needed and they are not interchangeable: an outline highlights
  the name, a fold hides the body, and going to a declaration puts the
  cursor on the name.
  """
  let kind: DeclarationKind
  let name: String val
  let span: Span
  let name_span: Span
  let container: (USize | None)
    """
    The index in the same document's declaration list of what encloses
    this, or `None` for a top-level declaration. An index rather than a
    reference so the list stays a flat immutable value.
    """

  new val create(
    kind': DeclarationKind,
    name': String val,
    span': Span,
    name_span': Span,
    container': (USize | None))
  =>
    kind = kind'
    name = name'
    span = span'
    name_span = name_span'
    container = container'
