use "../../upstream/tools/lib/ponylang/pony_syntax"

primitive RenderDiag
  """
  One diagnostic in ponyc's shape: the location line with 1-based line and
  byte column, the source line as written, and a caret under the column.
  """
  fun apply(diag: CheckDiag, source: String val): String val =>
    let index = LineIndex(source, Utf8)
    (let line, let character) = index.position(diag.offset)
    let out = recover iso String end
    out.append(diag.file)
    out.push(':')
    out.append((line + 1).string())
    out.push(':')
    out.append((character + 1).string())
    out.append(": ")
    out.append(diag.message)
    out.push('\n')
    out.append(_line_of(source, diag.offset))
    out.push('\n')
    var i: USize = 0
    while i < character do
      out.push(' ')
      i = i + 1
    end
    out.push('^')
    consume out

  fun _line_of(source: String val, offset: USize): String val =>
    var from: USize = offset
    while (from > 0) and _not_newline(source, from - 1) do
      from = from - 1
    end
    var to: USize = offset
    while (to < source.size()) and _not_newline(source, to) do
      to = to + 1
    end
    source.substring(from.isize(), to.isize())

  fun _not_newline(source: String val, at: USize): Bool =>
    try source(at)? != '\n' else false end
