class val Diagnostic
  """
  Something wrong with the source, and where, in lines and characters.
  """
  let span: Span
  let message: String val

  new val create(span': Span, message': String val) =>
    span = span'
    message = message'

  fun string(): String iso^ =>
    (recover String end)
      .> append(span.string())
      .> append(": ")
      .> append(message)
