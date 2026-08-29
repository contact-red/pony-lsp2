primitive BindLocal
  """
  A `var`, `let` or `embed` in a body, a `for` or `with` name, or a name
  bound by a `match` pattern.
  """
  fun name(): String val => "local"

primitive BindParam
  """
  A parameter of a method or of a lambda, or a lambda capture.
  """
  fun name(): String val => "param"

primitive BindField
  """
  A field of the entity that encloses the use.
  """
  fun name(): String val => "field"

primitive BindTypeParam
  """
  A type parameter of an entity or of a method.
  """
  fun name(): String val => "type param"

type BindingKind is (BindLocal | BindParam | BindField | BindTypeParam)
  """
  What kind of thing a name is bound to. Named for what Pony calls them.
  """

class val Binding
  """
  A name bound inside one document, and where it can be seen.

  `scope` is what a use of the name has to fall within for this to be what
  it refers to. It runs from where the name becomes visible -- which is not
  always where it is written -- to the end of whatever encloses it.
  """
  let name: String val
  let kind: BindingKind
  let name_span: Span
  let scope: Span
  let _from: USize
  let _to: USize
  let _name_from: USize
  let _name_to: USize

  new val create(
    name': String val,
    kind': BindingKind,
    name_span': Span,
    scope': Span,
    from': USize,
    to': USize,
    name_from': USize,
    name_to': USize)
  =>
    name = name'
    kind = kind'
    name_span = name_span'
    scope = scope'
    _from = from'
    _to = to'
    _name_from = name_from'
    _name_to = name_to'

  fun covers(byte: USize): Bool =>
    """
    Whether a use at this byte offset could refer to this binding.

    Where it is written counts as well as where it is visible. A parameter
    is not in scope until the body, so its own name lies outside its scope,
    and without this a cursor on the declaration would find nothing to go
    to.
    """
    ((byte >= _from) and (byte < _to))
      or ((byte >= _name_from) and (byte < _name_to))

  fun extent(): USize =>
    """
    How much source the binding is visible over.

    What picks the innermost of several bindings of the same name: the one
    that shadows is the one visible over less.
    """
    _to - _from
