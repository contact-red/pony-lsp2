class val Identifier
  """
  An identifier written in a document, and where.
  """
  let name: String val
  let qualifier: String val
    """
    The package alias written before it, as in `col.List`, or empty.

    Part of the identifier rather than of what reads it, because only the
    document knows whether the dot before a name is a qualifier or a field
    access on an expression.
    """
  let span: Span
  let offset: USize
    """
    Where it starts, in bytes. What a scope test needs, and what neither
    line nor character can be turned into without the document.
    """

  new val create(
    name': String val,
    span': Span,
    offset': USize,
    qualifier': String val = "")
  =>
    name = name'
    span = span'
    offset = offset'
    qualifier = qualifier'

  fun written(): String val =>
    """
    The name as it appears in the source, qualifier and all.
    """
    if qualifier.size() > 0 then
      qualifier + "." + name
    else
      name
    end
