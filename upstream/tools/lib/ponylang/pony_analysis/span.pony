class val Span
  """
  A range of source, in zero-based lines and characters.

  Half-open: `start` is the first position in the range and `finish` is one
  past the last, which is what a client expects and what makes an empty
  range representable.

  Characters are counted in whatever encoding the `LineIndex` that produced
  this was given. Nothing downstream re-counts them, so nothing downstream
  has to know.
  """
  let start_line: USize
  let start_character: USize
  let finish_line: USize
  let finish_character: USize

  new val create(
    start_line': USize,
    start_character': USize,
    finish_line': USize,
    finish_character': USize)
  =>
    start_line = start_line'
    start_character = start_character'
    finish_line = finish_line'
    finish_character = finish_character'

  new val from_bytes(index: LineIndexView, from: USize, to: USize) =>
    (start_line, start_character) = index.position(from)
    (finish_line, finish_character) = index.position(to)

  fun is_empty(): Bool =>
    (start_line == finish_line) and (start_character == finish_character)

  fun line_count(): USize =>
    (finish_line - start_line) + 1

  fun string(): String iso^ =>
    (recover String end)
      .> append(start_line.string())
      .> append(":")
      .> append(start_character.string())
      .> append("-")
      .> append(finish_line.string())
      .> append(":")
      .> append(finish_character.string())
