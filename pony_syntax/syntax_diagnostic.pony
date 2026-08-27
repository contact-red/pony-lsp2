class val SyntaxDiagnostic
  """
  Something wrong with the source, and where.

  The offset is a byte offset into the source, because that is what the tree
  works in. Converting to a line and a column is the caller's job, and the
  only place that needs to know how positions are encoded on the wire.
  """
  let offset: USize
  let width: USize
  let message: String val

  new val create(offset': USize, width': USize, message': String val) =>
    offset = offset'
    width = width'
    message = message'

  fun string(): String iso^ =>
    (recover String end)
      .> append(offset.string())
      .> append("+")
      .> append(width.string())
      .> append(": ")
      .> append(message)
